# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.FakeAdapter do
  @moduledoc """
  Scripted T052 fixture. Runs a BEAM process, never an executable or model.

  Session.adapter_options accepts `script`, `executable` (:present/:missing),
  `cancellation` (:stop/:uncertain/:refuse), and `reconciliation` (:observe/:refuse).
  Each observe advances one step: {:stdout, bytes}, {:stderr, bytes},
  {:result_file, bytes}, {:model_completion, value, raw_sequence_numbers},
  {:exit, code}, :hang, or {:capture_failure, reason}. release/1 unblocks :hang.
  Scripted model completion cites earlier raw chunks, not an invented OS result.

  All ownership evidence is explicitly marked simulated. An exit code is scripted;
  observed BEAM process death does not claim subprocess/descendant termination.
  Captures are in-memory only, not durable spools or canonical artifact admissions.
  Idle/hard timers and owner monitoring are T053 responsibilities, not simulated here.
  """
  @behaviour R5eRecurse.Execution.Adapter
  alias R5eRecurse.Execution.Adapter.{
    Capabilities,
    Session,
    Prepared,
    Handle,
    Observation,
    Ownership
  }

  alias __MODULE__.Runner
  @timeout 1_000

  @impl true
  def capabilities do
    %Capabilities{
      harness: "scripted-beam-fixture",
      version: "1",
      auth_modes: [:fake],
      transports: [:fake],
      context_inputs: [:rendered_input],
      control_inputs: [:script],
      output_events: [:raw_chunk, :model_completion, :os_exit, :capture_incomplete],
      cancellation: :observed_process,
      descendants: :unobserved,
      tool_restrictions: ["no tools execute"],
      evidence_limits: [
        "simulated exit codes; only BEAM process death is observed",
        "no durable spool",
        "no real harness or provider"
      ]
    }
  end

  @impl true
  def prepare(%Session{} = session) do
    opts = session.adapter_options

    cond do
      not is_map(opts) ->
        {:error, :invalid_options}

      opts[:executable] == :missing ->
        {:error, :missing_executable}

      Map.keys(opts) --
        [
          :script,
          :executable,
          :cancellation,
          :reconciliation,
          :block_start,
          :block_observe,
          :block_cancel,
          :block_reconcile,
          :probe
        ] != [] ->
        {:error, :invalid_options}

      not valid_session?(session) ->
        {:error, :invalid_session}

      not valid_script?(opts[:script]) ->
        {:error, :invalid_script}

      Map.get(opts, :executable, :present) != :present ->
        {:error, :invalid_options}

      Map.get(opts, :cancellation, :stop) not in [:stop, :uncertain, :refuse] ->
        {:error, :invalid_options}

      Map.get(opts, :reconciliation, :observe) not in [:observe, :refuse] ->
        {:error, :invalid_options}

      true ->
        {:ok, %Prepared{adapter: __MODULE__, session: session, invocation: opts}}
    end
  end

  def prepare(_), do: {:error, :invalid_session}

  @impl true
  def start(%Prepared{
        adapter: __MODULE__,
        session: session,
        invocation: invocation,
        launch_ref: ref
      }) do
    # Syntactic prerequisite only. The coordinator owns actual admission proof.
    with true <- event_ref?(ref),
         {:ok, prepared} <- prepare(%{session | adapter_options: invocation}),
         token = make_ref(),
         {:ok, pid} <-
           owned_runner(session.owner, prepared.invocation, session.budgets, token) do
      maybe_block(invocation, :start)

      {:ok,
       %Handle{
         adapter: __MODULE__,
         session_id: session.id,
         generation: session.generation,
         owner: session.owner,
         identity: {pid, token},
         state: %{
           faults:
             Map.take(invocation, [:block_observe, :block_cancel, :block_reconcile, :probe]),
           terminal: false,
           sequence: 0,
           reconciliation: Map.get(invocation, :reconciliation, :observe)
         }
       }}
    else
      false -> {:error, :launch_reference_required}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :start_failed}
    end
  end

  def start(_), do: {:error, :invalid_prepared}

  @impl true
  def observe(%Handle{adapter: __MODULE__, state: %{terminal: true}} = handle),
    do: {:ok, [], handle}

  def observe(%Handle{adapter: __MODULE__, identity: {pid, token}} = handle) do
    maybe_block(Map.get(handle.state, :faults, %{}), :observe)
    monitor = Process.monitor(pid)
    result = call(pid, {:observe, token})

    result =
      case result do
        {:ok, events, terminal} ->
          if not terminal or down?(monitor, pid) do
            sequence =
              case List.last(events) do
                nil -> handle.state.sequence
                event -> event.sequence
              end

            {:ok, events,
             %{handle | state: %{handle.state | terminal: terminal, sequence: sequence}}}
          else
            {:error, :stop_unconfirmed}
          end

        error ->
          error
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  def observe(_), do: {:error, :invalid_handle}

  @impl true
  def cancel(%Handle{adapter: __MODULE__, state: %{terminal: true}} = handle, reason)
      when is_atom(reason) do
    maybe_block(Map.get(handle.state, :faults, %{}), :cancel)
    {:ok, ownership(handle, :stopped, :previously_observed_exit)}
  end

  def cancel(%Handle{adapter: __MODULE__, identity: {pid, token}} = handle, reason)
      when is_atom(reason) do
    maybe_block(Map.get(handle.state, :faults, %{}), :cancel)
    monitor = Process.monitor(pid)

    result =
      case call(pid, {:cancel, token}) do
        :stopping ->
          state = if down?(monitor, pid), do: :stopped, else: :unknown
          {:ok, ownership(handle, state, :cancellation)}

        :uncertain ->
          {:ok, ownership(handle, :unknown, :cancellation_unconfirmed)}

        error ->
          error
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  def cancel(_, _), do: {:error, :invalid_handle}

  @impl true
  def reconcile(%{handle: %Handle{adapter: __MODULE__} = handle}) do
    maybe_block(Map.get(handle.state, :faults, %{}), :reconcile)

    cond do
      handle.state.reconciliation == :refuse ->
        {:error, :reconciliation_refused}

      handle.state.terminal ->
        {:ok, ownership(handle, :stopped, :previously_observed_exit)}

      true ->
        {pid, token} = handle.identity

        state =
          case call(pid, {:reconcile, token}) do
            :live -> :live
            _ -> :unknown
          end

        {:ok, ownership(handle, state, :read_only_probe)}
    end
  end

  def reconcile(_),
    do:
      {:ok,
       %Ownership{
         state: :unknown,
         identity: nil,
         evidence: [%{simulated: true, reason: :unproven_identity}],
         spool: nil
       }}

  @doc "Test control only: advance a paused script without starting another process."
  def release(%Handle{adapter: __MODULE__, identity: {pid, token}}),
    do: call(pid, {:release, token})

  defp ownership(handle, state, reason),
    do: %Ownership{
      state: state,
      identity: handle.identity,
      evidence: [%{simulated: true, reason: reason}],
      spool: %{durable: false, last_observed_sequence: handle.state.sequence}
    }

  defp maybe_block(options, action) do
    key =
      %{
        start: :block_start,
        observe: :block_observe,
        cancel: :block_cancel,
        reconcile: :block_reconcile
      }[action]

    if options[key] do
      Process.flag(:trap_exit, true)
      if is_pid(options[:probe]), do: send(options.probe, {:fake_callback, action, self()})

      receive do
        :never -> :ok
      end
    end
  end

  defp owned_runner(owner, options, budgets, token) do
    caller = self()
    reply = make_ref()

    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      result = GenServer.start(Runner, {options, budgets, token}, timeout: @timeout)
      send(caller, {reply, result})

      case result do
        {:ok, pid} ->
          if is_pid(options[:probe]), do: send(options.probe, {:fake_runner, pid, owner})
          runner_monitor = Process.monitor(pid)

          receive do
            {:DOWN, ^owner_monitor, :process, ^owner, _} ->
              Process.exit(pid, :kill)

              receive do
                {:DOWN, ^runner_monitor, :process, ^pid, _} -> :ok
              end

            {:DOWN, ^runner_monitor, :process, ^pid, _} ->
              :ok
          end

        _ ->
          :ok
      end
    end)

    receive do
      {^reply, result} -> result
    after
      @timeout + 100 -> {:error, :start_unconfirmed}
    end
  end

  defp call(pid, message) do
    GenServer.call(pid, message, @timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp down?(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> true
    after
      @timeout -> false
    end
  end

  defp valid_session?(s) do
    is_binary(s.id) and s.id != "" and is_pid(s.owner) and Process.alive?(s.owner) and
      is_map(s.generation) and
      Enum.all?(~w(bootId runId), &(is_binary(s.generation[&1]) and s.generation[&1] != "")) and
      event_ref?(s.binding_ref) and event_ref?(s.context_ref) and is_binary(s.rendered_input) and
      is_binary(s.workspace) and Path.type(s.workspace) == :absolute and File.dir?(s.workspace) and
      is_binary(s.model) and s.model != "" and s.auth_mode == :fake and not is_nil(s.route) and
      is_map(s.budgets) and
      Enum.all?(
        [:max_output_bytes, :max_chunk_bytes],
        &(is_integer(s.budgets[&1]) and s.budgets[&1] > 0)
      )
  end

  defp event_ref?(value),
    do: is_binary(value) and Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, value)

  defp valid_script?(script) when is_list(script) do
    Enum.all?(script, fn
      {stream, bytes} when stream in [:stdout, :stderr, :result_file] ->
        is_binary(bytes)

      {:model_completion, _value, coverage} ->
        is_list(coverage) and coverage != [] and Enum.all?(coverage, &(is_integer(&1) and &1 > 0))

      {:exit, code} ->
        is_integer(code) and code in 0..255

      {:capture_failure, reason} ->
        is_atom(reason)

      :hang ->
        true

      _ ->
        false
    end)
  end

  defp valid_script?(_), do: false

  defmodule Runner do
    @moduledoc false
    use GenServer
    @impl true
    def init({opts, budgets, token}) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         script: opts.script,
         token: token,
         budgets: budgets,
         cancellation: Map.get(opts, :cancellation, :stop),
         sequence: 0,
         bytes: 0,
         chunks: %{}
       }}
    end

    @impl true
    def handle_call({:observe, token}, _, %{token: token, script: [step | rest]} = s) do
      case step do
        :hang ->
          {:reply, {:ok, [], false}, s}

        {:exit, code} ->
          finish(s, :process, :os_exit, %{code: code, simulated: true})

        {:capture_failure, reason} ->
          finish(s, :process, :capture_incomplete, %{reason: reason, simulated: true})

        {:model_completion, value, coverage} ->
          if Enum.all?(coverage, &Map.has_key?(s.chunks, &1)) do
            event =
              observation(
                s,
                :stdout,
                :model_completion,
                value,
                Enum.map(coverage, &Map.fetch!(s.chunks, &1))
              )

            {:reply, {:ok, [event], false}, %{s | script: rest, sequence: event.sequence}}
          else
            finish(s, :process, :capture_incomplete, %{reason: :invalid_coverage, simulated: true})
          end

        {source, bytes} ->
          if byte_size(bytes) > s.budgets.max_chunk_bytes or
               s.bytes + byte_size(bytes) > s.budgets.max_output_bytes do
            finish(s, :process, :capture_incomplete, %{reason: :output_limit, simulated: true})
          else
            event = observation(s, source, :raw_chunk, bytes, [])

            chunk = %{
              sequence: event.sequence,
              source: source,
              bytes: byte_size(bytes),
              digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
            }

            {:reply, {:ok, [event], false},
             %{
               s
               | script: rest,
                 sequence: event.sequence,
                 bytes: s.bytes + byte_size(bytes),
                 chunks: Map.put(s.chunks, event.sequence, chunk)
             }}
          end
      end
    end

    def handle_call({:observe, token}, _, %{token: token, script: []} = s),
      do: {:reply, {:ok, [], false}, s}

    def handle_call({:cancel, token}, _, %{token: token, cancellation: :stop} = s),
      do: {:stop, :normal, :stopping, s}

    def handle_call({:cancel, token}, _, %{token: token, cancellation: :uncertain} = s),
      do: {:reply, :uncertain, s}

    def handle_call({:cancel, token}, _, %{token: token, cancellation: :refuse} = s),
      do: {:reply, {:error, :cancellation_refused}, s}

    def handle_call({:reconcile, token}, _, %{token: token} = s), do: {:reply, :live, s}

    def handle_call({:release, token}, _, %{token: token, script: [:hang | rest]} = s),
      do: {:reply, :ok, %{s | script: rest}}

    def handle_call(_, _, s), do: {:reply, {:error, :stale_identity}, s}

    defp observation(s, source, kind, value, coverage),
      do: %Observation{
        sequence: s.sequence + 1,
        source: source,
        kind: kind,
        value: value,
        coverage: coverage
      }

    defp finish(s, source, kind, value),
      do: {:stop, :normal, {:ok, [observation(s, source, kind, value, [])], true}, s}

    @impl true
    def format_status(status), do: Map.new(status, fn {key, _} -> {key, :redacted} end)
  end
end
