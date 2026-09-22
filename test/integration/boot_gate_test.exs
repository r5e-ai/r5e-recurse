defmodule R5eRecurse.BootGateTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Boot

  test "revocation failure keeps gate closed and recovery is narrowly scoped" do
    boundary = %{
      interrupted: fn -> {:ok, [%{badge: "old", issuer: "deployment"}]} end,
      reconcile: fn b -> {:ok, b} end,
      admit: fn
        :observation, _ ->
          {:ok, %{event_ref: "event:sha256:" <> String.duplicate("a", 64), kind: :observation}}

        :revocation, _ ->
          {:error, :issuer_unavailable}
      end
    }

    {:ok, boot} = Boot.start_link(boundary: boundary)
    refute Boot.mutation_allowed?(boot)

    assert {:error, :boot_reconciliation_required} =
             Boot.execute(boot, fn -> flunk("mutation dispatched") end)

    assert {:error, :issuer_unavailable} = Boot.reconcile(boot)
    refute Boot.mutation_allowed?(boot)
    assert {:ok, _} = Boot.recover(boot, :observation, %{})
    assert {:error, :recovery_kind_forbidden} = Boot.recover(boot, :launch, %{})
  end

  test "every interrupted badge needs confirmed observation and revocation before opening" do
    test = self()

    boundary = %{
      interrupted: fn ->
        {:ok, [%{badge: "a", issuer: "deployment"}, %{badge: "b", issuer: "deployment"}]}
      end,
      reconcile: fn b -> {:ok, b} end,
      admit: fn kind, b ->
        send(test, {kind, b})

        {:ok,
         Map.merge(b, %{event_ref: "event:sha256:" <> String.duplicate("a", 64), kind: kind})}
      end
    }

    {:ok, boot} = Boot.start_link(boundary: boundary)
    assert :ok = Boot.reconcile(boot)
    assert Boot.mutation_allowed?(boot)
    assert :dispatched = Boot.execute(boot, fn -> :dispatched end)

    for badge <- ["a", "b"],
        kind <- [:observation, :revocation],
        do: assert_received({^kind, %{badge: ^badge}})
  end

  defmodule GateStore do
    def history(pid) do
      send(pid, :history_read)
      {:ok, []}
    end

    def submit(_, _, _), do: raise("must never submit")
  end

  test "managed Commands refuses before history refresh or journal; lookups remain available" do
    {:ok, boot} = Boot.start_link(boundary: %{})
    origin = RecurseVerify.Canonical.hash("gate-#{System.unique_integer([:positive])}")

    {:ok, commands} =
      R5eRecurse.Commands.start_link(origin: origin, store: {GateStore, self()}, boot_gate: boot)

    assert_received :history_read

    assert {:error, :boot_reconciliation_required} =
             R5eRecurse.Commands.submit(commands, %{}, %{})

    refute_received :history_read
    assert {:outcome_unknown, _} = R5eRecurse.Commands.lookup(commands, "caller", "id")
    assert_received :history_read
    GenServer.stop(commands)
  end

  test "mismatched issuer or badge receipt cannot open gate" do
    binding = %{badge: "expected", issuer: "issuer"}

    boundary = %{
      interrupted: fn -> {:ok, [binding]} end,
      reconcile: fn b -> {:ok, b} end,
      admit: fn kind, b ->
        {:ok,
         Map.merge(b, %{
           kind: kind,
           badge: "different",
           event_ref: "event:sha256:" <> String.duplicate("a", 64)
         })}
      end
    }

    {:ok, boot} = Boot.start_link(boundary: boundary)
    assert {:error, :revocation_target_mismatch} = Boot.reconcile(boot)
    refute Boot.mutation_allowed?(boot)
  end

  test "mutation callback failure stays uncertain and closes the gate" do
    {:ok, boot} = Boot.start_link(boundary: %{interrupted: fn -> {:ok, []} end})
    assert :ok = Boot.reconcile(boot)
    caller = self()

    assert {:outcome_unknown, %{reason: :mutation_callback_failed}} =
             Boot.execute(boot, fn ->
               send(caller, :effect_happened)
               raise "after effect"
             end)

    assert_received :effect_happened
    refute Boot.mutation_allowed?(boot)
  end

  test "malformed callback success never opens the gate" do
    {:ok, boot} = Boot.start_link(boundary: %{interrupted: fn -> :ok end})
    assert {:error, :malformed_interrupted_bindings} = Boot.reconcile(boot)
    refute Boot.mutation_allowed?(boot)

    {:ok, boot} =
      Boot.start_link(
        boundary: %{
          interrupted: fn -> {:ok, [%{badge: "b", issuer: "i"}]} end,
          reconcile: fn _ -> :ok end
        }
      )

    assert {:error, :malformed_reconciliation} = Boot.reconcile(boot)
    refute Boot.mutation_allowed?(boot)
  end

  test "uncertain recovery closes an already open gate and retains its outcome" do
    uncertain =
      {:outcome_unknown,
       %{reason: :lost_ack, event_ref: "event:sha256:" <> String.duplicate("a", 64)}}

    boundary = %{interrupted: fn -> {:ok, []} end, admit: fn _, _ -> uncertain end}
    {:ok, gate} = Boot.start_link(boundary: boundary)
    assert :ok = Boot.reconcile(gate)
    assert Boot.mutation_allowed?(gate)
    assert ^uncertain = Boot.recover(gate, :revocation, %{})
    refute Boot.mutation_allowed?(gate)

    boundary =
      %{boundary | interrupted: fn -> {:ok, [%{badge: "b", issuer: "i"}]} end}
      |> Map.put(:reconcile, fn b -> {:ok, b} end)

    {:ok, gate} = Boot.start_link(boundary: boundary)
    assert ^uncertain = Boot.reconcile(gate)
    refute Boot.mutation_allowed?(gate)
  end

  test "recorded recovery denials and conflicts retain details and keep the gate closed" do
    for result <- [
          {:denied, %{"eventRef" => "event:sha256:" <> String.duplicate("a", 64)}},
          {:conflict, %{operation_id: "recovery", reason: :candidate_changed}}
        ] do
      boundary = %{interrupted: fn -> {:ok, []} end, admit: fn _, _ -> result end}
      {:ok, gate} = Boot.start_link(boundary: boundary)
      assert :ok = Boot.reconcile(gate)
      assert ^result = Boot.recover(gate, :observation, %{})
      refute Boot.mutation_allowed?(gate)
      GenServer.stop(gate)

      boundary =
        Map.merge(boundary, %{
          interrupted: fn -> {:ok, [%{badge: "b", issuer: "i"}]} end,
          reconcile: fn binding -> {:ok, binding} end
        })

      {:ok, gate} = Boot.start_link(boundary: boundary)
      assert ^result = Boot.reconcile(gate)
      refute Boot.mutation_allowed?(gate)
      GenServer.stop(gate)
    end
  end
end
