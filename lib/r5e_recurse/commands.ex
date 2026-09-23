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

    {module, store} = Keyword.fetch!(opts, :store)

    with %R5eRecurse.KernelClient{} = client <- store_call(module, :client, [store]),
         {:ok, broker, lifetime, directory} <- Ownership.start_link(origin, self(), client) do
      state = %{
        origin: origin,
        broker: broker,
        lifetime: lifetime,
        directory: directory,
        store: Keyword.fetch!(opts, :store),
        operators: Keyword.get(opts, :operator_keys, []),
        index: nil
      }

      case refresh(state) do
        {:ok, state} ->
          {:ok, state}

        _ ->
          Ownership.close(broker)
          {:stop, :canonical_history_unavailable}
      end
    else
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :unsupported_command_store}
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
         {:ok, state} <- refresh_for_submit(state) do
      key = {verified.caller, verified.spec["commandId"]}
      entry = Map.get(state.index.commands, key) || Map.get(state.index.denials, key)
      digest = verified.spec["payloadDigest"]

      result =
        cond do
          entry && entry.digest != digest ->
            {:conflict, %{event_ref: entry.result.event_ref}}

          MapSet.member?(state.index.nonces, {verified.caller, verified.request["nonce"]}) ->
            submit_replay(state, verified.spec, envelope)

          entry ->
            {:existing, entry.result}

          true ->
            dispatch(state, :normal, verified.spec, envelope)
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

  defp refresh_for_submit(state) do
    case refresh(state) do
      {:ok, state} -> {:ok, state}
      _ -> {:outcome_unknown, %{reason: :canonical_history_unavailable}}
    end
  end

  defp dispatch(%{store: {module, store}} = state, mode, spec, envelope) do
    case store_call(module, :prepare_submit, [store, spec, envelope]) do
      {:ok, %{spec: ^spec, envelope: ^envelope} = descriptor} ->
        Ownership.dispatch(state.broker, state.lifetime, mode, descriptor)

      _ ->
        {:error, :invalid_command_preparation}
    end
  end

  defp submit_replay(state, spec, envelope), do: dispatch(state, :replay, spec, envelope)

  defp store_call(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  @impl true
  def terminate(_, state), do: Ownership.close(state.broker)
end
