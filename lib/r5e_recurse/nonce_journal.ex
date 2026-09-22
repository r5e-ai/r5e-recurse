defmodule R5eRecurse.NonceJournal do
  @moduledoc """
  Single-writer immutable admission journal. Persistence precedes submission.

  A durable intent reserves each operation before signing. One operation ID fixes
  its candidate and envelope permanently. A crash before the final entry leaves
  a lookup-only reserved operation; it never triggers another signature. Subsequent calls
  only scan canonical history; they never invoke the signer or submit again.
  Pre-boot entries remain readable but cannot authorize fresh signatures/writes.
  The caller supplies sanitized admission specs, never transport headers or keys.
  Entries contain public signatures and candidates, not signing custody. The
  lock-owning helper publishes both files. Loss of ownership fences publication
  and dispatch: the same helper initiates HTTP while holding its lock. An already-sent HTTP request can still complete, and is
  resolved only by canonical lookup. New directory parent entries are synced.
  """
  use GenServer
  alias RecurseVerify.Canonical
  alias R5eRecurse.{Commands.Envelope, NonceJournal.Scan, NonceJournal.Entry}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def submit_once(server, operation_id, generation, candidate, signer),
    do: GenServer.call(server, {:submit, operation_id, generation, candidate, signer}, :infinity)

  def lookup(server, operation_id), do: GenServer.call(server, {:lookup, operation_id}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    directory = Path.expand(Keyword.fetch!(opts, :directory))

    with {:ok, lock} <- acquire(directory),
         {:ok, entries} <- load(directory, Keyword.fetch!(opts, :origin)) do
      {:ok,
       %{
         directory: directory,
         lock: lock,
         entries: entries,
         client: Keyword.fetch!(opts, :client),
         origin: Keyword.fetch!(opts, :origin),
         boot: Keyword.fetch!(opts, :boot_id)
       }}
    else
      _ -> {:stop, :journal_unavailable}
    end
  end

  @impl true
  def handle_call({:lookup, id}, _, state) do
    result =
      case Map.fetch(state.entries, id) do
        {:ok, entry} -> scan(state.client, entry)
        :error -> {:outcome_unknown, %{reason: :operation_not_journaled}}
      end

    {:reply, result, state}
  end

  def handle_call({:submit, id, generation, candidate, signer}, _, state) do
    candidate = stringify_candidate(candidate)

    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        if entry["candidate"] == candidate and entry["generation"] == generation,
          do: {:reply, scan(state.client, entry), state},
          else: {:reply, {:conflict, %{operation_id: id, reason: :candidate_changed}}, state}

      :error ->
        if is_binary(id) and byte_size(id) > 0 and Entry.generation?(generation) and
             generation["bootId"] == state.boot do
          case prepare(state, id, generation, candidate, signer) do
            {:ok, entry} ->
              # Even a lost acknowledgement leaves the entry in memory and on disk.
              state = put_in(state.entries[id], entry)

              result = submit(state, entry)

              {:reply, result, state}

            {:blocked, entry} ->
              {:reply, {:outcome_unknown, %{reason: :preparation_unconfirmed}},
               put_in(state.entries[id], entry)}

            error ->
              {:reply, error, state}
          end
        else
          {:reply, {:error, :stale_generation_or_operation}, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{lock: port} = state),
    do: {:stop, :writer_lock_lost, state}

  def handle_info({:EXIT, port, _}, %{lock: port} = state), do: {:stop, :writer_lock_lost, state}
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state), do: if(Port.info(state.lock), do: Port.close(state.lock))
  @impl true
  def format_status(status), do: Map.new(status, fn {k, _} -> {k, :redacted} end)

  defp prepare(state, id, generation, candidate, signer) do
    reservation = %{
      "operationId" => id,
      "origin" => state.origin,
      "generation" => generation,
      "candidate" => candidate,
      "candidateDigest" => Canonical.hash(candidate),
      "status" => "reserved"
    }

    if Entry.valid?(reservation, state.origin) do
      case persist(state.lock, id, ".intent", reservation) do
        :ok -> sign_reserved(state, reservation, signer)
        _ -> {:blocked, reservation}
      end
    else
      {:error, :invalid_candidate}
    end
  rescue
    _ -> {:error, :invalid_candidate}
  end

  defp sign_reserved(state, reservation, signer) do
    with {:ok, envelope} <- signer.(),
         {:ok, verified} <- Envelope.verify_signed(envelope),
         entry =
           Map.merge(reservation, %{
             "status" => "prepared",
             "envelope" => envelope,
             "request" => verified.request
           }),
         true <- Entry.valid?(entry, state.origin),
         false <-
           Enum.any?(state.entries, fn {_, e} -> Entry.nonce_key(e) == Entry.nonce_key(entry) end) do
      case persist(state.lock, entry["operationId"], ".json", entry) do
        :ok -> {:ok, entry}
        _ -> {:blocked, entry}
      end
    else
      _ -> {:blocked, reservation}
    end
  rescue
    _ -> {:blocked, reservation}
  catch
    _, _ -> {:blocked, reservation}
  end

  defp submit(state, entry) do
    name = Canonical.hash(entry["operationId"]) <> ".json"

    command = %{
      action: "dispatch",
      name: name,
      url: state.client.url,
      timeout: state.client.timeout
    }

    case helper_call(state.lock, command, state.client.timeout + 1000) do
      {:ok, %{"status" => "acknowledged"}} -> scan(state.client, entry)
      {:ok, %{"status" => "connection_failed"}} -> {:transport_failure, :connection_failed}
      _ -> {:outcome_unknown, %{reason: :submission_unconfirmed}}
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :submission_failed}}
  catch
    _, _ -> {:outcome_unknown, %{reason: :submission_failed}}
  end

  defp scan(_, %{"status" => "reserved"}), do: {:outcome_unknown, %{reason: :signing_unconfirmed}}

  defp scan(client, entry) do
    case Scan.lookup(client, entry) do
      {tag, _, _} = result when tag in [:ok, :denied] -> result
      {:outcome_unknown, _} = result -> result
      _ -> {:outcome_unknown, %{reason: :history_unavailable}}
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :history_unavailable}}
  end

  defp stringify_candidate(%{target: target, spec: spec}),
    do: %{"target" => target, "spec" => spec}

  defp stringify_candidate(candidate), do: candidate

  defp acquire(directory) do
    helper = Application.app_dir(:r5e_recurse, "priv/nonce_journal/journal_io.py")

    case System.find_executable("python3") do
      nil ->
        {:error, :python_required}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:line, 256},
            args: [helper, directory]
          ])

        receive do
          {^port, {:data, {:eol, "acquired"}}} ->
            {:ok, port}

          {^port, _} ->
            if(Port.info(port), do: Port.close(port))
            {:error, :ownership_unavailable}
        after
          5000 ->
            Port.close(port)
            {:error, :ownership_timeout}
        end
    end
  end

  defp persist(port, id, suffix, entry) do
    name = Canonical.hash(id) <> suffix
    content = Canonical.encode(entry)
    if byte_size(content) > 8 * 1024 * 1024, do: throw(:too_large)

    case helper_call(port, %{name: name, content: content}, 5000) do
      {:ok, %{"status" => "persisted"}} -> :ok
      _ -> {:error, :publication_unconfirmed}
    end
  rescue
    _ -> {:error, :publication_unconfirmed}
  catch
    _, _ -> {:error, :publication_unconfirmed}
  end

  defp helper_call(port, %{name: name} = command, timeout) do
    bytes = Jason.encode!(command)
    Port.command(port, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>)

    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"name" => ^name} = response} -> {:ok, response}
          _ -> {:error, :helper_unconfirmed}
        end

      {^port, _} ->
        {:error, :helper_unconfirmed}
    after
      timeout ->
        if Port.info(port), do: Port.close(port)
        {:error, :helper_unconfirmed}
    end
  rescue
    _ -> {:error, :helper_unconfirmed}
  end

  defp load(directory, origin) do
    with {:ok, intents} <- load_files(directory, ".intent", origin, "reserved"),
         {:ok, prepared} <- load_files(directory, ".json", origin, "prepared"),
         true <-
           Enum.all?(prepared, fn {id, entry} -> Entry.reservation(entry) == intents[id] end),
         nonce_keys = Enum.map(prepared, fn {_, e} -> Entry.nonce_key(e) end),
         true <- length(nonce_keys) == length(Enum.uniq(nonce_keys)) do
      {:ok, Map.merge(intents, prepared)}
    else
      _ -> {:error, :corrupt_journal}
    end
  end

  defp load_files(directory, suffix, origin, status) do
    Enum.reduce_while(Path.wildcard(Path.join(directory, "*" <> suffix)), {:ok, %{}}, fn path,
                                                                                         {:ok,
                                                                                          entries} ->
      with {:ok, stat} <- File.lstat(path),
           true <- stat.type == :regular and stat.size <= 8 * 1024 * 1024,
           {:ok, bytes} <- File.read(path),
           {:ok, entry} <- Canonical.decode_json(bytes),
           true <- Entry.valid?(entry, origin) and entry["status"] == status,
           true <- Path.basename(path) == Canonical.hash(entry["operationId"]) <> suffix do
        {:cont, {:ok, Map.put(entries, entry["operationId"], entry)}}
      else
        _ -> {:halt, {:error, :corrupt_journal}}
      end
    end)
  rescue
    _ -> {:error, :corrupt_journal}
  end
end
