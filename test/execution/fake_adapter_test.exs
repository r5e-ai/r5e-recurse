# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.FakeAdapterTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.FakeAdapter, as: Fake
  alias R5eRecurse.Execution.Adapter.{Session, Prepared, Ownership}

  setup do
    session = %Session{
      id: "fake-session",
      generation: %{"bootId" => "boot", "runId" => "run"},
      owner: self(),
      binding_ref: event("a"),
      context_ref: event("b"),
      rendered_input: "private rendered input",
      workspace: System.tmp_dir!(),
      model: "fake-model",
      auth_mode: :fake,
      route: %{credential: "route-secret-do-not-print"},
      budgets: %{max_output_bytes: 100, max_chunk_bytes: 50},
      adapter_options: %{script: []}
    }

    %{session: session}
  end

  test "preparation refuses missing executable and launch has a separate structural prerequisite",
       %{session: session} do
    assert {:error, :missing_executable} =
             Fake.prepare(%{session | adapter_options: %{script: [], executable: :missing}})

    assert {:ok, %Prepared{} = prepared} = Fake.prepare(session)
    assert prepared.launch_ref == nil
    assert {:error, :launch_reference_required} = Fake.start(prepared)
    assert {:error, :invalid_session} = Fake.prepare(%{session | auth_mode: :subscription})

    assert {:error, :invalid_options} =
             Fake.prepare(%{session | adapter_options: %{script: [], signing_key: "forbidden"}})

    assert Fake.capabilities().harness == "scripted-beam-fixture"
    assert Fake.capabilities().descendants == :unobserved
  end

  test "model done then nonzero exit stays two different observations", %{session: session} do
    handle =
      start(session, [{:stdout, "done"}, {:model_completion, %{message: "done"}, [1]}, {:exit, 7}])

    {pid, _} = handle.identity
    assert {:ok, [raw], handle} = Fake.observe(handle)
    assert {raw.sequence, raw.source, raw.kind, raw.value} == {1, :stdout, :raw_chunk, "done"}
    assert {:ok, [model], handle} = Fake.observe(handle)
    assert model.kind == :model_completion
    assert model.sequence == 2

    assert model.coverage == [
             %{
               sequence: 1,
               source: :stdout,
               bytes: 4,
               digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, "done"), case: :lower)
             }
           ]

    assert Process.alive?(pid)
    assert {:ok, [exit], stopped} = Fake.observe(handle)
    assert exit.kind == :os_exit
    assert exit.value == %{code: 7, simulated: true}
    refute Process.alive?(pid)
    assert {:ok, [], ^stopped} = Fake.observe(stopped)
    assert {:ok, %{state: :stopped}} = Fake.reconcile(%{handle: stopped})
    assert {:ok, %{state: :unknown}} = Fake.reconcile(%{handle: handle})
  end

  test "raw split UTF8 and JSON, stderr, and final-file bytes retain exact stream order", %{
    session: session
  } do
    chunks = [
      {:stdout, <<123, 34, 120, 34, 58, 34, 0xE2>>},
      {:stderr, "noise\n"},
      {:stdout, <<0x82, 0xAC, 34, 125>>},
      {:result_file, "final-file-only\n"}
    ]

    handle = start(session, chunks ++ [{:exit, 0}])

    {observed, _handle} =
      Enum.map_reduce(chunks, handle, fn _, handle ->
        assert {:ok, [event], next} = Fake.observe(handle)
        {event, next}
      end)

    assert Enum.map(observed, &{&1.source, &1.value}) == chunks
    assert Enum.map(observed, & &1.sequence) == [1, 2, 3, 4]
    assert Enum.all?(observed, &(&1.kind == :raw_chunk))
  end

  test "hang gives no synthetic success; uncertain cancellation leaves the same process live", %{
    session: session
  } do
    handle = start(session, [:hang, {:stdout, "late"}, {:exit, 0}], cancellation: :uncertain)
    {pid, _} = handle.identity
    assert {:ok, [], ^handle} = Fake.observe(handle)

    assert {:ok, %Ownership{state: :unknown, evidence: [%{simulated: true}]}} =
             Fake.cancel(handle, :deadline)

    assert Process.alive?(pid)
    assert {:ok, %{state: :live, identity: identity}} = Fake.reconcile(%{handle: handle})
    assert identity == handle.identity
    assert {:ok, [], ^handle} = Fake.observe(handle)
    assert :ok = Fake.release(handle)
    assert {:ok, [%{value: "late"}], next} = Fake.observe(handle)
    assert {:ok, [%{kind: :os_exit}], _} = Fake.observe(next)
    refute Process.alive?(pid)
  end

  test "confirmed cancellation waits for real fixture process death; refusal stays refusal", %{
    session: session
  } do
    handle = start(session, [:hang])
    {pid, _} = handle.identity
    assert {:ok, %{state: :stopped}} = Fake.cancel(handle, :cancelled)
    refute Process.alive?(pid)
    refused = start(session, [:hang], cancellation: :refuse)
    assert {:error, :cancellation_refused} = Fake.cancel(refused, :cancelled)
    assert Process.alive?(elem(refused.identity, 0))
  end

  test "reconciliation is read-only, refuses unknown identity and never consumes a pending script",
       %{session: session} do
    handle = start(session, [{:stdout, "first"}, :hang])
    assert {:ok, %{state: :unknown}} = Fake.reconcile(%{pid: elem(handle.identity, 0)})
    wrong = %{handle | identity: {elem(handle.identity, 0), make_ref()}}
    assert {:ok, %{state: :unknown}} = Fake.reconcile(%{handle: wrong})
    for _ <- 1..3, do: assert({:ok, %{state: :live}} = Fake.reconcile(%{handle: handle}))
    assert {:ok, [%{sequence: 1, value: "first"}], _} = Fake.observe(handle)
    refusing = start(session, [:hang], reconciliation: :refuse)
    assert {:error, :reconciliation_refused} = Fake.reconcile(%{handle: refusing})
    assert {:ok, [], ^refusing} = Fake.observe(refusing)
    Process.exit(elem(handle.identity, 0), :kill)
    monitor = Process.monitor(elem(handle.identity, 0))
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert {:ok, %{state: :unknown, identity: identity}} = Fake.reconcile(%{handle: handle})
    assert identity == handle.identity
    refute Process.alive?(elem(identity, 0))
  end

  test "oversized newline-free output, spool fault, and invented parsed coverage stop incomplete",
       %{session: session} do
    for script <- [
          [{:stdout, String.duplicate("x", 51)}, {:exit, 0}],
          [{:capture_failure, :spool_unavailable}, {:exit, 0}],
          [{:model_completion, :done, [42]}, {:exit, 0}]
        ] do
      handle = start(session, script)

      assert {:ok, [%{kind: :capture_incomplete, value: %{simulated: true}}], stopped} =
               Fake.observe(handle)

      refute Process.alive?(elem(handle.identity, 0))
      assert {:ok, [], ^stopped} = Fake.observe(stopped)
    end

    limited = %{session | budgets: %{max_output_bytes: 5, max_chunk_bytes: 5}}
    handle = start(limited, [{:stdout, "123"}, {:stderr, "456"}])
    assert {:ok, [_], handle} = Fake.observe(handle)
    assert {:ok, [%{kind: :capture_incomplete}], _} = Fake.observe(handle)
  end

  test "session routing and input do not leak through Inspect or ownership evidence", %{
    session: session
  } do
    {:ok, prepared} = Fake.prepare(session)
    handle = start(session, [:hang])
    {:ok, ownership} = Fake.reconcile(%{handle: handle})

    for value <- [session, prepared, handle, ownership] do
      refute inspect(value) =~ "route-secret-do-not-print"
      refute inspect(value) =~ "private rendered input"
    end

    refute inspect(ownership.evidence) =~ "route-secret-do-not-print"
    assert :sys.get_status(elem(handle.identity, 0)) |> inspect() |> String.contains?("redacted")
  end

  defp start(session, script, opts \\ []) do
    options = Map.merge(Map.new(opts), %{script: script})
    {:ok, prepared} = Fake.prepare(%{session | adapter_options: options})
    {:ok, handle} = Fake.start(%{prepared | launch_ref: event("c")})

    on_exit(fn ->
      {pid, _} = handle.identity
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
    end)

    handle
  end

  defp event(character), do: "event:sha256:" <> String.duplicate(character, 64)
end
