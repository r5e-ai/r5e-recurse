defmodule R5eRecurse.Commands do
  @moduledoc "Serialized canonical Command admission. Operations are explicitly unimplemented stubs."
  use GenServer
  alias R5eRecurse.Commands.{Dedup, Envelope, Ownership}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def submit(server, command, envelope),
    do: GenServer.call(server, {:submit, command, envelope}, :infinity)

  def lookup(server, caller, id), do: GenServer.call(server, {:lookup, caller, id}, :infinity)
  def operations, do: Envelope.operations()
  def command_spec(command, caller), do: Envelope.spec(command, caller)

  @impl true
  def init(opts) do
    origin = Keyword.fetch!(opts, :origin)

    with {:ok, lock, directory} <- Ownership.acquire(origin) do
      state = %{
        origin: origin,
        lock: lock,
        directory: directory,
        store: Keyword.fetch!(opts, :store),
        operators: Keyword.get(opts, :operator_keys, []),
        index: nil
      }

      case refresh(state) do
        {:ok, state} ->
          {:ok, state}

        _ ->
          Ownership.close(lock)
          {:stop, :canonical_history_unavailable}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:lookup, caller, id}, _from, state) do
    key = {caller, Envelope.scoped_id(state.origin, caller, id)}

    case refresh(state) do
      {:ok, state} ->
        result =
          case Map.get(state.index.commands, key) || Map.get(state.index.denials, key) do
            nil -> {:outcome_unknown, %{reason: :no_canonical_command}}
            entry -> {:existing, entry.result}
          end

        {:reply, result, state}

      _ ->
        {:reply, {:outcome_unknown, %{reason: :canonical_history_unavailable}}, state}
    end
  end

  def handle_call({:submit, command, envelope}, _from, state) do
    with {:ok, verified} <- Envelope.authenticate(command, envelope, state.origin),
         :ok <- operator(verified, state),
         {:ok, state} <- refresh(state) do
      key = {verified.caller, verified.spec["commandId"]}
      entry = Map.get(state.index.commands, key) || Map.get(state.index.denials, key)
      digest = verified.spec["payloadDigest"]

      pending_path =
        Path.join(
          state.directory,
          RecurseVerify.Canonical.hash([verified.caller, verified.spec["commandId"]]) <>
            ".pending"
        )

      result =
        cond do
          entry && entry.digest != digest ->
            {:conflict, %{event_ref: entry.result.event_ref}}

          MapSet.member?(state.index.nonces, {verified.caller, verified.request["nonce"]}) ->
            submit_replay(state, verified.spec, envelope)

          entry ->
            {:existing, entry.result}

          File.exists?(pending_path) ->
            pending_result(pending_path, digest)

          true ->
            admit(state, verified.spec, envelope, pending_path)
        end

      {:reply, result, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:outcome_unknown, %{reason: :canonical_history_unavailable}}, state}
    end
  end

  defp operator(%{spec: %{"operation" => operation}, public_key: key}, state)
       when operation in ["record_decision", "recover_attempt", "request_push", "select_lesson"] do
    if key in state.operators, do: :ok, else: {:error, :operator_signature_required}
  end

  defp operator(_, _), do: :ok

  defp refresh(%{store: {module, store}} = state) do
    with {:ok, records} <- store_call(module, :history, [store]),
         {:ok, index} <- Dedup.rebuild(records, state.origin) do
      {:ok, %{state | index: index}}
    end
  end

  defp pending_result(path, digest) do
    case File.read(path) do
      {:ok, ^digest} -> {:outcome_unknown, %{reason: :submission_unresolved}}
      {:ok, _} -> {:conflict, %{reason: :pending_payload_differs}}
      _ -> {:outcome_unknown, %{reason: :pending_record_unreadable}}
    end
  end

  defp admit(%{store: {module, store}}, spec, envelope, pending_path) do
    with :ok <- persist(pending_path, spec["payloadDigest"]) do
      case store_call(module, :submit, [store, spec, envelope]) do
        {:ok, receipt} ->
          {:accepted,
           %{
             event_ref: receipt["eventRef"],
             target: spec["target"],
             execution: :not_implemented,
             outcome: "admitted"
           }}

        {:denied, receipt} ->
          File.rm(pending_path)
          {:denied, receipt}

        {:refused, _} ->
          File.rm(pending_path)
          {:error, :command_refused}

        _ ->
          {:outcome_unknown, %{reason: :submission_unresolved}}
      end
    else
      _ -> {:error, :uncertainty_journal_unavailable}
    end
  end

  defp submit_replay(%{store: {module, store}}, spec, envelope) do
    case store_call(module, :submit, [store, spec, envelope]) do
      {:denied, receipt} -> {:denied, receipt}
      _ -> {:outcome_unknown, %{reason: :replay_outcome_unresolved}}
    end
  end

  defp store_call(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp persist(path, digest) do
    helper = Application.app_dir(:r5e_recurse, "priv/commands/persist.py")

    case System.cmd("python3", [helper, path, digest], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, :journal_write_failed}
    end
  rescue
    _ -> {:error, :journal_write_failed}
  end

  @impl true
  def handle_info({port, _}, %{lock: port} = state), do: {:stop, :writer_ownership_lost, state}
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state), do: Ownership.close(state.lock)
end
