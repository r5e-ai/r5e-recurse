defmodule R5eRecurse.SessionBindingTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{SessionBinding, SessionKeys, Authority}
  alias R5eRecurse.PolicyBaseTest, as: Fixture
  @moduletag :deployment
  @moduletag skip: not Code.ensure_loaded?(R5e.Policy.Facts)

  setup do
    kind = File.read!("test/fixtures/gateway/agent-session.json") |> Jason.decode!()
    Fixture.setup_fixture(kind)
  end

  test "two ephemeral keys admit distinct spans and bindings under their own credentials", ctx do
    keys = start_supervised!(SessionKeys)

    results =
      for id <- ["one", "two"] do
        {:ok, key} = SessionKeys.create(keys, id, self())
        opts = options(ctx, keys, key)

        assert {:ok, %{span: span, binding: binding}} =
                 SessionBinding.admit(driver(), keys, key.generation, opts)

        assert binding.actor == RecurseVerify.DSSE.key_id!("ed25519", key.public_key)
        assert span.actor == binding.actor
        assert binding.spec["agentSessionAdmission"]["$ref"] == span.event_ref
        assert binding.spec["generation"] == key.generation
        assert binding.spec["custody"] == "runtime-held"
        assert binding.spec["badge"]["$ref"] == opts.badge
        {key, opts, binding}
      end

    [{first, first_opts, b1}, {second, _, b2}] = results
    refute b1.actor == b2.actor
    refute b1.event_ref == b2.event_ref

    assert {:error, :invalid_session_preparation} =
             SessionBinding.admit(driver(), keys, second.generation, first_opts)

    SessionKeys.destroy(keys, first.generation)

    assert {:error, :stale_generation} =
             SessionBinding.admit(driver(), keys, first.generation, first_opts)
  end

  test "agent requires provider; runtime action can bind without model provider", ctx do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "agent", self())
    opts = options(ctx, keys, key)
    broken = update_in(opts.binding, &Map.delete(&1, "provider"))

    assert {:error, :invalid_session_preparation} =
             SessionBinding.admit(driver(), keys, key.generation, broken)

    {:ok, action_key} = SessionKeys.create(keys, "action", self())

    action =
      options(ctx, keys, action_key, :runtime_action)
      |> update_in(
        [:binding],
        &(&1 |> Map.put("actorType", "runtime_action") |> Map.drop(["provider", "model"]))
      )

    assert {:ok, _} = SessionBinding.admit(driver(), keys, action_key.generation, action)
    # These are direct admissions: missing required fields/labels fail at the kernel.
    for field <- ["agentSessionAdmission", "custody", "profile", "signerReachability"] do
      assert {:denied, _} = Fixture.admit_binding(ctx, Map.delete(ctx.binding, field))
    end
  end

  test "uncertain binding preserves admitted span and never dispatches a third write", ctx do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "uncertain", self())
    opts = options(ctx, keys, key)
    base = driver()
    counter = start_supervised!({Agent, fn -> 0 end})

    submit = fn operation, candidate, signer ->
      Agent.update(counter, &(&1 + 1))

      case candidate.target["kind"] do
        "AgentSession" ->
          base.submit_once.(operation, candidate, signer)

        "SessionBinding" ->
          assert {:ok, _, _} = base.submit_once.(operation, candidate, signer)
          {:outcome_unknown, :lost_ack}
      end
    end

    assert {:incomplete,
            %{span: %{event_ref: ref}, binding_result: {:outcome_unknown, %{reason: :lost_ack}}}} =
             SessionBinding.admit(%{base | submit_once: submit}, keys, key.generation, opts)

    assert is_binary(ref)
    assert Agent.get(counter, & &1) == 2
  end

  test "key process death after span confirmation preserves evidence and recovery handle", ctx do
    {:ok, keys} = SessionKeys.start_link()
    {:ok, key} = SessionKeys.create(keys, "dies", self())
    opts = options(ctx, keys, key)
    base = driver()

    read = fn ref ->
      result = base.read.(ref)
      if match?({:ok, %{target: %{"kind" => "AgentSession"}}}, result), do: GenServer.stop(keys)
      result
    end

    assert {:incomplete,
            %{span: %{event_ref: ref}, binding_result: {:outcome_unknown, %{operation_id: op}}}} =
             SessionBinding.admit(%{base | read: read}, keys, key.generation, opts)

    assert is_binary(ref) and is_binary(op)
  end

  test "missing required input fails before any span submission", ctx do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "invalid", self())
    opts = options(ctx, keys, key)
    base = %{driver() | submit_once: fn _, _, _ -> flunk("invalid preparation submitted") end}

    for field <- ~w(harnessVersion contextManifest workspace) do
      assert {:error, :invalid_session_preparation} =
               SessionBinding.admit(
                 base,
                 keys,
                 key.generation,
                 update_in(opts.binding, &Map.delete(&1, field))
               )
    end
  end

  test "ambiguous first write and failed confirmation retain an operation handle", ctx do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "first-unknown", self())
    opts = options(ctx, keys, key)
    base = driver()

    for result <- [{:error, :timeout}, {:transport_failure, :connection_lost}] do
      assert {:outcome_unknown, %{operation_id: id}} =
               SessionBinding.admit(
                 %{base | submit_once: fn _, _, _ -> result end},
                 keys,
                 key.generation,
                 opts
               )

      assert is_binary(id)
    end

    read = fn ref ->
      case base.read.(ref) do
        {:ok, %{target: %{"kind" => "AgentSession"}}} -> {:error, :unavailable}
        other -> other
      end
    end

    assert {:outcome_unknown, %{operation_id: id, event_ref: ref}} =
             SessionBinding.admit(%{base | read: read}, keys, key.generation, opts)

    assert is_binary(id) and is_binary(ref)
  end

  defp options(ctx, keys, key, role \\ :producer) do
    {:ok, role_kinds} = Authority.Kinds.for_role(role)

    parent =
      Fixture.credential(
        "Badge",
        :node,
        ctx.operator,
        Enum.uniq(ctx.paths ++ role_kinds),
        nil,
        []
      )

    common = [
      subject_public_key: key.public_key,
      role: role,
      task_ref: ctx.task["eventRef"],
      not_before: "2020-01-01T00:00:00Z",
      not_after: "2030-01-01T00:00:00Z",
      operator_badge: parent["eventRef"]
    ]

    {:ok, bp} = Authority.deployment_badge(common)
    {:ok, dp} = Authority.session_endorsement(common)
    badge = issue(ctx.operator, bp, keys, key)
    delegation = issue(ctx.operator, dp, keys, key)

    %{
      origin: R5e.Origin.current(),
      badge: badge["eventRef"],
      delegation: delegation["eventRef"],
      span: %{"harness" => "test"},
      binding:
        Map.take(
          ctx.binding,
          ~w(task role actorType provider model harness harnessVersion contextManifest workspace)
        )
        |> Map.put("role", to_string(role))
    }
  end

  defp issue(operator, plan, keys, key) do
    target =
      Map.take(plan.candidate, [:group, :version, :kind, :name])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    request =
      R5e.Request.build(%{target: target, spec: plan.candidate.spec, authority: plan.authority},
        actor: R5e.Request.key_id(operator)
      )

    issuer = %{
      public_key: operator.public,
      sign: fn pae -> {:ok, :crypto.sign(:eddsa, :none, pae, [operator.private, :ed25519])} end
    }

    subject = %{public_key: key.public_key, sign: &SessionKeys.sign(keys, key.generation, &1)}
    assert {:ok, envelope} = Authority.envelope(plan, request, issuer, subject)
    assert {:ok, receipt} = R5e.Admission.admit(Map.put(plan.candidate, :envelope, envelope))
    receipt
  end

  defp driver do
    %{
      # Synchronous fixture driver: production must use the durable nonce journal.
      submit_once: fn _operation, %{target: target, spec: spec}, signer ->
        {:ok, envelope} = signer.()
        body = Jason.encode!(%{"envelope" => envelope, "spec" => spec, "name" => nil})

        conn =
          Plug.Test.conn(
            :post,
            "/apis/#{target["group"]}/#{target["version"]}/#{target["kind"]}",
            body
          )
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> R5e.HTTP.Router.call(R5e.HTTP.Router.init([]))

        case conn.status do
          201 -> {:ok, Jason.decode!(conn.resp_body), envelope}
          403 -> {:denied, Jason.decode!(conn.resp_body), envelope}
          _ -> {:outcome_unknown, :http_error}
        end
      end,
      read: fn ref ->
        with event when not is_nil(event) <-
               Enum.find(R5e.Log.events(), &("event:" <> &1["hash"] == ref)),
             "admission.granted" <- event["kind"],
             {:ok, bytes} <- R5e.CAS.get(event["payload"]),
             payload <- Jason.decode!(bytes) do
          {:ok,
           %{
             spec: payload["spec"],
             target: payload["target"],
             actor: payload["actor"]["id"],
             signed: payload["signed"]
           }}
        else
          _ -> {:error, :unconfirmed}
        end
      end
    }
  end
end
