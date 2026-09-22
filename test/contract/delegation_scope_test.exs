defmodule R5eRecurse.DelegationScopeTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.PolicyBaseTest, as: Fixture
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)

  setup do
    Fixture.setup_fixture()
  end

  test "direct signed Task admission enforces reservation, Node, issuer and cited authority",
       ctx do
    {:ok, other_node} =
      Fixture.admit(
        "recurse.r5e.io",
        "v1alpha1",
        "Node",
        nil,
        Map.put(ctx.node_spec, "id", "other"),
        ctx.operator,
        ctx.operator_authority
      )

    for spec <- [
          Map.put(ctx.task_spec, "id", "unreserved"),
          Map.put(ctx.task_spec, "node", %{
            "$ref" => "recurse.r5e.io/v1alpha1/Node/" <> other_node["name"]
          }),
          Map.put(ctx.task_spec, "delegatedBy", R5e.Request.key_id(ctx.session)),
          Map.put(ctx.task_spec, "delegationRef", %{"$ref" => ctx.delegation["eventRef"]})
        ] do
      assert {:denied, receipt} = task(ctx, spec, ctx.task_authority)
      assert receipt["policy"]["decision"] == "deny"
      assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    end

    assert {:denied, _} = task(ctx, ctx.task_spec, ctx.operator_authority)

    for scope <- [nil, %{"task" => ctx.task["eventRef"]}] do
      grant =
        Fixture.credential(
          "Endorsement",
          ctx.operator,
          ctx.operator,
          ctx.paths,
          ctx.operator_badge["eventRef"],
          ctx.operator_authority,
          scope
        )

      spec = Map.put(ctx.task_spec, "delegationRef", %{"$ref" => grant["eventRef"]})
      assert {:denied, receipt} = task(ctx, spec, ctx.operator_authority ++ [grant["eventRef"]])
      assert receipt["policy"]["decision"] == "deny"
      assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    end

    assert {:ok, _} = task(ctx, ctx.task_spec, ctx.task_authority)
  end

  test "session scope must name the exact admitted Task and its delegating issuer", ctx do
    {:ok, another_task} = task(ctx, ctx.task_spec, ctx.task_authority)

    for scope <- [
          nil,
          %{"task" => another_task["eventRef"]},
          %{"task" => "recurse.r5e.io/v1alpha1/Task/" <> ctx.task["name"]},
          %{"task" => "event:" <> String.duplicate("0", 64)},
          %{"taskId" => "task", "node" => ctx.task_spec["node"]["$ref"]}
        ] do
      delegation =
        Fixture.credential(
          "Endorsement",
          ctx.operator,
          ctx.session,
          ctx.paths,
          ctx.operator_badge["eventRef"],
          ctx.operator_authority,
          scope
        )

      binding = Map.put(ctx.binding, "delegation", %{"$ref" => delegation["eventRef"]})

      assert {:denied, receipt} =
               Fixture.admit_binding(ctx, binding, [ctx.badge["eventRef"], delegation["eventRef"]])

      assert receipt["policy"]["decision"] == "deny"
      assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    end

    delegation =
      Fixture.credential("Endorsement", :node, ctx.session, ctx.paths, nil, [], %{
        "task" => ctx.task["eventRef"]
      })

    binding = Map.put(ctx.binding, "delegation", %{"$ref" => delegation["eventRef"]})

    assert {:denied, _} =
             Fixture.admit_binding(ctx, binding, [ctx.badge["eventRef"], delegation["eventRef"]])

    assert {:ok, _} = Fixture.admit_binding(ctx)
  end

  test "deployment Badge must carry the same exact Task scope", ctx do
    for scope <- [nil, %{"task" => "event:sha256:" <> String.duplicate("0", 64)}] do
      badge =
        Fixture.credential(
          "Badge",
          ctx.operator,
          ctx.session,
          ctx.paths,
          ctx.operator_badge["eventRef"],
          ctx.operator_authority,
          scope
        )

      binding = Map.put(ctx.binding, "badge", %{"$ref" => badge["eventRef"]})

      assert {:denied, receipt} =
               Fixture.admit_binding(ctx, binding, [badge["eventRef"], ctx.delegation["eventRef"]])

      assert receipt["policy"]["decision"] == "deny"
      assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    end

    assert {:ok, _} = Fixture.admit_binding(ctx)
  end

  defp task(ctx, spec, authority),
    do: Fixture.admit("recurse.r5e.io", "v1alpha1", "Task", nil, spec, ctx.operator, authority)
end
