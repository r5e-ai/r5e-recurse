defmodule R5eRecurse.Commands.Ownership do
  @moduledoc "Pinned, single-host writer lifetime; the helper owns both flock and HTTP dispatch."
  alias __MODULE__.Broker

  def start_link(origin, owner, client) do
    lifetime = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    case Broker.start_link({origin, owner, client, lifetime}) do
      {:ok, pid} -> {:ok, pid, lifetime, directory(origin)}
      error -> error
    end
  end

  def directory(origin),
    do: "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(origin, "sha256:", "")

  def dispatch(pid, lifetime, mode, descriptor) do
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    result =
      try do
        GenServer.call(pid, {:dispatch, lifetime, mode, descriptor, token}, :infinity)
      catch
        :exit, _ -> {:outcome_unknown, %{reason: :writer_ownership_lost}}
      end

    case {mode, result} do
      {:replay, {tag, details}} when is_map(details) ->
        {tag, Map.put(details, :attempt_id, token)}

      {:replay, {:error, reason}} ->
        {:error, %{reason: reason, attempt_id: token}}

      _ ->
        result
    end
  end

  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end

defmodule R5eRecurse.Commands.Ownership.Broker do
  @moduledoc false
  use GenServer
  alias R5eRecurse.{Commands.Envelope, KernelClient}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({origin, owner, %KernelClient{} = client, lifetime}) do
    Process.flag(:trap_exit, true)

    with true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, origin),
         true <- is_integer(client.timeout) and client.timeout in 1..15_000,
         %KernelClient{} <- KernelClient.new(client.url),
         executable when is_binary(executable) <- System.find_executable("python3") do
      directory = R5eRecurse.Commands.Ownership.directory(origin)

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 4},
          args: [
            Application.app_dir(:r5e_recurse, "priv/commands/ownership.py"),
            directory,
            lifetime,
            origin,
            client.url,
            Integer.to_string(client.timeout)
          ]
        ])

      receive do
        {^port, {:data, bytes}} ->
          case Jason.decode(bytes) do
            {:ok, %{"version" => 1, "type" => "ready"}} ->
              {:ok,
               %{
                 port: port,
                 owner: owner,
                 owner_ref: Process.monitor(owner),
                 lifetime: lifetime,
                 timeout: client.timeout,
                 pending: nil,
                 poisoned: false
               }}

            _ ->
              Port.close(port)
              {:stop, :writer_ownership_unavailable}
          end

        {^port, _} ->
          {:stop, :writer_ownership_unavailable}
      after
        5_000 ->
          Port.close(port)
          {:stop, :writer_ownership_timeout}
      end
    else
      _ -> {:stop, :writer_ownership_unavailable}
    end
  rescue
    _ -> {:stop, :writer_ownership_unavailable}
  end

  @impl true
  def handle_call({:dispatch, lifetime, mode, descriptor, token}, from, state) do
    cond do
      state.poisoned or lifetime != state.lifetime ->
        {:reply, unknown(:writer_ownership_lost), state}

      state.pending != nil ->
        {:reply, {:error, :writer_busy}, state}

      true ->
        case validate(descriptor, mode, token) do
          :ok ->
            {:ok, verified} = Envelope.verify_signed(descriptor.envelope)

            request = %{
              version: 1,
              type: "dispatch",
              lifetime: lifetime,
              token: token,
              mode: Atom.to_string(mode),
              caller: verified.caller,
              nonce: verified.request["nonce"],
              body: Base.encode64(descriptor.body),
              body_digest: descriptor.body_digest,
              envelope_digest: RecurseVerify.Canonical.hash(descriptor.envelope),
              marker:
                RecurseVerify.Canonical.hash([verified.caller, descriptor.spec["commandId"]])
            }

            pending = %{
              from: from,
              monitor: Process.monitor(elem(from, 0)),
              token: token,
              mode: mode,
              spec: descriptor.spec,
              result: nil,
              timer: Process.send_after(self(), {:deadline, token}, state.timeout + 250)
            }

            state = %{state | pending: pending}

            if send_frame(state.port, request),
              do: {:noreply, state},
              else: poison(state, :writer_ownership_lost)

          _ ->
            {:reply, {:error, :invalid_command_preparation}, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port, pending: pending} = state)
      when not is_nil(pending) do
    with true <- byte_size(bytes) <= 131_072,
         {:ok, %{"version" => 1, "token" => token} = message} <- Jason.decode(bytes),
         true <- token == pending.token do
      response(message, state)
    else
      _ -> poison(state, :ownership_protocol_failure)
    end
  end

  def handle_info({:deadline, token}, %{pending: %{token: token}} = state),
    do: poison(state, :ownership_deadline)

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    {:noreply, state} = poison(state, :writer_ownership_lost)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: poison(state, :writer_ownership_lost)
  def handle_info({:EXIT, _, _}, state), do: poison(state, :writer_ownership_lost)
  def handle_info({port, _}, %{port: port} = state), do: poison(state, :writer_ownership_lost)
  def handle_info(_, state), do: {:noreply, state}

  defp response(
         %{"type" => "pending", "same" => same},
         %{pending: %{result: nil, mode: :normal}} = state
       )
       when is_boolean(same) do
    finish(
      state,
      if(same,
        do: unknown(:submission_unresolved),
        else: {:conflict, %{reason: :pending_payload_differs}}
      )
    )
  end

  defp response(%{"type" => "response"} = msg, %{pending: %{result: nil} = pending} = state) do
    decoded =
      case msg do
        %{"status" => status, "body" => body} when is_integer(status) ->
          case Base.decode64(body) do
            {:ok, bytes} -> KernelClient.decode_write({:ok, status, bytes})
            _ -> {:outcome_unknown, :invalid_receipt}
          end

        _ ->
          {:outcome_unknown, :connection_lost}
      end

    {result, action} = outcome(decoded, pending)
    Process.cancel_timer(pending.timer)

    pending = %{
      pending
      | result: result,
        timer: Process.send_after(self(), {:deadline, pending.token}, 1_250)
    }

    state = %{state | pending: pending}

    frame = %{
      version: 1,
      type: "finalize",
      lifetime: state.lifetime,
      token: pending.token,
      action: action
    }

    if send_frame(state.port, frame),
      do: {:noreply, state},
      else: poison(state, :finalization_failed)
  end

  defp response(%{"type" => "finalized"}, %{pending: %{result: result}} = state)
       when not is_nil(result), do: finish(state, result)

  defp response(_, state), do: poison(state, :ownership_protocol_failure)

  defp outcome({:ok, receipt}, %{mode: :replay}),
    do: {unknown(:unexpected_replay_admission, %{known_outcome: {:ok, receipt}}), "retain"}

  defp outcome({:ok, receipt}, %{spec: spec}),
    do:
      {{:accepted,
        %{
          event_ref: receipt["eventRef"],
          target: spec["target"],
          execution: :not_implemented,
          outcome: "admitted"
        }}, "retain"}

  defp outcome({:denied, receipt}, _), do: {{:denied, receipt}, "remove"}
  defp outcome({:refused, _}, _), do: {{:error, :command_refused}, "remove"}
  defp outcome(_, %{mode: :replay}), do: {unknown(:replay_outcome_unresolved), "retain"}
  defp outcome(_, _), do: {unknown(:submission_unresolved), "retain"}

  defp finish(state, result) do
    pending = state.pending
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.monitor, [:flush])
    GenServer.reply(pending.from, attempt(result, pending))
    {:noreply, %{state | pending: nil}}
  end

  defp poison(state, reason) do
    if state.pending do
      details =
        case state.pending.result do
          {tag, _} = result when tag in [:accepted, :denied] ->
            %{known_outcome: result, cleanup: :unacknowledged}

          {:error, :command_refused} = result ->
            %{known_outcome: result, cleanup: :unacknowledged}

          {:outcome_unknown, %{known_outcome: result}} ->
            %{known_outcome: result, cleanup: :unacknowledged}

          nil ->
            %{}

          _ ->
            %{cleanup: :unacknowledged}
        end

      finish(
        state,
        unknown(if(state.pending.result, do: :finalization_failed, else: reason), details)
      )
    end

    if Port.info(state.port), do: Port.close(state.port)
    {:noreply, %{state | poisoned: true, pending: nil}}
  end

  defp attempt({tag, details}, %{mode: :replay, token: token}) when is_map(details),
    do: {tag, Map.put(details, :attempt_id, token)}

  defp attempt({:error, reason}, %{mode: :replay, token: token}),
    do: {:error, %{reason: reason, attempt_id: token}}

  defp attempt(result, _), do: result
  defp unknown(reason, details \\ %{}), do: {:outcome_unknown, Map.put(details, :reason, reason)}

  defp validate(
         %{spec: spec, envelope: envelope, body: body, body_digest: digest} = descriptor,
         mode,
         token
       ) do
    with true <- mode in [:normal, :replay],
         true <- is_binary(token) and Regex.match?(~r/\A[0-9a-f]{64}\z/, token),
         true <- map_size(descriptor) == 4 and is_binary(body) and byte_size(body) <= 8_388_608,
         true <- digest == "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower),
         {:ok, %{"spec" => ^spec, "envelope" => ^envelope, "name" => nil} = decoded} <-
           Jason.decode(body),
         true <- map_size(decoded) == 3,
         {:ok, verified} <- Envelope.verify_signed(envelope),
         true <- verified.request["target"] == Envelope.target(),
         true <- verified.request["specAddress"] == RecurseVerify.Canonical.hash(spec) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate(_, _, _), do: :error

  defp send_frame(port, frame) do
    Port.command(port, Jason.encode!(frame))
  rescue
    _ -> false
  end

  @impl true
  def terminate(_, state) do
    poison(state, :writer_ownership_lost)
    :ok
  end
end
