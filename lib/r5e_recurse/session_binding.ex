defmodule R5eRecurse.SessionBinding do
  @moduledoc """
  Admit a session-owned span, then its immutable SessionBinding.

  The trusted driver supplies `submit_once.(operation_id, candidate, signer)` and
  `read.(event_ref)`, returning verified granted canonical records with `spec`,
  `target`, `actor` and exact `signed` envelope fields. Submission must durably journal the exact candidate
  and envelope before sending; the signer callback returns {:ok, envelope} and
  must only be called for a new operation. The driver returns {:ok, receipt, envelope},
  {:denied, receipt, envelope}, or an explicit {:not_submitted, reason}; all other
  failures remain uncertain. Repeated IDs perform lookup only. R5E-216 supplies
  the durable driver. Results retain operation_id for recovery. Canonical target
  fields remain unchanged; the span resource_ref is derived separately.
  No routing is enabled here and neither admission is retried. If the second
  admission fails, the returned partial result retains the admitted span.

  A driver is deployment code, not a client-provided map. Policy enforcement is
  still required on the kernel; preflight checks here are preparation checks.
  """
  alias R5eRecurse.{Authority, SessionKeys}
  alias RecurseVerify.{Canonical, DSSE}

  @span %{
    "group" => "gateway.r5e.io",
    "version" => "v1alpha1",
    "kind" => "AgentSession",
    "name" => nil
  }
  @binding %{
    "group" => "recurse.r5e.io",
    "version" => "v1alpha1",
    "kind" => "SessionBinding",
    "name" => nil
  }
  @roles %{
    "producer" => :producer,
    "reviewer" => :reviewer,
    "delegated_decision" => :delegated_decision,
    "runtime_action" => :runtime_action
  }
  @labels %{
    "custody" => "runtime-held",
    "profile" => "cooperative-local",
    "signerReachability" => "same-user-cooperative-limit"
  }

  def admit(driver, keys, generation, opts) do
    with {:ok, public} <- SessionKeys.public_key(keys, generation),
         {:ok, prepared} <- prepare(driver, public, generation, opts),
         {:ok, span} <- submit(driver, keys, generation, prepared, @span, prepared.span) do
      bind_span(driver, keys, generation, prepared, span)
    end
  rescue
    _ -> {:error, :invalid_session_preparation}
  catch
    _, _ -> {:error, :invalid_session_preparation}
  end

  defp bind_span(driver, keys, generation, prepared, span) do
    spec =
      Map.merge(prepared.binding, %{
        "agentSession" => %{"$ref" => span.resource_ref},
        "agentSessionAdmission" => %{"$ref" => span.event_ref}
      })

    case submit(driver, keys, generation, prepared, @binding, spec) do
      {:ok, binding} -> {:ok, %{span: span, binding: binding}}
      result -> {:incomplete, %{span: span, binding_result: result}}
    end
  rescue
    _ ->
      {:incomplete, %{span: span, binding_result: {:outcome_unknown, %{reason: :binding_failed}}}}
  catch
    _, _ ->
      {:incomplete, %{span: span, binding_result: {:outcome_unknown, %{reason: :binding_failed}}}}
  end

  defp prepare(driver, public, generation, opts) do
    key_id = DSSE.key_id!("ed25519", public)
    refs = [opts.badge, opts.delegation]

    with true <-
           Enum.sort(Map.keys(opts)) == Enum.sort([:origin, :badge, :delegation, :binding, :span]),
         true <- is_map(opts.binding) and is_map(opts.span),
         true <- valid_binding_fields?(opts.binding),
         true <-
           Map.keys(opts.binding) --
             ~w(task role actorType provider model harness harnessVersion contextManifest workspace) ==
             [],
         true <- Map.keys(opts.span) -- ~w(harness purpose startedAt sourceIds) == [],
         {:ok, badge} <- driver.read.(opts.badge),
         {:ok, delegation} <- driver.read.(opts.delegation),
         true <- kind?(badge.target, "core.r5e.io", "v1", "Badge"),
         true <- kind?(delegation.target, "core.r5e.io", "v1", "Endorsement"),
         true <- badge.spec["subject"] == key_id and delegation.spec["subject"] == key_id,
         %{"$ref" => task_ref} <- opts.binding["task"],
         true <-
           Authority.scope_allows?(badge.spec["scope"], %{task_ref: task_ref}) and
             Authority.scope_allows?(delegation.spec["scope"], %{task_ref: task_ref}),
         true <- valid_actor?(opts.binding),
         {:ok, role} <- Map.fetch(@roles, opts.binding["role"]),
         {:ok, kinds} <- Authority.Kinds.for_role(role),
         true <-
           Enum.sort(badge.spec["kinds"]) == kinds and
             Enum.sort(delegation.spec["kinds"]) == kinds,
         true <-
           badge.spec["role"] == opts.binding["role"] and
             delegation.spec["role"] == opts.binding["role"],
         true <- opts.binding["actorType"] == "runtime_action" == (role == :runtime_action),
         {:ok, expires} <- expiry(badge.spec, delegation.spec) do
      binding =
        Map.merge(opts.binding, @labels)
        |> Map.merge(%{
          "sessionKey" => key_id,
          "generation" => generation,
          "badge" => %{"$ref" => opts.badge},
          "delegation" => %{"$ref" => opts.delegation}
        })

      _ = Canonical.encode(binding)
      _ = Canonical.encode(opts.span)

      {:ok,
       %{
         binding: binding,
         span: opts.span,
         public: public,
         actor: key_id,
         authority: refs,
         origin: opts.origin,
         expires: expires
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_session_preparation}
    end
  end

  defp submit(driver, keys, generation, prepared, target, spec) do
    candidate = %{target: target, spec: spec}
    operation = Canonical.hash([prepared.origin, prepared.actor, generation, target])

    signer = fn ->
      request = %{
        "origin" => prepared.origin,
        "actor" => prepared.actor,
        "target" => target,
        "specAddress" => Canonical.hash(spec),
        "derivedFrom" => nil,
        "authority" => prepared.authority,
        "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
        "expires" => prepared.expires
      }

      plan = %{
        candidate:
          Map.new(target, fn {k, v} -> {String.to_existing_atom(k), v} end)
          |> Map.put(:spec, spec),
        authority: prepared.authority
      }

      handle = %{public_key: prepared.public, sign: &SessionKeys.sign(keys, generation, &1)}
      Authority.envelope(plan, request, handle)
    end

    result = submit_confirm(driver, operation, candidate, signer, prepared.actor)

    case result do
      {tag, details} when is_map(details) -> {tag, Map.put(details, :operation_id, operation)}
      {tag, reason} -> {tag, %{reason: reason, operation_id: operation}}
    end
  end

  defp submit_confirm(driver, operation, candidate, signer, actor) do
    case driver.submit_once.(operation, candidate, signer) do
      {:ok, %{"eventRef" => event_ref}, envelope} ->
        confirm(driver, candidate, envelope, actor, event_ref)

      {:denied, %{"recorded" => true, "outcome" => "denied"} = receipt, _} ->
        {:denied, receipt}

      {:not_submitted, reason} ->
        {:error, reason}

      {:outcome_unknown, _} = uncertain ->
        uncertain

      _ ->
        {:outcome_unknown, %{reason: :submission_unconfirmed}}
    end
  rescue
    _ -> {:outcome_unknown, %{reason: :submission_failed}}
  catch
    _, _ -> {:outcome_unknown, %{reason: :submission_failed}}
  end

  defp confirm(driver, candidate, envelope, actor, ref) do
    with {:ok, record} <- driver.read.(ref),
         true <- record.actor == actor and record.spec == candidate.spec,
         true <- Map.drop(record.target, ["name"]) == Map.drop(candidate.target, ["name"]),
         true <- record.signed == envelope,
         true <- Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, ref),
         {:ok, name} <- recorded_name(candidate, record, ref) do
      {:ok,
       record
       |> Map.put(:event_ref, ref)
       |> Map.put(
         :resource_ref,
         if(candidate.target == @span, do: "gateway.r5e.io/v1alpha1/AgentSession/" <> name)
       )}
    else
      _ -> {:outcome_unknown, %{event_ref: ref, reason: :canonical_confirmation_unavailable}}
    end
  rescue
    _ -> {:outcome_unknown, %{event_ref: ref, reason: :canonical_confirmation_unavailable}}
  catch
    _, _ -> {:outcome_unknown, %{event_ref: ref, reason: :canonical_confirmation_unavailable}}
  end

  # Server-created span names derive from the admission event and cannot be
  # embedded in the payload that determines that same event's hash.
  defp recorded_name(%{target: @span}, %{target: target}, ref) do
    if Map.has_key?(target, "name"), do: {:error, :unexpected_name}, else: {:ok, ref}
  end

  defp recorded_name(%{target: @binding, spec: spec}, %{target: %{"name" => name}}, _) do
    if name == Canonical.hash(spec), do: {:ok, name}, else: {:error, :unexpected_name}
  end

  defp recorded_name(_, _, _), do: {:error, :unexpected_name}

  defp valid_binding_fields?(binding) do
    Enum.all?(
      ~w(role actorType harness harnessVersion),
      &(is_binary(binding[&1]) and binding[&1] != "")
    ) and
      Enum.all?(~w(task contextManifest), fn field ->
        case binding[field] do
          %{"$ref" => ref} = value when map_size(value) == 1 and is_binary(ref) ->
            Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, ref)

          _ ->
            false
        end
      end) and
      case binding["workspace"] do
        %{"description" => d, "digest" => h} = value when map_size(value) == 2 ->
          is_binary(d) and is_binary(h)

        _ ->
          false
      end
  end

  defp valid_actor?(%{"actorType" => "agent", "provider" => p, "model" => m})
       when is_binary(p) and byte_size(p) > 0 and is_binary(m) and byte_size(m) > 0, do: true

  defp valid_actor?(%{"actorType" => "runtime_action"}), do: true
  defp valid_actor?(_), do: false

  defp kind?(target, g, v, k),
    do: Map.take(target, ~w(group version kind)) == %{"group" => g, "version" => v, "kind" => k}

  defp expiry(badge, delegation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, b, _} <- DateTime.from_iso8601(badge["notAfter"]),
         {:ok, d, _} <- DateTime.from_iso8601(delegation["notAfter"]),
         {:ok, bf, _} <- DateTime.from_iso8601(badge["notBefore"]),
         {:ok, df, _} <- DateTime.from_iso8601(delegation["notBefore"]),
         true <- DateTime.compare(now, bf) != :lt and DateTime.compare(now, df) != :lt do
      limit = Enum.min_by([b, d, DateTime.add(now, 300, :second)], &DateTime.to_unix/1)

      if DateTime.compare(limit, now) == :gt,
        do: {:ok, DateTime.to_iso8601(limit)},
        else: {:error, :expired_credential}
    else
      _ -> {:error, :invalid_credential_term}
    end
  end
end
