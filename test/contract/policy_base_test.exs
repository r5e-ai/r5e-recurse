defmodule R5eRecurse.PolicyBaseTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined,
            [
              R5e.Policy,
              R5e.Policy.Facts,
              R5e.Policy.EvaluationRecord,
              R5e.TestHelpers,
              R5e.Request,
              R5e.CAS,
              R5e.DSSE,
              R5e.ResourceStore,
              R5e.Cedar,
              R5e.Canonical,
              R5e.Log,
              R5e.Vectors,
              R5e.HTTP.Router,
              R5e.Export,
              RecurseVerify
            ]}
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)
  @group "recurse.r5e.io"
  @version "v1alpha1"
  @labels %{
    "custody" => "runtime-held",
    "profile" => "cooperative-local",
    "signerReachability" => "same-user-cooperative-limit"
  }
  @root Path.expand("../..", __DIR__)

  setup do
    setup_fixture()
  end

  def setup_fixture do
    previous =
      Map.new([:data_dir, :policy, :seed_kernel_policy], &{&1, Application.get_env(:r5e, &1)})

    Application.stop(:r5e)
    dir = Path.join(System.tmp_dir!(), "recurse-policy-#{System.unique_integer([:positive])}")
    Application.put_env(:r5e, :data_dir, dir)
    Application.put_env(:r5e, :policy, R5e.Policy.KernelCedar)
    Application.put_env(:r5e, :seed_kernel_policy, true)
    {:ok, _} = Application.ensure_all_started(:r5e)

    on_exit(fn ->
      Application.delete_env(:r5e, :before_record)
      Application.stop(:r5e)
      Enum.each(previous, fn {k, v} -> Application.put_env(:r5e, k, v) end)
      {:ok, _} = Application.ensure_all_started(:r5e)
      File.rm_rf!(dir)
    end)

    {:ok, fixture()}
  end

  test "real signed admission evaluates the admitted policy and retains upstream proof", ctx do
    assert {:ok, receipt} = admit_binding(ctx)
    assert receipt["policy"]["bundleRef"] == R5eRecurse.Policy.bundle_ref()
    assert receipt["policy"]["decision"] == "allow"
    assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    assert {:ok, evaluation} = R5e.Policy.EvaluationRecord.fetch(receipt["policy"]["evaluation"])
    assert evaluation["decision"] == "allow"
    assert receipt["policy"]["generations"][ctx.session_ref] == ctx.span["seq"]
    assert receipt["policy"]["generations"][R5eRecurse.Policy.bundle_ref()] == ctx.bundle["seq"]
    verify_export()
  end

  test "missing and wrong labels, empty authority, mismatched key, and omitted credentials refuse",
       ctx do
    for field <- Map.keys(@labels) do
      assert {:denied, _} = admit_binding(ctx, Map.delete(ctx.binding, field))
      assert {:denied, _} = admit_binding(ctx, Map.put(ctx.binding, field, "untrue"))
    end

    assert {:denied, _} = admit_binding(ctx, ctx.binding, [])

    assert {:denied, mismatch} =
             admit_binding(
               ctx,
               Map.put(ctx.binding, "sessionKey", R5e.Request.key_id(ctx.operator))
             )

    assert mismatch["policy"]["decision"] == "deny"

    for authority <- [[ctx.badge["eventRef"]], [ctx.delegation["eventRef"]]] do
      assert {:denied, refused} = admit_binding(ctx, ctx.binding, authority)
      assert refused["policy"]["decision"] == "deny"
    end

    for field <- ["provider", "model"] do
      assert {:denied, _} = admit_binding(ctx, Map.delete(ctx.binding, field))
    end
  end

  test "a different span actor or Badge subject cannot establish the session identity", ctx do
    {:ok, other_span} =
      admit(
        "gateway.r5e.io",
        "v1alpha1",
        "AgentSession",
        nil,
        %{},
        ctx.operator,
        ctx.operator_authority
      )

    spec =
      ctx.binding
      |> Map.put(
        "agentSession",
        ref("gateway.r5e.io/v1alpha1/AgentSession/" <> other_span["name"])
      )
      |> Map.put("agentSessionAdmission", ref(other_span["eventRef"]))

    assert {:denied, receipt} = admit_binding(ctx, spec)
    assert receipt["policy"]["decision"] == "deny"

    assert {:denied, _} =
             admit_binding(
               ctx,
               Map.put(ctx.binding, "badge", ref(ctx.operator_badge["eventRef"]))
             )
  end

  test "active bundle without the adapter fails the boot gate", _ctx do
    assert :ok = R5eRecurse.Policy.Boot.check!()
    Application.put_env(:r5e, :policy, Recurse.Fold.Policy.Cedar)

    assert_raise RuntimeError, ~r/active managed PolicyBundle requires/, fn ->
      R5eRecurse.Policy.Boot.check!()
    end
  end

  test "policy management excludes itself and can replace a denying bundle", ctx do
    bad = Map.put(ctx.bundle_spec, "governs", ["recurse.r5e.io/v1alpha1/PolicyBundle"])

    assert {:denied, _} =
             admit(
               @group,
               @version,
               "PolicyBundle",
               "active",
               bad,
               ctx.operator,
               ctx.operator_authority
             )

    deny_source = object("forbid(principal, action, resource);", "text/plain")
    denying = Map.put(ctx.bundle_spec, "sourceRef", ref(deny_source))

    assert {:ok, _} =
             admit(
               @group,
               @version,
               "PolicyBundle",
               "active",
               denying,
               ctx.operator,
               ctx.operator_authority
             )

    assert {:denied, _} = admit_binding(ctx)

    assert {:ok, receipt} =
             admit(
               @group,
               @version,
               "PolicyBundle",
               "active",
               ctx.bundle_spec,
               ctx.operator,
               ctx.operator_authority
             )

    assert receipt["policy"]["reason"] == "policyManagement"
    assert {:ok, _} = admit_binding(ctx)
  end

  test "bundle moves after allow: commit retries and records the new denial", ctx do
    deny_source = object("forbid(principal, action, resource);", "text/plain")

    Application.put_env(:r5e, :before_record, fn request ->
      if request.kind == "SessionBinding" do
        Application.delete_env(:r5e, :before_record)

        {:ok, replacement} =
          admit(
            @group,
            @version,
            "PolicyBundle",
            "active",
            Map.put(ctx.bundle_spec, "sourceRef", ref(deny_source)),
            ctx.operator,
            ctx.operator_authority
          )

        Process.put(:policy_replacement, replacement)
      end
    end)

    assert {:denied, receipt} = admit_binding(ctx)
    assert receipt["policy"]["decision"] == "deny"

    assert receipt["policy"]["generations"][R5eRecurse.Policy.bundle_ref()] ==
             Process.get(:policy_replacement)["seq"]
  end

  test "Node parent cycle is refused by the kernel adapter", ctx do
    first = ctx.node

    parent_spec =
      Map.put(ctx.node_spec, "parent", ref(resource("Node", first))) |> Map.put("id", "child")

    {:ok, second} =
      admit(@group, @version, "Node", nil, parent_spec, ctx.operator, ctx.operator_authority)

    cycle = Map.put(ctx.node_spec, "parent", ref(resource("Node", second)))

    assert {:denied, refused} =
             admit(
               @group,
               @version,
               "Node",
               first["name"],
               cycle,
               ctx.operator,
               ctx.operator_authority
             )

    assert refused["policy"]["decision"] == "deny"
  end

  test "ContextManifest labels are required at the direct kernel HTTP surface", ctx do
    for field <- Map.keys(@labels) do
      assert {:denied, _} =
               admit(
                 @group,
                 @version,
                 "ContextManifest",
                 nil,
                 Map.delete(ctx.context_spec, field),
                 ctx.operator,
                 ctx.operator_authority
               )

      assert {:denied, _} =
               admit(
                 @group,
                 @version,
                 "ContextManifest",
                 nil,
                 Map.put(ctx.context_spec, field, "untrue"),
                 ctx.operator,
                 ctx.operator_authority
               )
    end

    action =
      ctx.binding |> Map.put("actorType", "runtime_action") |> Map.drop(["provider", "model"])

    assert {:ok, _} = admit_binding(ctx, action)
  end

  test "upstream refusal is wrapped and a local permit cannot widen it", ctx do
    {:ok, current, _} = R5e.ResourceStore.get("core.r5e.io", "v1", "PolicyBundle", "active")
    {:ok, original_source} = R5e.CAS.get(current["spec"]["sourceRef"]["$ref"])

    text =
      original_source <>
        "\nforbid(principal, action, resource) when { context.target_kind == \"SessionBinding\" };"

    source = object(text, "text/plain")

    {:ok, _} =
      admit(
        "core.r5e.io",
        "v1",
        "PolicyBundle",
        "active",
        Map.put(current["spec"], "sourceRef", ref(source)),
        :node,
        []
      )

    assert {:denied, receipt} = admit_binding(ctx)
    assert receipt["policy"]["bundleRef"] == R5eRecurse.Policy.bundle_ref()
    assert receipt["policy"]["evaluated"] == false
    assert receipt["policy"]["reason"] == "upstreamRefused"
    assert receipt["policy"]["bundle"] == nil
    assert receipt["policy"]["upstreamPolicy"]["decision"] == "deny"
    assert is_binary(receipt["policy"]["upstreamPolicy"]["evaluation"])
    verify_export()
  end

  test "admitted Cedar source independently denies each managed-profile violation", ctx do
    {:ok, receipt} = admit_binding(ctx)
    {:ok, record} = R5e.Policy.EvaluationRecord.fetch(receipt["policy"]["evaluation"])
    question = record["requestBytes"] |> Base.decode64!() |> Jason.decode!()
    entities = Base.decode64!(record["entitiesBytes"])
    {:ok, source} = R5e.CAS.get(receipt["policy"]["source"])

    for {field, bad} <- [
          {"custody", "other"},
          {"profile", "other"},
          {"signer_reachability", "other"},
          {"authority_present", false},
          {"binding_valid", false},
          {"task_scope_valid", false},
          {"node_acyclic", false},
          {"session_key", "other"},
          {"badge_subject", "other"},
          {"delegation_subject", "other"},
          {"span_actor", "other"}
        ] do
      changed = put_in(question, ["context", field], bad)

      assert {:ok, %{decision: :deny}} =
               R5e.Cedar.evaluate(source, R5e.Canonical.encode(changed), entities)
    end
  end

  test "missing admitted policy source produces an error receipt preserving upstream evidence",
       ctx do
    source = ctx.bundle_spec["sourceRef"]["$ref"]
    path = Path.join(R5e.CAS.root(), R5e.CAS.relative_path(source))
    File.rm!(path)
    assert {:denied, receipt} = admit_binding(ctx)
    assert receipt["policy"]["decision"] == "error"
    assert receipt["policy"]["evaluation"] == nil
    assert receipt["policy"]["upstreamPolicy"]["decision"] == "allow"
    assert receipt["policy"]["derivedObjects"] != []
  end

  test "bootstrap admits the exact policy and authority, then reruns without writes", ctx do
    R5e.Vectors.with_fresh_kernel(fn ->
      driver = bootstrap_driver(ctx.operator)

      opts = [
        policy_dir: Path.join(@root, "priv/policy"),
        definitions: R5eRecurse.Kinds.definitions()
      ]

      assert {:ok, first} = R5eRecurse.Bootstrap.run(driver, opts)
      assert Enum.all?(first, &(&1.status == :admitted))
      count = length(R5e.Log.events())
      assert {:ok, second} = R5eRecurse.Bootstrap.run(driver, opts)
      assert Enum.all?(second, &(&1.status == :existing))
      assert length(R5e.Log.events()) == count
      assert :ok = R5eRecurse.Policy.Boot.check!()
    end)
  end

  defp bootstrap_driver(operator) do
    fn
      :measure_engine, _ ->
        {:ok, R5eRecurse.Policy.EngineBuild.measure()}

      :authority_plan, %{kinds: paths} ->
        spec = %{
          "subject" => R5e.Request.key_id(operator),
          "subjectKey" => %{
            "algorithm" => "ed25519",
            "bytes" => Base.encode64(R5e.Request.public_key(operator))
          },
          "kinds" => paths,
          "mayIssue" => true,
          "notBefore" => "2020-01-01T00:00:00Z",
          "notAfter" => "2035-01-01T00:00:00Z"
        }

        base = %{group: "core.r5e.io", version: "v1", name: nil, spec: spec}

        {:ok,
         %{
           node_endorsement: Map.put(base, :kind, "Endorsement"),
           operator_badge:
             base
             |> Map.put(:kind, "Badge")
             |> Map.put(:spec, Map.put(spec, "subjectKind", "person"))
         }}

      :current_resource, candidate ->
        matches =
          for event <- R5e.Log.events(),
              event["kind"] == "admission.granted",
              {:ok, payload} <- [R5e.Log.payload(event)],
              payload["target"]["group"] == candidate.group,
              payload["target"]["version"] == candidate.version,
              payload["target"]["kind"] == candidate.kind,
              candidate.name == nil or payload["target"]["name"] == candidate.name,
              payload["spec"] == candidate.spec,
              do: %{"spec" => payload["spec"], "eventRef" => "event:" <> event["hash"]}

        case List.last(matches) do
          nil -> :missing
          found -> {:ok, found}
        end

      :get_bytes, %{address: address} ->
        R5e.CAS.get(address)

      :put_bytes, %{candidate: candidate, bytes: bytes, role: :node, authority: []} ->
        case R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), bytes, candidate.spec["mediaType"]) do
          {:ok, receipt, _, _} -> {:ok, receipt}
          other -> other
        end

      :admit, %{candidate: candidate, role: role, authority: authority} ->
        keys =
          cond do
            candidate.kind == "Badge" -> [:node, operator]
            role == :node -> [:node]
            true -> [operator]
          end

        R5e.TestHelpers.admit_request(Map.merge(candidate, %{keys: keys, authority: authority}))
    end
  end

  def fixture do
    kinds =
      Path.wildcard(Path.join(@root, "priv/kinds/*.json"))
      |> Enum.map(&(File.read!(&1) |> Jason.decode!()))

    for kind <- kinds do
      assert {:ok, _} = admit("core.r5e.io", "v1", "KindDefinition", nil, kind, :node, [])
    end

    session_kind = %{
      "group" => "gateway.r5e.io",
      "version" => "v1alpha1",
      "kind" => "AgentSession",
      "substrate" => "resource",
      "naming" => %{"mode" => "server"},
      "schema" => %{"properties" => %{}, "required" => [], "additionalProperties" => false},
      "predicates" => []
    }

    assert {:ok, _} = admit("core.r5e.io", "v1", "KindDefinition", nil, session_kind, :node, [])

    paths =
      Enum.map(kinds, &"#{&1["group"]}/#{&1["version"]}/#{&1["kind"]}") ++
        [
          "gateway.r5e.io/v1alpha1/AgentSession",
          "core.r5e.io/v1/Badge",
          "core.r5e.io/v1/Endorsement",
          "core.r5e.io/v1/CasObject"
        ]

    operator = R5e.TestHelpers.key_for("policy-operator")
    session = R5e.TestHelpers.key_for("policy-session")
    endorsement = credential("Endorsement", :node, operator, paths, nil, [])
    operator_badge = credential("Badge", :node, operator, paths, nil, [])
    operator_authority = [endorsement["eventRef"], operator_badge["eventRef"]]

    source = object(File.read!(Path.join(@root, "priv/policy/base.cedar")), "text/plain")
    measurement = R5eRecurse.Policy.EngineBuild.measure()

    assert object(measurement.bytes, R5eRecurse.Policy.EngineBuild.media_type()) ==
             measurement.address

    Application.put_env(:r5e, :policy, R5eRecurse.Policy)

    bundle_spec = %{
      "engine" => "cedar",
      "sourceRef" => ref(source),
      "governs" =>
        Enum.reject(
          Enum.map(kinds, &"#{@group}/#{@version}/#{&1["kind"]}"),
          &String.ends_with?(&1, "/PolicyBundle")
        )
    }

    assert {:ok, bundle} =
             admit(
               @group,
               @version,
               "PolicyBundle",
               "active",
               bundle_spec,
               operator,
               operator_authority
             )

    text = object("test evidence", "text/plain")

    {:ok, graph} =
      admit(
        @group,
        @version,
        "Graph",
        nil,
        %{"id" => "graph", "class" => "codebase", "objective" => ref(text)},
        operator,
        operator_authority
      )

    node_spec = %{
      "id" => "node",
      "graph" => ref(resource("Graph", graph)),
      "objective" => ref(text),
      "acceptanceCriteria" => ref(text)
    }

    {:ok, node} = admit(@group, @version, "Node", nil, node_spec, operator, operator_authority)

    creation =
      credential(
        "Endorsement",
        operator,
        operator,
        paths,
        operator_badge["eventRef"],
        operator_authority,
        %{"taskId" => "task", "node" => resource("Node", node)}
      )

    task_authority = operator_authority ++ [creation["eventRef"]]

    task_spec = %{
      "id" => "task",
      "node" => ref(resource("Node", node)),
      "delegatedBy" => R5e.Request.key_id(operator),
      "delegationRef" => ref(creation["eventRef"]),
      "step" => "produce"
    }

    {:ok, task} = admit(@group, @version, "Task", nil, task_spec, operator, task_authority)

    badge =
      credential(
        "Badge",
        operator,
        session,
        paths,
        operator_badge["eventRef"],
        operator_authority,
        %{"task" => task["eventRef"]}
      )

    delegation =
      credential(
        "Endorsement",
        operator,
        session,
        paths,
        operator_badge["eventRef"],
        operator_authority,
        %{"task" => task["eventRef"]}
      )

    authority = [badge["eventRef"], delegation["eventRef"]]

    context_spec =
      Map.merge(@labels, %{
        "renderedInput" => ref(text),
        "parts" => [],
        "projectionVersion" => "1",
        "budgets" => %{"inputBytes" => 100},
        "omissions" => [],
        "harnessConfiguration" => [],
        "overrides" => [],
        "exclusions" => []
      })

    {:ok, context} =
      admit(@group, @version, "ContextManifest", nil, context_spec, operator, operator_authority)

    {:ok, span} =
      admit("gateway.r5e.io", "v1alpha1", "AgentSession", nil, %{}, session, authority)

    session_ref = "gateway.r5e.io/v1alpha1/AgentSession/" <> span["name"]

    binding =
      Map.merge(@labels, %{
        "task" => ref(task["eventRef"]),
        "agentSession" => ref(session_ref),
        "agentSessionAdmission" => ref(span["eventRef"]),
        "sessionKey" => R5e.Request.key_id(session),
        "badge" => ref(badge["eventRef"]),
        "delegation" => ref(delegation["eventRef"]),
        "generation" => %{"bootId" => "b", "runId" => "r"},
        "role" => "agent",
        "actorType" => "agent",
        "provider" => "provider",
        "model" => "model",
        "harness" => "harness",
        "harnessVersion" => "1",
        "contextManifest" => ref(context["eventRef"]),
        "workspace" => %{"description" => "test", "digest" => "test"}
      })

    %{
      paths: paths,
      task: task,
      task_spec: task_spec,
      task_authority: task_authority,
      creation: creation,
      operator: operator,
      operator_badge: operator_badge,
      operator_authority: operator_authority,
      session: session,
      badge: badge,
      delegation: delegation,
      authority: authority,
      bundle: bundle,
      bundle_spec: bundle_spec,
      binding: binding,
      span: span,
      session_ref: session_ref,
      node: node,
      node_spec: node_spec,
      context_spec: context_spec
    }
  end

  def credential(kind, issuer, subject, paths, parent, authority, scope \\ nil) do
    spec = %{
      "subject" => R5e.Request.key_id(subject),
      "subjectKey" => %{
        "algorithm" => "ed25519",
        "bytes" => Base.encode64(R5e.Request.public_key(subject))
      },
      "kinds" => paths,
      "mayIssue" => true,
      "notBefore" => "2020-01-01T00:00:00Z",
      "notAfter" => "2035-01-01T00:00:00Z"
    }

    spec = if scope, do: Map.put(spec, "scope", scope), else: spec
    spec = if parent, do: Map.put(spec, "parent", ref(parent)), else: spec
    spec = if kind == "Badge", do: Map.put(spec, "subjectKind", "agent"), else: spec
    keys = if kind == "Badge", do: [issuer, subject], else: [issuer]

    {:ok, receipt} =
      R5e.TestHelpers.admit_request(%{
        keys: keys,
        group: "core.r5e.io",
        version: "v1",
        kind: kind,
        name: nil,
        spec: spec,
        authority: authority
      })

    receipt
  end

  def admit_binding(ctx, spec \\ nil, authority \\ nil),
    do:
      admit(
        @group,
        @version,
        "SessionBinding",
        nil,
        spec || ctx.binding,
        ctx.session,
        authority || ctx.authority
      )

  def admit(g, v, k, n, s, key, authority) do
    signed =
      R5e.TestHelpers.sign_request(%{
        keys: [key],
        group: g,
        version: v,
        kind: k,
        name: n,
        spec: s,
        authority: authority
      })

    body = Jason.encode!(%{"envelope" => signed.envelope, "spec" => s, "name" => n})

    conn =
      Plug.Test.conn(:post, "/apis/#{g}/#{v}/#{k}", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> R5e.HTTP.Router.call(R5e.HTTP.Router.init([]))

    assert conn.status in [201, 403]
    {if(conn.status == 201, do: :ok, else: :denied), Jason.decode!(conn.resp_body)}
  end

  defp verify_export do
    dest =
      Path.join(System.tmp_dir!(), "recurse-policy-export-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, ^dest, export} = R5e.Export.run(dest)
      assert export["missingObjects"] == []
      assert {:ok, report} = RecurseVerify.run(dest, posture: "house")
      assert report.findings == [], Enum.join(report.findings, "\n")
    after
      File.rm_rf!(dest)
    end
  end

  defp object(bytes, media) do
    {:ok, _, address, _} = R5e.TestHelpers.cas_admit(R5e.DSSE.node_key_id(), bytes, media)
    address
  end

  defp ref(value), do: %{"$ref" => value}
  defp resource(kind, receipt), do: "#{@group}/#{@version}/#{kind}/#{receipt["name"]}"
end
