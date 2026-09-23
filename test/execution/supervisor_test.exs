# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.ExecutionSupervisorTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Execution.{Supervisor, Worker}
  alias R5eRecurse.Execution.Adapter.Session
  alias R5eRecurse.FakeAdapter, as: Fake

  defmodule SwappedHandle do
    def start(prepared) do
      with {:ok, handle} <- Fake.start(%{prepared | adapter: Fake}),
           do: {:ok, %{handle | adapter: __MODULE__}}
    end

    def observe(handle), do: {:ok, [], %{handle | identity: {:wrong, make_ref()}}}
    def cancel(handle, reason), do: Fake.cancel(%{handle | adapter: Fake}, reason)
  end

  defmodule SwappedStart do
    def start(prepared) do
      with {:ok, handle} <- Fake.start(%{prepared | adapter: Fake}),
           do: {:ok, %{handle | adapter: __MODULE__, session_id: "different-session"}}
    end
  end

  defmodule SwappedOwnership do
    def start(prepared) do
      with {:ok, handle} <- Fake.start(%{prepared | adapter: Fake}),
           do: {:ok, %{handle | adapter: __MODULE__}}
    end

    def observe(handle) do
      with {:ok, observations, next} <- Fake.observe(%{handle | adapter: Fake}),
           do: {:ok, observations, %{next | adapter: __MODULE__}}
    end

    def cancel(handle, reason) do
      with {:ok, ownership} <- Fake.cancel(%{handle | adapter: Fake}, reason),
           do: {:ok, %{ownership | identity: {:wrong, make_ref()}}}
    end
  end

  setup do
    supervisor = start_supervised!(Supervisor)

    session = %Session{
      id: "execution",
      generation: %{"bootId" => "boot", "runId" => "run"},
      owner: self(),
      binding_ref: event("a"),
      context_ref: event("b"),
      rendered_input: "secret input",
      workspace: System.tmp_dir!(),
      model: "fake",
      auth_mode: :fake,
      route: %{credential: "secret route"},
      budgets: %{
        max_output_bytes: 10_000,
        max_chunk_bytes: 100,
        idle_timeout_ms: 1_000,
        hard_timeout_ms: 2_000,
        callback_timeout_ms: 300
      }
    }

    %{supervisor: supervisor, session: session}
  end

  test "timer overflow is refused before any callback or runner can start", c do
    for key <- [:idle_timeout_ms, :hard_timeout_ms, :callback_timeout_ms] do
      session = %{c.session | budgets: Map.put(c.session.budgets, key, 4_294_967_296)}
      prepared = prepared(session, [:hang], probe: self(), block_start: true)

      assert {:error, :invalid_execution_owner_or_budget} =
               Supervisor.start_execution(c.supervisor, prepared)
    end

    assert DynamicSupervisor.which_children(c.supervisor) == []
    refute_receive {:fake_runner, _, _}, 50
    refute_receive {:fake_callback, _, _}, 50

    assert_raise FunctionClauseError, fn ->
      R5eRecurse.Execution.Callback.start(
        self(),
        :generation,
        make_ref(),
        fn -> flunk("must never run") end,
        4_294_967_296
      )
    end
  end

  test "injected guardian DOWN during cancellation cannot strand cancelling_wait", c do
    {worker, runner} = launch(c, [:hang], block_observe: true)
    assert_receive {:fake_callback, :observe, callback}, 1_000
    state = :sys.get_state(worker)
    guardian = state.callback.pid
    :erlang.suspend_process(guardian)

    try do
      assert :cancelling = Worker.cancel(worker, :test)
      assert :sys.get_state(worker).phase == :cancelling_wait
      send(worker, {:DOWN, state.callback.monitor, :process, guardian, :injected_failure})

      assert_receive {:execution, ^worker, _,
                      {:terminal,
                       %{state: :unknown, evidence: [%{reason: :callback_guardian_lost}]},
                       {:cancelled, :test}}},
                     1_000

      dead(worker)
    after
      :erlang.resume_process(guardian)
    end

    # This injects the notification; it does not claim forced guardian-kill cleanup.
    dead(callback)
    dead(guardian)
    dead(runner)
  end

  test "model completion does not end execution; nonzero exit retains code and obtains ownership",
       c do
    {worker, runner} = launch(c, [{:stdout, "done"}, {:model_completion, :done, [1]}, {:exit, 9}])
    assert_receive {:execution, ^worker, _, {:observations, [%{kind: :raw_chunk}]}}, 1_000
    assert_receive {:execution, ^worker, _, {:observations, [%{kind: :model_completion}]}}, 1_000

    assert_receive {:execution, ^worker, _,
                    {:observations, [%{kind: :os_exit, value: %{code: 9}}]}},
                   1_000

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, {:os_exit, 9}}}, 1_000
    dead(worker)
    refute Process.alive?(runner)
    assert DynamicSupervisor.which_children(c.supervisor) == []
  end

  test "hard deadline wins despite continuous output; idle independently fires on a hang", c do
    busy = %{
      c
      | session: %{
          c.session
          | budgets: Map.merge(c.session.budgets, %{idle_timeout_ms: 120, hard_timeout_ms: 220})
        }
    }

    {worker, runner} = launch(busy, List.duplicate({:stdout, "."}, 100))
    assert_receive {:execution, ^worker, _, {:observations, [_]}}, 1_000

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, {:hard, :deadline}}},
                   1_000

    dead(worker)
    refute Process.alive?(runner)

    idle = %{
      c
      | session: %{c.session | budgets: Map.put(c.session.budgets, :idle_timeout_ms, 80)}
    }

    {worker, runner} = launch(idle, [:hang])

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, {:idle, :deadline}}},
                   1_000

    dead(worker)
    refute Process.alive?(runner)
  end

  test "stale generation, same-generation timer tokens and callback references are ignored", c do
    {worker, _} = launch(c, [:hang, {:stdout, "activity"}, :hang])
    wait_running(worker)
    before = :sys.get_state(worker)
    assert :ok = Fake.release(before.handle)
    assert_receive {:execution, ^worker, _, {:observations, [_]}}, 1_000
    after_activity = :sys.get_state(worker)
    refute before.timers.idle == after_activity.timers.idle
    send(worker, {:deadline, before.generation, :idle, elem(before.timers.idle, 1)})
    send(worker, {:deadline, %{"bootId" => "stale"}, :hard, elem(before.timers.hard, 1)})
    send(worker, {:callback, before.generation, make_ref(), {:ok, {:error, :injected}}})
    assert Worker.status(worker).phase == :running
    assert :cancelling = Worker.cancel(worker, :test)

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, {:cancelled, :test}}},
                   1_000
  end

  test "submitting caller death stops stable worker and owned trapping runner", c do
    parent = self()

    owner =
      spawn(fn ->
        prepared = prepared(%{c.session | owner: self()}, [:hang], probe: parent)
        {:ok, worker} = Supervisor.start_execution(c.supervisor, prepared)
        send(parent, {:worker, worker})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:worker, worker}, 1_000
    assert_receive {:fake_runner, runner, ^worker}, 1_000
    send(owner, :stop)
    dead(worker)
    dead(runner)
  end

  test "start-spawn-then-block timeout kills callback and owner-bound runner without claiming stopped",
       c do
    {worker, runner} = launch(c, [:hang], block_start: true)
    assert_receive {:fake_callback, :start, callback}, 1_000

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :unknown}, :start_unconfirmed}},
                   1_000

    dead(worker)
    dead(callback)
    dead(runner)
  end

  test "abrupt worker death reaps a trapping blocked callback and pending-start runner", c do
    {worker, runner} = launch(c, [:hang], block_start: true)
    assert_receive {:fake_callback, :start, callback}, 1_000
    guardian = :sys.get_state(worker).callback.pid
    Process.exit(worker, :kill)
    dead(worker)
    dead(callback)
    dead(guardian)
    dead(runner)
    assert DynamicSupervisor.which_children(c.supervisor) == []
    refute_receive {:fake_runner, _, _}, 50
  end

  test "blocked observe is reaped before bounded cancel; blocked cancel preserves unknown", c do
    {worker, runner} = launch(c, [:hang], block_observe: true, block_cancel: true)
    assert_receive {:fake_callback, :observe, observing}, 1_000
    assert :cancelling = Worker.cancel(worker, :test)
    assert_receive {:fake_callback, :cancel, cancelling}, 1_000
    refute Process.alive?(observing)

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :unknown}, {:cancelled, :test}}},
                   1_000

    dead(cancelling)
    dead(worker)
    dead(runner)
  end

  test "cancellation uncertainty remains unknown even though owner-death cleanup follows", c do
    {worker, runner} = launch(c, [:hang], cancellation: :uncertain)
    wait_running(worker)
    assert :cancelling = Worker.cancel(worker, :test)

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :unknown}, {:cancelled, :test}}},
                   1_000

    dead(worker)
    dead(runner)
  end

  test "swapped handles and ownership identities are refused", c do
    prepared = prepared(c.session, [:hang], probe: self())
    {:ok, worker} = Supervisor.start_execution(c.supervisor, %{prepared | adapter: SwappedStart})
    assert_receive {:fake_runner, runner, ^worker}, 1_000

    assert_receive {:execution, ^worker, _,
                    {:terminal, %{state: :unknown}, :invalid_start_handle}},
                   1_000

    dead(worker)
    dead(runner)
    {:ok, worker} = Supervisor.start_execution(c.supervisor, %{prepared | adapter: SwappedHandle})
    assert_receive {:fake_runner, runner, ^worker}, 1_000

    assert_receive {:execution, ^worker, _,
                    {:terminal, %{state: :stopped}, :invalid_observation_handle}},
                   1_000

    dead(worker)
    dead(runner)

    {:ok, worker} =
      Supervisor.start_execution(c.supervisor, %{prepared | adapter: SwappedOwnership})

    assert_receive {:fake_runner, runner, ^worker}, 1_000
    wait_running(worker)
    Worker.cancel(worker, :test)

    assert_receive {:execution, ^worker, _,
                    {:terminal,
                     %{state: :unknown, evidence: [%{reason: :invalid_ownership_identity}]}, _}},
                   1_000

    dead(worker)
    dead(runner)
  end

  test "cleanup deadline cannot erase observed nonzero exit or capture failure", c do
    c = %{c | session: %{c.session | budgets: Map.put(c.session.budgets, :idle_timeout_ms, 80)}}

    for {step, expected} <- [
          {{:exit, 7}, {:os_exit, 7}},
          {{:capture_failure, :spool_fault}, :capture_incomplete}
        ] do
      {worker, runner} = launch(c, [step], block_reconcile: true, block_cancel: true)
      assert_receive {:execution, ^worker, _, {:observations, [_]}}, 1_000
      assert_receive {:fake_callback, :reconcile, reconcile_callback}, 1_000
      assert_receive {:fake_callback, :cancel, cancel_callback}, 1_000
      refute Process.alive?(reconcile_callback)

      assert_receive {:execution, ^worker, _,
                      {:terminal, %{state: :unknown},
                       %{observation: ^expected, cleanup: {:idle, :deadline}}}},
                     1_000

      dead(worker)
      dead(runner)
      dead(cancel_callback)
    end
  end

  test "capture failure stays incomplete and restarting supervisor relaunches nothing", c do
    {worker, _} = launch(c, [{:capture_failure, :spool_fault}])

    assert_receive {:execution, ^worker, _, {:observations, [%{kind: :capture_incomplete}]}},
                   1_000

    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, :capture_incomplete}},
                   1_000

    dead(worker)
    {worker, runner} = launch(c, [:hang])
    assert :ok = stop_supervised(Supervisor)
    dead(worker)
    dead(runner)
    successor = start_supervised!(Supervisor)
    assert DynamicSupervisor.which_children(successor) == []
    refute_receive {:fake_runner, _, _}, 50
  end

  defp launch(c, script, options \\ []) do
    {:ok, worker} =
      Supervisor.start_execution(
        c.supervisor,
        prepared(c.session, script, Keyword.put(options, :probe, self()))
      )

    assert_receive {:fake_runner, runner, ^worker}, 1_000
    {worker, runner}
  end

  defp prepared(session, script, opts) do
    {:ok, prepared} =
      Fake.prepare(%{session | adapter_options: Map.put(Map.new(opts), :script, script)})

    %{prepared | launch_ref: event("c")}
  end

  defp wait_running(worker) do
    case Worker.status(worker).phase do
      :running ->
        :ok

      :starting ->
        Process.sleep(1)
        wait_running(worker)
    end
  end

  defp dead(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
  end

  defp event(c), do: "event:sha256:" <> String.duplicate(c, 64)
end
