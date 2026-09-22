defmodule R5eRecurse.Boot do
  @moduledoc """
  Fail-closed boot barrier. The supplied boundary must read canonical interrupted bindings,
  reconcile ownership, and return admitted event references for observations and issuer
  revocations. Callback success is a boundary contract, not independent admission proof.
  `boundary` is trusted deployment code, never a wire-supplied function/map:
  * `interrupted.()` returns `{:ok, bindings}` from verified canonical history.
  * `reconcile.(binding)` returns `{:ok, observation}` without executing work.
  * `admit.(kind, candidate)` verifies a granted canonical event, returning
    `{:ok, %{event_ref: "event:sha256:<64 lower-case hex>", kind: kind}}`; a revocation
    additionally returns the exact `badge` and `issuer` from the binding.
    It must verify the admitted Revocation subject and issuer authority, not merely
    echo candidate fields. An HTTP acknowledgment or projection is insufficient.

  No recovered binding is registered as a live route here. Deployment wiring and
  real canonical revocation integration are required before claiming managed boot.
  `execute/2` serializes the mutation with reconciliation, preventing check/use races;
  callback failure is an uncertain outcome and closes the gate. Never recursively
  call this server from a boundary or mutation callback.
  """
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def reconcile(server), do: GenServer.call(server, :reconcile, :infinity)

  def execute(server, mutation) when is_function(mutation, 0),
    do: GenServer.call(server, {:execute, mutation}, :infinity)

  def mutation_allowed?(server), do: GenServer.call(server, :allowed)
  def recover(server, kind, candidate), do: GenServer.call(server, {:recover, kind, candidate})
  @impl true
  def init(opts), do: {:ok, %{open: false, boundary: Keyword.fetch!(opts, :boundary)}}
  @impl true
  def handle_call({:execute, mutation}, _, %{open: true} = state) do
    result = mutation_result(mutation)

    open =
      case result do
        {:outcome_unknown, _} -> false
        _ -> true
      end

    {:reply, result, %{state | open: open}}
  end

  def handle_call({:execute, _}, _, state),
    do: {:reply, {:error, :boot_reconciliation_required}, state}

  def handle_call(:allowed, _, state), do: {:reply, state.open, state}

  def handle_call({:recover, kind, candidate}, _, state)
      when kind in [:observation, :revocation] do
    result = admitted(state.boundary, kind, candidate)
    open = state.open and match?({:ok, _}, result)
    {:reply, result, %{state | open: open}}
  end

  def handle_call({:recover, _, _}, _, state),
    do: {:reply, {:error, :recovery_kind_forbidden}, state}

  def handle_call(:reconcile, _, state) do
    result =
      safe(fn ->
        with {:ok, bindings} when is_list(bindings) <- state.boundary.interrupted.() do
          Enum.reduce_while(bindings, :ok, fn binding, :ok ->
            result =
              with {:ok, observation} <- state.boundary.reconcile.(binding),
                   {:ok, _} <-
                     admitted(state.boundary, :observation, observation),
                   {:ok, _} <- admitted(state.boundary, :revocation, binding) do
                :ok
              else
                {:outcome_unknown, _} = uncertain -> uncertain
                {:error, _} = error -> error
                _ -> {:error, :malformed_reconciliation}
              end

            if result == :ok, do: {:cont, :ok}, else: {:halt, result}
          end)
        else
          {:error, _} = error -> error
          _ -> {:error, :malformed_interrupted_bindings}
        end
      end)

    {:reply, result, %{state | open: result == :ok}}
  end

  # This trusted deployment boundary verifies canonical admission and issuer authority;
  # this barrier additionally binds its returned receipt to the exact recovery target.
  defp admitted(boundary, kind, candidate) do
    case safe(fn -> boundary.admit.(kind, candidate) end) do
      {:ok, %{event_ref: ref, kind: ^kind} = receipt}
      when is_binary(ref) and byte_size(ref) > 0 ->
        if Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, ref) and
             (kind == :observation or
                (is_map(candidate) and is_binary(candidate[:badge]) and
                   is_binary(candidate[:issuer]) and
                   receipt[:badge] == candidate[:badge] and receipt[:issuer] == candidate[:issuer])),
           do: {:ok, receipt},
           else: {:error, :revocation_target_mismatch}

      {:outcome_unknown, _} = uncertain ->
        uncertain

      {:error, _} = error ->
        error

      _ ->
        {:error, :admission_unconfirmed}
    end
  end

  defp mutation_result(fun) do
    try do
      fun.()
    rescue
      _ -> {:outcome_unknown, %{reason: :mutation_callback_failed}}
    catch
      _, _ -> {:outcome_unknown, %{reason: :mutation_callback_failed}}
    end
  end

  defp safe(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :boundary_failed}
    catch
      _, _ -> {:error, :boundary_failed}
    end
  end
end
