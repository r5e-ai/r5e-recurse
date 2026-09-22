defmodule R5eRecurse.BootDiscoveryKernelTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.PolicyBaseTest, as: Fixture
  alias R5eRecurse.{Boot.Discovery, KernelClient}
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)
  @compile {:no_warn_undefined, [R5e.HTTP.Router, R5e.Origin, R5e.Request]}

  test "actual admitted preparation and server-named span produce an uncited binding inventory" do
    check_inventory(nil)
  end

  test "actual kernel admits a binding after failure and discovery keeps it blocked" do
    check_inventory("failed")
  end

  test "actual kernel admits a binding after interruption and discovery keeps it blocked" do
    check_inventory("interrupted")
  end

  defp check_inventory(closure) do
    span_kind = File.read!("test/fixtures/gateway/agent-session.json") |> Jason.decode!()
    {:ok, c} = Fixture.setup_fixture(span_kind)
    generation = c.binding["generation"]

    preparing = %{
      "task" => ref(c.task["eventRef"]),
      "commandId" => "discovery-fixture-preparation",
      "generation" => generation,
      "transition" => "preparing",
      "observationSource" => "fixture-preparation"
    }

    assert {:ok, preparation} =
             Fixture.admit(
               "recurse.r5e.io",
               "v1alpha1",
               "LifecycleEvent",
               nil,
               preparing,
               c.operator,
               c.operator_authority
             )

    scope = %{"task" => c.task["eventRef"]}

    badge =
      Fixture.credential(
        "Badge",
        c.operator,
        c.session,
        c.paths,
        c.operator_badge["eventRef"],
        c.operator_authority,
        scope
      )

    delegation =
      Fixture.credential(
        "Endorsement",
        c.operator,
        c.session,
        c.paths,
        c.operator_badge["eventRef"],
        c.operator_authority,
        scope
      )

    authority = [badge["eventRef"], delegation["eventRef"]]

    assert {:ok, span} =
             Fixture.admit(
               "gateway.r5e.io",
               "v1alpha1",
               "AgentSession",
               nil,
               %{},
               c.session,
               authority
             )

    spec =
      Map.merge(c.binding, %{
        "badge" => ref(badge["eventRef"]),
        "delegation" => ref(delegation["eventRef"]),
        "agentSessionAdmission" => ref(span["eventRef"]),
        "agentSession" => ref("gateway.r5e.io/v1alpha1/AgentSession/" <> span["name"])
      })

    if closure do
      closing =
        preparing
        |> Map.put("transition", closure)
        |> Map.put("commandId", "discovery-fixture-closure")
        |> Map.put("priorLifecycle", ref(preparation["eventRef"]))

      assert {:ok, _} =
               Fixture.admit(
                 "recurse.r5e.io",
                 "v1alpha1",
                 "LifecycleEvent",
                 nil,
                 closing,
                 c.operator,
                 c.operator_authority
               )
    end

    assert {:ok, binding} = Fixture.admit_binding(c, spec, authority)
    {:ok, server} = Bandit.start_link(plug: R5e.HTTP.Router, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    try do
      client = KernelClient.new("http://127.0.0.1:#{port}")
      assert {:ok, inventory} = Discovery.read(client, R5e.Origin.current(), "next-boot")
      assert [entry] = inventory.bindings
      assert entry.binding == binding["eventRef"]
      assert entry.preparation == ref(preparation["eventRef"])
      assert entry.badge == badge["eventRef"]
      assert entry.delegation == delegation["eventRef"]
      assert entry.issuer == R5e.Request.key_id(c.operator)

      if closure do
        assert %{binding: binding["eventRef"], reason: :binding_after_closure} in entry.blockers
      else
        assert entry.classification == :old_active
        assert entry.blockers == []
      end

      refute entry.lifecycle_attached
      assert inventory.unattached == [entry]
      refute inventory.complete_boot
    after
      GenServer.stop(server)
    end
  end

  defp ref(value), do: %{"$ref" => value}
end
