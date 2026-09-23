# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.LocalCLITest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Execution.{LocalCLI, Spool, Supervisor, Worker}
  alias R5eRecurse.Execution.Adapter.Session

  defmodule ReconcileTimeout do
    def start(p) do
      with {:ok, h} <- LocalCLI.start(%{p | adapter: LocalCLI}),
           do: {:ok, %{h | adapter: __MODULE__}}
    end

    def observe(h) do
      with {:ok, events, next} <- LocalCLI.observe(%{h | adapter: LocalCLI}),
           do: {:ok, events, %{next | adapter: __MODULE__}}
    end

    def cancel(h, reason), do: LocalCLI.cancel(%{h | adapter: LocalCLI}, reason)
    def reconcile(_), do: Process.sleep(:infinity)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "launcher-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    session = %Session{
      id: "fixture",
      generation: %{"bootId" => "boot", "runId" => "run"},
      owner: self(),
      binding_ref: "event:binding",
      context_ref: "event:context",
      rendered_input: "input",
      workspace: root,
      model: "fixture",
      auth_mode: :external,
      route: nil,
      budgets: %{grace_timeout_ms: 50, drain_timeout_ms: 200},
      adapter_options: %{
        executable: "/bin/sh",
        args: [],
        env: %{"PATH" => "/usr/bin:/bin"},
        spool_root: root
      }
    }

    %{root: root, session: session}
  end

  test "stdout/stderr exact bytes survive nonzero exit and durable diagnostic recovery", c do
    h = launch(c.session, ["-c", "printf 'done'; printf 'noise' >&2; exit 9"])
    events = collect(h)
    assert raw(events, :stdout) == "done"
    assert raw(events, :stderr) == "noise"
    assert Enum.find(events, &(&1.kind == :os_exit)).value.code == 9
    {:ok, ownership} = LocalCLI.reconcile(%{handle: h})
    assert ownership.state == :stopped
    assert {:ok, %{complete: true, accounted: 14}} = Spool.recover(ownership.spool.root)
  end

  test "missing executable refuses preparation and removal before exec reports127", c do
    assert {:error, _} =
             LocalCLI.prepare(%{
               c.session
               | adapter_options: %{c.session.adapter_options | executable: "/missing"}
             })

    exe = Path.join(c.root, "removed")
    File.write!(exe, "#!/bin/sh\nexit 0\n")
    File.chmod!(exe, 0o700)

    {:ok, p} =
      LocalCLI.prepare(%{
        c.session
        | adapter_options: %{c.session.adapter_options | executable: exe}
      })

    File.rm!(exe)
    {:ok, h} = LocalCLI.start(%{p | launch_ref: "event:launch"})
    assert Enum.find(collect(h), &(&1.kind == :os_exit)).value.code == 127
  end

  test "final file is retained without deleting its evidence; symlink refused", c do
    s = %{c.session | adapter_options: Map.put(c.session.adapter_options, :result_file, "result")}

    {:ok, p} =
      LocalCLI.prepare(%{
        s
        | adapter_options: %{s.adapter_options | args: ["-c", "printf result > result"]}
      })

    # The configured private final-file root is the per-run spool, not cwd.
    p = %{
      p
      | session: %{p.session | workspace: p.invocation.spool.root},
        launch_ref: "event:launch"
    }

    {:ok, h} = LocalCLI.start(p)
    events = collect(h)
    assert raw(events, :result_file) == "result"
    assert File.read!(Path.join(p.invocation.spool.root, "result")) == "result"

    {:ok, p2} =
      LocalCLI.prepare(%{
        s
        | adapter_options: %{s.adapter_options | args: ["-c", "ln -s /etc/passwd result"]}
      })

    p2 = %{
      p2
      | session: %{p2.session | workspace: p2.invocation.spool.root},
        launch_ref: "event:launch"
    }

    {:ok, h2} = LocalCLI.start(p2)
    assert Enum.any?(collect(h2), &(&1.kind == :capture_incomplete))
  end

  test "large newline-free output exhausts budget explicitly and future requests reserve bytes",
       c do
    s = %{c.session | budgets: Map.put(c.session.budgets, :trace_bytes, 100)}
    h = launch(s, ["-c", "yes x | head -c 20000"])
    events = collect(h)
    assert Enum.any?(events, &(&1.kind == :capture_incomplete))
    assert byte_size(raw(events, :stdout)) <= 95
    {:ok, o} = LocalCLI.reconcile(%{handle: h})
    assert {:ok, %{complete: false}} = Spool.recover(o.spool.root)
    h2 = launch(s, ["-c", "sleep 20"])
    assert {:error, :trace_budget} = LocalCLI.account_request(h2, 101)
    assert Enum.any?(collect(h2), &(&1.kind == :capture_incomplete))
  end

  test "spool failure is incomplete and raw intent remains recoverably uncertain", c do
    {:ok, spool} = Spool.create(c.root, "abc", 100, 4)
    assert {:ok, spool} = Spool.account(spool, 5)
    File.mkdir!(Path.join(spool.root, "stdout-1.raw"))
    assert {:error, failed} = Spool.append(spool, :stdout, 1, "hello")
    assert failed.incomplete == :spool_write_failed
    assert {:ok, %{complete: false, accounted: 17, pending: pending}} = Spool.recover(spool.root)
    assert map_size(pending) == 1
  end

  test "bounded split JSON/UTF8 parser cites original sequence ranges", _c do
    alias Spool.JsonLines
    data = Jason.encode!(%{"v" => "😀"}) <> "\n"

    for split <- 1..(byte_size(data) - 1) do
      <<a::binary-size(split), b::binary>> = data
      assert {:ok, [], state} = JsonLines.push(JsonLines.new(), 1, a)
      assert {:ok, [event], state} = JsonLines.push(state, 2, b)
      assert event.value == %{"v" => "😀"}
      assert Enum.map(event.coverage, & &1.sequence) == [1, 2]
      assert Enum.sum(Enum.map(event.coverage, & &1.bytes)) == byte_size(data)
      assert :ok = JsonLines.finish(state)
    end

    assert {:error, :frame_limit} = JsonLines.push(JsonLines.new(8), 1, "123456789")
    assert {:ok, [], state} = JsonLines.push(JsonLines.new(), 1, "{\"")
    assert {:error, :incomplete_frame} = JsonLines.finish(state)
  end

  test "worker owner death closes helper control and no supervisor restart relaunches", c do
    supervisor = start_supervised!(Supervisor)
    parent = self()

    owner =
      spawn(fn ->
        s = %{
          c.session
          | owner: self(),
            adapter_options: %{
              c.session.adapter_options
              | args: ["-c", "while :; do echo beat; sleep .02; done"]
            }
        }

        {:ok, p} = LocalCLI.prepare(s)
        {:ok, w} = Supervisor.start_execution(supervisor, %{p | launch_ref: "event:launch"})
        send(parent, {:worker, w})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:worker, worker}
    wait_phase(worker, :running)
    state = :sys.get_state(worker)
    {broker, _} = state.handle.state
    monitor = Process.monitor(broker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^broker, _}, 2_000
    assert DynamicSupervisor.which_children(supervisor) == []
    assert {:ok, %{state: :unknown}} = LocalCLI.reconcile(%{pid: 123, group: 123})
  end

  test "production cancellation budgets cover cleanup and explicit short callback budget refuses",
       c do
    session = %{
      c.session
      | budgets: %{},
        adapter_options: %{c.session.adapter_options | args: ["-c", "echo ready; exec sleep 30"]}
    }

    {:ok, prepared} = LocalCLI.prepare(session)

    assert prepared.session.budgets == %{
             grace_timeout_ms: 5_000,
             drain_timeout_ms: 5_000,
             callback_timeout_ms: 12_000
           }

    assert {:error, _} = LocalCLI.prepare(%{session | budgets: %{callback_timeout_ms: 1_000}})
    supervisor = start_supervised!(Supervisor)

    {:ok, worker} =
      Supervisor.start_execution(supervisor, %{prepared | launch_ref: "event:launch"})

    assert_receive {:execution, ^worker, _, {:observations, [_ | _]}}, 2_000
    assert :cancelling = Worker.cancel(worker, :test)
    assert_receive {:execution, ^worker, _, {:terminal, %{state: :stopped}, _}}, 12_000
  end

  test "helper loss reports unobserved target status, never fabricated OS exit", c do
    h = launch(c.session, ["-c", "sleep 30"])
    {broker, _} = h.state
    state = :sys.get_state(broker)
    # Closing the port exercises control-pipe loss and helper cleanup, not helper SIGKILL.
    Port.close(state.port)
    send(broker, {state.port, {:exit_status, 3}})
    events = collect(h)
    refute Enum.any?(events, &(&1.kind == :os_exit))
    assert Enum.find(events, &(&1.kind == :capture_incomplete)).value.target_status == :unobserved
  end

  test "actual BEAM process death closes the helper pipe and stops heartbeats", c do
    beat = Path.join(c.root, "heartbeat")
    fixture = Path.expand("test/fixtures/procs/file_heartbeat.sh")
    fields = c.session |> Map.from_struct() |> Map.put(:owner, nil)
    fields = %{fields | adapter_options: %{fields.adapter_options | args: [fixture, beat]}}

    source = """
    Application.load(:r5e_recurse)
    Application.ensure_all_started(:crypto)
    session = struct(R5eRecurse.Execution.Adapter.Session, #{Macro.to_string(Macro.escape(fields))})
    session = %{session | owner: self()}
    {:ok, p} = R5eRecurse.Execution.LocalCLI.prepare(session)
    {:ok, _} = R5eRecurse.Execution.LocalCLI.start(%{p | launch_ref: "event:launch"})
    IO.puts("STARTED")
    Process.sleep(:infinity)
    """

    file = Path.join(c.root, "child_vm.exs")
    File.write!(file, source)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ [file]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("elixir"))},
        [:binary, :exit_status, {:args, args}, {:env, [{~c"ERL_FLAGS", ~c"+S 2:2"}]}]
      )

    assert_receive {^port, {:data, "STARTED\n"}}, 5_000
    wait_file(beat)
    {:os_pid, pid} = Port.info(port, :os_pid)

    assert {_, 0} =
             System.cmd("python3", [
               "-c",
               "import os,signal,sys; os.kill(int(sys.argv[1]),signal.SIGKILL)",
               Integer.to_string(pid)
             ])

    assert_receive {^port, {:exit_status, _}}, 5_000
    Process.sleep(500)
    bytes = File.read!(beat)
    Process.sleep(200)
    assert File.read!(beat) == bytes
  end

  test "fixture byte streams remain raw and final framing is independently derived", c do
    fixture = Path.expand("test/fixtures/procs/split_json.sh")
    h = launch(c.session, [fixture])
    events = collect(h)
    assert raw(events, :stdout) == Jason.encode!(%{"v" => "😀"}) <> "\n"
    assert Enum.all?(Enum.filter(events, &(&1.source == :stdout)), &(&1.kind == :raw_chunk))
  end

  test "hard deadline fires despite real continuous output", c do
    supervisor = start_supervised!(Supervisor)

    session = %{
      c.session
      | budgets: Map.merge(c.session.budgets, %{hard_timeout_ms: 150, idle_timeout_ms: 1_000}),
        adapter_options: %{
          c.session.adapter_options
          | args: ["-c", "while :; do echo beat; sleep .01; done"]
        }
    }

    {:ok, prepared} = LocalCLI.prepare(session)

    {:ok, worker} =
      Supervisor.start_execution(supervisor, %{prepared | launch_ref: "event:launch"})

    assert_receive {:execution, ^worker, _, {:terminal, ownership, {:hard, :deadline}}}, 3_000
    assert ownership.state in [:stopped, :unknown]
    assert Enum.any?(ownership.evidence, &(&1.cleanup in [:observed_group_gone, :unknown]))
  end

  test "real broker spool refusal ACKs bounded frame then cleans up", c do
    s = %{
      c.session
      | adapter_options: %{c.session.adapter_options | args: ["-c", "echo output; sleep 20"]}
    }

    {:ok, p} = LocalCLI.prepare(s)
    File.mkdir!(Path.join(p.invocation.spool.root, "stdout-1.raw"))
    {:ok, h} = LocalCLI.start(%{p | launch_ref: "event:launch"})
    events = collect(h)
    assert Enum.any?(events, &(&1.kind == :capture_incomplete))
    {:ok, o} = LocalCLI.reconcile(%{handle: h})
    assert o.state == :stopped
    assert {:ok, %{complete: false}} = Spool.recover(o.spool.root)

    assert {:error, :invalid_live_capability} =
             LocalCLI.cancel(%{h | state: {elem(h.state, 0), make_ref()}}, :test)
  end

  test "worker kill independently closes helper and stops real file output", c do
    beat = Path.join(c.root, "worker-heartbeat")
    fixture = Path.expand("test/fixtures/procs/file_heartbeat.sh")
    session = %{c.session | adapter_options: %{c.session.adapter_options | args: [fixture, beat]}}
    {:ok, p} = LocalCLI.prepare(session)
    supervisor = start_supervised!(Supervisor)
    {:ok, worker} = Supervisor.start_execution(supervisor, %{p | launch_ref: "event:launch"})
    wait_phase(worker, :running)
    wait_file(beat)
    {broker, _} = :sys.get_state(worker).handle.state
    :ok = :sys.suspend(broker)
    monitor = Process.monitor(broker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^broker, :killed}, 1_000
    Process.sleep(500)
    bytes = File.read!(beat)
    Process.sleep(150)
    assert File.read!(beat) == bytes
    assert DynamicSupervisor.which_children(supervisor) == []
  end

  test "recovery never promotes partial indexes or mutated raw bytes to complete", c do
    {:ok, spool} = Spool.create(c.root, "input", 100)
    {:ok, spool, entry} = Spool.append(spool, :stdout, 1, "exact")
    {:ok, spool} = Spool.finish(spool, %{capture_incomplete: false})
    assert {:ok, %{complete: true}} = Spool.recover(spool.root)
    File.write!(Path.join(spool.root, entry.path), "other")
    assert {:ok, %{complete: false}} = Spool.recover(spool.root)
    File.write!(Path.join(spool.root, "record-000005.json"), "{partial")
    assert {:error, :incomplete_local_spool} = Spool.recover(spool.root)
  end

  test "stronger descendant requirement refuses and dead live owner remains unknown", c do
    assert {:error, _} =
             LocalCLI.prepare(%{
               c.session
               | adapter_options:
                   Map.put(c.session.adapter_options, :required_descendants, :contained)
             })

    h = launch(c.session, ["-c", "echo done"])
    collect(h)
    {broker, _} = h.state
    GenServer.stop(broker)
    assert {:ok, %{state: :unknown, identity: identity}} = LocalCLI.reconcile(%{handle: h})
    assert identity == h.identity
  end

  test "incomplete capture plus actual exit or signal survives timed-out reconciliation", c do
    supervisor = start_supervised!(Supervisor)

    for {command, status} <- [
          {"printf x; exit 9", {:os_exit, 9}},
          {"printf x; kill -TERM $$", {:os_signal, 15}}
        ] do
      session = %{
        c.session
        | budgets: Map.put(c.session.budgets, :trace_bytes, 5),
          adapter_options: %{c.session.adapter_options | args: ["-c", command]}
      }

      {:ok, p} = LocalCLI.prepare(session)

      {:ok, worker} =
        Supervisor.start_execution(supervisor, %{
          p
          | adapter: ReconcileTimeout,
            launch_ref: "event:launch"
        })

      assert_receive {:execution, ^worker, _, {:observations, events}}, 2_000
      assert Enum.any?(events, &(&1.kind == :capture_incomplete))
      observed = Enum.find(events, &(&1.kind == :os_exit)).value

      case status do
        {:os_exit, code} -> assert observed.code == code
        {:os_signal, signal} -> assert observed.signal == signal
      end

      assert_receive {:execution, ^worker, _,
                      {:terminal, %{state: :unknown},
                       %{exit: ^status, capture: :capture_incomplete}}},
                     4_000
    end
  end

  test "30/31/32 raw boundaries keep paired terminal evidence in one bounded batch", c do
    for count <- [30, 31, 32] do
      session = %{c.session | budgets: Map.put(c.session.budgets, :trace_bytes, 5)}
      h = launch(session, ["-c", "printf x; exit 9"])
      {broker, _} = h.state
      wait_outcome(broker)
      {:ok, spool} = Spool.create(c.root, "", 10_000)

      {spool, raw} =
        Enum.reduce(1..count, {spool, []}, fn seq, {spool, entries} ->
          {:ok, next, entry} = Spool.append(spool, :stdout, seq, "x")
          {next, entries ++ [{:raw, entry}]}
        end)

      :sys.replace_state(broker, fn s ->
        [{:terminal, events}] = :queue.to_list(s.queue)

        events =
          events
          |> Enum.with_index(count + 1)
          |> Enum.map(fn {e, seq} -> %{e | sequence: seq} end)

        %{s | spool: spool, queue: :queue.from_list(raw ++ [{:terminal, events}])}
      end)

      {:ok, first, _} = LocalCLI.observe(h)
      {:ok, second, _} = LocalCLI.observe(h)
      assert length(first) <= 32 and length(second) <= 32

      for batch <- [first, second], Enum.any?(batch, &(&1.kind == :capture_incomplete)) do
        assert Enum.find(batch, &(&1.kind == :os_exit)).value.code == 9
      end

      assert Enum.map(first ++ second, & &1.sequence) == Enum.to_list(1..(count + 2))
      assert Enum.count(first ++ second, &(&1.kind == :capture_incomplete)) == 1
    end
  end

  defp wait_outcome(broker, attempts \\ 200)
  defp wait_outcome(_, 0), do: flunk("helper did not report terminal outcome")

  defp wait_outcome(broker, attempts) do
    if :sys.get_state(broker).outcome != nil,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_outcome(broker, attempts - 1)
        )
  end

  defp wait_file(path, attempts \\ 200)
  defp wait_file(_, 0), do: flunk("workload did not emit a heartbeat")

  defp wait_file(path, attempts) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        :ok

      _ ->
        Process.sleep(10)
        wait_file(path, attempts - 1)
    end
  end

  defp launch(session, args) do
    {:ok, p} =
      LocalCLI.prepare(%{session | adapter_options: %{session.adapter_options | args: args}})

    assert {:error, :launch_not_admitted} = LocalCLI.start(p)
    {:ok, h} = LocalCLI.start(%{p | launch_ref: "event:launch"})
    h
  end

  defp collect(h, acc \\ [], attempts \\ 500)
  defp collect(_, _, 0), do: flunk("helper did not finish")

  defp collect(h, acc, attempts) do
    {:ok, events, h} = LocalCLI.observe(h)
    all = acc ++ events

    if Enum.any?(events, &(&1.kind in [:os_exit, :capture_incomplete])),
      do: all,
      else:
        (
          Process.sleep(10)
          collect(h, all, attempts - 1)
        )
  end

  defp raw(events, stream),
    do:
      events
      |> Enum.filter(&(&1.source == stream and &1.kind == :raw_chunk))
      |> Enum.map(& &1.value)
      |> IO.iodata_to_binary()

  defp wait_phase(worker, phase, n \\ 100)
  defp wait_phase(_, _, 0), do: flunk("worker not running")

  defp wait_phase(w, phase, n) do
    if Worker.status(w).phase == phase,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_phase(w, phase, n - 1)
        )
  end
end
