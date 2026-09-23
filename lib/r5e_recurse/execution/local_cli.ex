# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.LocalCLI do
  @moduledoc """
  Argument-vector launcher for cooperative local processes. The private helper
  owns a live group anchor; persisted PIDs never authorize recovery signals.
  Detached descendants and abrupt helper SIGKILL are outside this profile.
  Raw bytes, OS status, capture completeness and cleanup remain separate facts.
  """
  @behaviour R5eRecurse.Execution.Adapter
  alias R5eRecurse.Execution.{Adapter, Spool}
  alias Adapter.{Prepared, Handle, Ownership}
  alias __MODULE__.Broker

  @impl true
  def capabilities do
    %Adapter.Capabilities{
      harness: "posix-helper",
      version: "1",
      auth_modes: [:external],
      transports: [:stdio],
      context_inputs: [:stdin],
      control_inputs: [:cancel],
      output_events: [:raw_chunk, :os_exit, :capture_incomplete],
      cancellation: :observed_group,
      descendants: :cooperative_group,
      tool_restrictions: ["No shell expansion; detached descendants unsupported"],
      evidence_limits: [
        "64 MiB known-input/request plus output budget; bridge must account future requests",
        "Helper SIGKILL and detached process escape cannot be contained",
        "Local spool is not admission"
      ]
    }
  end

  @impl true
  def prepare(%Adapter.Session{} = session)
      when is_map(session.adapter_options) and is_map(session.budgets) do
    opts = session.adapter_options
    executable = opts[:executable]
    args = opts[:args] || []
    env = opts[:env] || %{}
    base = opts[:spool_root]
    final = opts[:result_file] || ""
    limit = Map.get(session.budgets, :trace_bytes, 64 * 1024 * 1024)
    reserved = Map.get(session.budgets, :reserved_request_bytes, 0)
    grace = Map.get(session.budgets, :grace_timeout_ms, 5_000)
    drain = Map.get(session.budgets, :drain_timeout_ms, 5_000)
    required = if is_integer(grace) and is_integer(drain), do: grace + drain + 2_000, else: 12_000
    callback = Map.get(session.budgets, :callback_timeout_ms, required)

    with true <- Map.get(opts, :required_descendants, :cooperative_group) == :cooperative_group,
         true <-
           is_integer(grace) and grace in 1..5_000 and is_integer(drain) and drain in 1..5_000,
         true <- is_integer(callback) and callback >= required and callback <= 60_000,
         true <- is_pid(session.owner) and Process.alive?(session.owner),
         true <- absolute?(executable) and File.regular?(executable),
         true <- absolute?(session.workspace) and File.dir?(session.workspace),
         true <- absolute?(base) and File.dir?(base),
         true <- is_list(args) and Enum.all?(args, &text?/1),
         true <-
           is_map(env) and
             Enum.all?(env, fn {k, v} ->
               text?(k) and k != "" and
                 not String.contains?(k, "=") and text?(v)
             end),
         true <-
           text?(final) and
             (final == "" or
                (Path.type(final) == :relative and
                   Enum.all?(String.split(final, "/"), &(&1 not in [".", "..", ""])))),
         true <-
           length(args) < 4096 and map_size(env) <= 4096 and
             Enum.reduce(
               args ++
                 [executable, session.workspace, base, final] ++
                 Enum.flat_map(env, fn {k, v} -> [k, v] end),
               0,
               &(byte_size(&1) + &2 + 8)
             ) <= 1_000_000,
         {:ok, spool} <- Spool.create(base, session.rendered_input, limit, reserved) do
      invocation = %{
        executable: executable,
        args: args,
        env: env,
        spool: spool,
        final: final,
        grace: grace,
        drain: drain
      }

      budgets =
        session.budgets
        |> Map.put(:grace_timeout_ms, grace)
        |> Map.put(:drain_timeout_ms, drain)
        |> Map.put(:callback_timeout_ms, callback)

      {:ok,
       %Prepared{
         adapter: __MODULE__,
         session: %{session | budgets: budgets},
         invocation: invocation
       }}
    else
      _ -> {:error, :invalid_local_invocation}
    end
  end

  def prepare(_), do: {:error, :invalid_local_invocation}

  @impl true
  def start(%Prepared{adapter: __MODULE__, launch_ref: ref} = prepared)
      when is_binary(ref) and ref != "" do
    with {:ok, broker} <- Broker.start(prepared), do: Broker.handle(broker)
  end

  def start(_), do: {:error, :launch_not_admitted}

  @impl true
  def observe(%Handle{adapter: __MODULE__, state: {broker, token}} = handle),
    do: Broker.observe(broker, token, handle)

  @impl true
  def cancel(%Handle{adapter: __MODULE__, state: {broker, token}}, _reason),
    do: Broker.cancel(broker, token)

  @impl true
  def reconcile(%{handle: %Handle{adapter: __MODULE__, state: {broker, token}} = handle}) do
    Broker.reconcile(broker, token)
  catch
    :exit, _ ->
      {:ok,
       %Ownership{
         state: :unknown,
         identity: handle.identity,
         evidence: [%{reason: :live_owner_unavailable}],
         spool: nil
       }}
  end

  def reconcile(_),
    do:
      {:ok,
       %Ownership{
         state: :unknown,
         identity: nil,
         evidence: [%{reason: :no_live_capability}],
         spool: nil
       }}

  def account_request(%Handle{state: {broker, token}}, bytes),
    do: Broker.account(broker, token, bytes)

  defp text?(s), do: is_binary(s) and not String.contains?(s, <<0>>)
  defp absolute?(s), do: text?(s) and Path.type(s) == :absolute
end
