# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Worker do
  @moduledoc """
  Responsive execution owner with one bounded adapter callback at a time.

  The fixed sink is the original Session.owner. Events are
  `{:execution, worker, generation, {:observations, batch}}` and
  `{:execution, worker, generation, {:terminal, ownership, reason}}`.
  Cancellation acknowledges only `:cancelling`; it is not stop evidence.

  Session.owner passed to the adapter is this stable worker. Adapters must bind
  launched work to its death before returning or blocking in start. Killing a
  callback cannot prove that an external process stopped. Unknown stays unknown.
  Defaults are idle 5 minutes, hard 30 minutes, callback 1 second; overrides use
  Session.budgets' *_timeout_ms keys. No admission evidence is manufactured here.
  """
  use GenServer
  alias R5eRecurse.Execution.Adapter.{Prepared, Handle, Ownership, Observation}
  @poll_ms 10

  def start_link(prepared), do: GenServer.start_link(__MODULE__, prepared, timeout: 1_000)
  def cancel(worker, reason) when is_atom(reason), do: GenServer.call(worker, {:cancel, reason})
  def status(worker), do: GenServer.call(worker, :status)

  @impl true
  def init(%Prepared{session: session} = prepared) do
    Process.flag(:trap_exit, true)

    budgets = %{
      idle: Map.get(session.budgets, :idle_timeout_ms, 300_000),
      hard: Map.get(session.budgets, :hard_timeout_ms, 1_800_000),
      callback: Map.get(session.budgets, :callback_timeout_ms, 1_000)
    }

    if is_pid(session.owner) and Process.alive?(session.owner) and
         Enum.all?(Map.values(budgets), &(is_integer(&1) and &1 in 1..4_294_967_295)) do
      s = %{
        prepared: %{prepared | session: %{session | owner: self()}},
        owner: session.owner,
        owner_monitor: Process.monitor(session.owner),
        generation: session.generation,
        session_id: session.id,
        adapter: prepared.adapter,
        handle: nil,
        phase: :starting,
        budgets: budgets,
        timers: %{},
        callback: nil,
        last_sequence: -1,
        terminal_sent: false,
        reason: nil
      }

      s = s |> timer(:hard, budgets.hard) |> timer(:idle, budgets.idle)
      {:ok, s, {:continue, :start}}
    else
      {:stop, :invalid_execution_owner_or_budget}
    end
  end

  @impl true
  def handle_continue(:start, s), do: {:noreply, invoke(s, :start, [s.prepared])}
  @impl true
  def handle_call(:status, _, s),
    do: {:reply, %{phase: s.phase, session_id: s.session_id, generation: s.generation}, s}

  def handle_call({:cancel, reason}, _, s) do
    {:reply, :cancelling, request_cancel(s, {:cancelled, reason})}
  end

  @impl true
  def handle_info({:deadline, generation, kind, token}, %{generation: generation} = s) do
    case s.timers[kind] do
      {_, ^token} -> {:noreply, request_cancel(s, {kind, :deadline})}
      _ -> {:noreply, s}
    end
  end

  def handle_info(
        {:poll, generation, token},
        %{generation: generation, phase: :running, callback: nil} = s
      ) do
    case s.timers[:poll] do
      {_, ^token} -> {:noreply, invoke(s, :observe, [s.handle])}
      _ -> {:noreply, s}
    end
  end

  def handle_info(
        {:callback, generation, ref, result},
        %{generation: generation, callback: %{ref: ref} = cb} = s
      ) do
    Process.demonitor(cb.monitor, [:flush])
    s = %{s | callback: nil}

    if s.phase == :cancelling_wait,
      do: {:noreply, begin_cancel(%{s | phase: :cancelling})},
      else: result(s, cb.action, result)
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = s),
    do: {:noreply, request_cancel(s, :owner_down)}

  def handle_info(
        {:DOWN, monitor, :process, _, _},
        %{callback: %{monitor: monitor}} = s
      ),
      do:
        finish(
          %{s | callback: nil, reason: s.reason || :callback_unconfirmed},
          unknown(s, :callback_guardian_lost)
        )

  def handle_info(:finish_unknown, s), do: finish(s, unknown(s, :ownership_unconfirmed))
  def handle_info(_, s), do: {:noreply, s}

  defp result(s, :start, {:ok, {:ok, %Handle{} = handle}}) do
    if valid_handle?(s, handle) do
      {:noreply, poll(%{s | phase: :running, handle: handle})}
    else
      finish(%{s | reason: :invalid_start_handle}, unknown(s, :invalid_identity))
    end
  end

  defp result(s, :observe, {:ok, {:ok, events, %Handle{} = handle}}) when is_list(events) do
    if valid_handle?(s, handle) and valid_events?(events, s.last_sequence) do
      last_sequence = if events == [], do: s.last_sequence, else: List.last(events).sequence
      s = %{s | handle: handle, last_sequence: last_sequence}
      if events != [], do: send_event(s, {:observations, events})
      s = if events == [], do: s, else: timer(s, :idle, s.budgets.idle)

      case Enum.find(events, &(&1.kind in [:os_exit, :capture_incomplete])) do
        nil ->
          {:noreply, poll(s)}

        _event ->
          s = %{s | phase: :reconciling, reason: terminal_reason(events)}
          {:noreply, invoke(s, :reconcile, [%{handle: handle}])}
      end
    else
      {:noreply, request_cancel(s, :invalid_observation_handle)}
    end
  end

  defp result(s, action, {:ok, {:ok, %Ownership{} = ownership}})
       when action in [:cancel, :reconcile] do
    if s.handle != nil and ownership.identity === s.handle.identity and
         ownership.state in [:live, :stopped, :unknown] do
      # Only the adapter's ownership result can establish stopped. A live result
      # at terminal observation still leaves cleanup uncertain on worker exit.
      ownership = if ownership.state == :live, do: %{ownership | state: :unknown}, else: ownership
      finish(s, ownership)
    else
      finish(s, unknown(s, :invalid_ownership_identity))
    end
  end

  defp result(s, action, _) when action in [:cancel, :reconcile],
    do: finish(s, unknown(s, :ownership_unconfirmed))

  defp result(s, :start, _),
    do: finish(%{s | reason: :start_unconfirmed}, unknown(s, :start_unconfirmed))

  defp result(s, :observe, _), do: {:noreply, request_cancel(s, :observation_unconfirmed)}

  defp valid_events?([], _previous), do: true

  defp valid_events?(
         [%Observation{sequence: sequence, kind: kind, source: source} | rest],
         previous
       )
       when is_integer(sequence) and sequence >= 0 and sequence > previous and
              kind in [
                :raw_chunk,
                :parsed_event,
                :model_completion,
                :os_exit,
                :capture_incomplete
              ] and
              source in [:stdout, :stderr, :process, :result_file],
       do: valid_events?(rest, sequence)

  defp valid_events?(_, _), do: false

  defp valid_handle?(s, handle) do
    handle.identity != nil and handle.adapter == s.adapter and handle.owner == self() and
      handle.session_id == s.session_id and
      handle.generation === s.generation and
      (s.handle == nil or handle.identity === s.handle.identity)
  end

  defp request_cancel(%{phase: phase} = s, _)
       when phase in [:cancelling, :cancelling_wait, :finished], do: s

  defp request_cancel(s, reason) do
    # Cleanup deadlines cannot erase an already observed exit/capture outcome.
    reason =
      if s.phase == :reconciling, do: %{observation: s.reason, cleanup: reason}, else: reason

    s = %{s | reason: reason}

    if s.callback do
      send(s.callback.pid, {:cancel, s.callback.ref})
      %{s | phase: :cancelling_wait}
    else
      begin_cancel(%{s | phase: :cancelling})
    end
  end

  defp begin_cancel(s) do
    if s.handle do
      invoke(s, :cancel, [s.handle, :execution_stopping])
    else
      send(self(), :finish_unknown)
      s
    end
  end

  defp invoke(s, action, args) do
    ref = make_ref()
    adapter = s.adapter

    {pid, monitor} =
      R5eRecurse.Execution.Callback.start(
        self(),
        s.generation,
        ref,
        fn -> apply(adapter, action, args) end,
        s.budgets.callback
      )

    %{s | callback: %{pid: pid, monitor: monitor, ref: ref, action: action}}
  end

  defp cancel_callback(%{callback: nil} = s), do: s

  defp cancel_callback(s) do
    send(s.callback.pid, {:cancel, s.callback.ref})
    Process.demonitor(s.callback.monitor, [:flush])
    %{s | callback: nil}
  end

  defp poll(s), do: timer(s, :poll, @poll_ms)

  defp timer(s, kind, milliseconds) do
    if s.timers[kind], do: Process.cancel_timer(elem(s.timers[kind], 0))
    token = make_ref()

    message =
      if kind == :poll,
        do: {:poll, s.generation, token},
        else: {:deadline, s.generation, kind, token}

    timer = Process.send_after(self(), message, milliseconds)
    %{s | timers: Map.put(s.timers, kind, {timer, token})}
  end

  # A batch can report both incomplete capture and an observed target exit.
  # Keep only the known status fields, so failed reconciliation cannot erase
  # already observed status or copy arbitrary adapter payload into final state.
  defp terminal_reason(events) when is_list(events) do
    exit = Enum.find(events, &(&1.kind == :os_exit))
    incomplete = Enum.any?(events, &(&1.kind == :capture_incomplete))

    case {incomplete, observed_exit(exit)} do
      {true, nil} -> :capture_incomplete
      {true, status} -> %{exit: status, capture: :capture_incomplete}
      {false, _} -> terminal_reason(exit)
    end
  end

  defp terminal_reason(%{kind: :os_exit, value: %{code: code}}) when is_integer(code),
    do: {:os_exit, code}

  defp terminal_reason(%{kind: :os_exit, value: %{signal: signal}})
       when is_integer(signal) and signal in 1..64, do: {:os_signal, signal}

  defp terminal_reason(%{kind: :capture_incomplete}), do: :capture_incomplete
  defp terminal_reason(_), do: :terminal_observation

  defp observed_exit(%{value: %{code: code}}) when is_integer(code) and code in 0..255,
    do: {:os_exit, code}

  defp observed_exit(%{value: %{signal: signal}}) when is_integer(signal) and signal in 1..64,
    do: {:os_signal, signal}

  defp observed_exit(_), do: nil

  defp unknown(s, reason),
    do: %Ownership{
      state: :unknown,
      identity: if(s.handle, do: s.handle.identity),
      evidence: [%{reason: reason}],
      spool: nil
    }

  defp send_event(s, event), do: send(s.owner, {:execution, self(), s.generation, event})

  defp finish(s, ownership) do
    send_event(s, {:terminal, ownership, s.reason})
    {:stop, :normal, %{s | phase: :finished, terminal_sent: true}}
  end

  @impl true
  def terminate(_, s) do
    cancel_callback(s)
    Enum.each(s.timers, fn {_, {timer, _}} -> Process.cancel_timer(timer) end)

    unless s.terminal_sent,
      do: send_event(s, {:terminal, unknown(s, :owner_terminated), :shutdown})

    :ok
  end

  @impl true
  def format_status(status), do: Map.new(status, fn {key, _} -> {key, :redacted} end)
end
