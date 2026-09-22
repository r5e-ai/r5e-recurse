defmodule R5eRecurse.Signer.Request do
  @moduledoc """
  Pure, bounded preparation for the future validating signer. No keys or signing.

  `prepare(wire, context)` accepts exactly the wire keys `kind`, `specBytes` and
  `authority`. Context is trusted runtime state, never copied from wire input:
  role, actor, authority, targets (fully qualified Kind => canonical target),
  span (resource ref), model, upstream_host, call_routing, body (exact binary), session_binding
  and llm_call (event refs), plus managed (the expected ManagedRequest spec).

  `read_record.(ref)` must return `{:ok, %{ref: ref, kind: fq_kind, actor: actor,
  spec: spec}}` for the exact verified admitted record at a complete checkpoint.
  It must verify admission, signature, origin, reference identity and immutable
  resource version; resource projection lookup is insufficient. `read_bytes.(ref)`
  returns `{:ok, bytes}`; this module also checks its digest and exact body bytes.
  These callbacks are trusted integration code, not caller-provided assertions.

  `call_routing` supplies exact presence and values for provider, transport,
  requestPath and apiFormat. An omitted field cannot be added on the wire.
  Managed `firstInput`, routing, semantic headers and operation identity must be
  prepared and checked by the trusted adapter; here their entire spec is bound
  exactly. No live authority, replay, generation or first-input verification is
  claimed. Only Prompt, LlmCall and ManagedRequest are supported. Shape checks
  mirror their closed Kinds; the installed core verifier has no Schema module.
  """
  alias RecurseVerify.Canonical
  alias R5eRecurse.Authority.Kinds
  @prompt "gateway.r5e.io/v1alpha1/Prompt"
  @call "gateway.r5e.io/v1alpha1/LlmCall"
  @managed "recurse.r5e.io/v1alpha1/ManagedRequest"
  @supported [@prompt, @call, @managed]
  @call_routing ~w(provider transport requestPath apiFormat)
  @max_bytes 1_048_576

  def prepare(wire, context) when is_map(wire) and is_map(context) do
    with true <- Enum.sort(Map.keys(wire)) == ~w(authority kind specBytes),
         kind when kind in @supported <- wire["kind"],
         {:ok, allowed} <- Kinds.for_role(context.role),
         true <- kind in allowed,
         true <- exact_authority?(wire["authority"], context.authority),
         bytes when is_binary(bytes) and byte_size(bytes) <= @max_bytes <- wire["specBytes"],
         {:ok, spec} when is_map(spec) <- Canonical.decode_json(bytes),
         true <- shape?(kind, spec),
         {:ok, target} <- Map.fetch(context.targets, kind),
         true <- target?(kind, target),
         :ok <- bound(kind, spec, context) do
      {:ok,
       %{
         target: target,
         spec: spec,
         spec_bytes: bytes,
         canonical_spec_bytes: Canonical.encode(spec),
         spec_address: Canonical.hash(spec),
         authority: context.authority
       }}
    else
      _ -> {:error, :invalid_signer_request}
    end
  rescue
    _ -> {:error, :invalid_signer_request}
  catch
    _, _ -> {:error, :invalid_signer_request}
  end

  def prepare(_, _), do: {:error, :invalid_signer_request}

  defp exact_authority?(given, expected) do
    is_list(given) and is_list(expected) and expected != [] and
      Enum.all?(given, &event_ref?/1) and Enum.all?(expected, &event_ref?/1) and
      length(given) == length(Enum.uniq(given)) and
      length(expected) == length(Enum.uniq(expected)) and
      Enum.sort(given) == Enum.sort(expected)
  end

  defp target?(kind, target) when is_map(target) do
    [group, version, name] = String.split(kind, "/")

    Enum.sort(Map.keys(target)) == ~w(group kind name version) and
      target["group"] == group and target["version"] == version and target["kind"] == name and
      (is_nil(target["name"]) or text?(target["name"]))
  end

  defp target?(_, _), do: false

  defp bound(@prompt, spec, ctx) do
    with true <- spec["session"] == ref(ctx.span),
         true <- spec["contentRef"] == ref(body_ref(ctx.body)),
         {:ok, bytes} <- ctx.read_bytes.(spec["contentRef"]["$ref"]),
         true <- bytes == ctx.body and body_ref(bytes) == spec["contentRef"]["$ref"] do
      :ok
    else
      _ -> :error
    end
  end

  defp bound(@call, spec, ctx) do
    with true <- spec["session"] == ref(ctx.span),
         true <- spec["model"] == ctx.model and spec["upstreamHost"] == ctx.upstream_host,
         true <- closed?(ctx.call_routing, [], @call_routing),
         true <- optional?(ctx.call_routing, ~w(provider requestPath apiFormat), &text?/1),
         true <- optional?(ctx.call_routing, ["transport"], &(&1 in ~w(https https-sse wss))),
         true <- Map.take(spec, @call_routing) == ctx.call_routing,
         true <-
           text?(ctx.model) and ctx.model != "" and text?(ctx.upstream_host) and
             ctx.upstream_host != "",
         {:ok, prompt} <- record(ctx, spec["prompt"]["$ref"], @prompt),
         :ok <- bound(@prompt, prompt, ctx) do
      :ok
    else
      _ -> :error
    end
  end

  defp bound(@managed, spec, ctx) do
    with true <- spec == ctx.managed,
         true <- spec["sessionBinding"] == ref(ctx.session_binding),
         true <- spec["llmCall"] == ref(ctx.llm_call),
         true <- spec["inboundBody"] == ref(body_ref(ctx.body)),
         true <- spec["outboundBody"] == spec["inboundBody"],
         true <- spec["bodyDigest"] == Canonical.hash_bytes(ctx.body),
         {:ok, call} <- record(ctx, ctx.llm_call, @call),
         :ok <- bound(@call, call, ctx) do
      :ok
    else
      _ -> :error
    end
  end

  defp record(ctx, reference, kind) do
    with {:ok, %{ref: ^reference, kind: ^kind, actor: actor, spec: spec}} <-
           ctx.read_record.(reference),
         true <- actor == ctx.actor and shape?(kind, spec) do
      {:ok, spec}
    else
      _ -> :error
    end
  end

  defp shape?(@prompt, spec) do
    closed?(spec, ~w(contentRef), ~w(contentRef mediaType role session observedAt)) and
      bytes_ref?(spec["contentRef"]) and
      optional?(spec, ~w(mediaType observedAt), &text?/1) and
      optional?(spec, ["role"], &(&1 in ~w(user system assistant tool))) and
      optional?(spec, ["session"], &resource_ref?(&1, "AgentSession"))
  end

  defp shape?(@call, spec) do
    closed?(
      spec,
      ~w(model prompt),
      ~w(model prompt provider upstreamHost transport apiFormat requestPath session sourceIds startedAt tools parameters)
    ) and
      text?(spec["model"]) and spec["model"] != "" and resource_ref?(spec["prompt"], "Prompt") and
      optional?(spec, ~w(provider upstreamHost apiFormat requestPath startedAt), &text?/1) and
      optional?(spec, ["transport"], &(&1 in ~w(https https-sse wss))) and
      optional?(spec, ["session"], &resource_ref?(&1, "AgentSession")) and
      optional?(
        spec,
        ["sourceIds"],
        &(closed?(&1, [], ~w(session run turn step)) and
            Enum.all?(Map.values(&1), fn v -> text?(v) end))
      ) and
      optional?(spec, ["tools"], &(is_list(&1) and Enum.all?(&1, fn v -> text?(v) end))) and
      optional?(
        spec,
        ["parameters"],
        &(is_map(&1) and
            Enum.all?(&1, fn {k, v} ->
              text?(k) and (text?(v) or is_integer(v) or is_boolean(v))
            end))
      )
  end

  defp shape?(@managed, spec) do
    fields =
      ~w(sessionBinding llmCall inboundBody outboundBody bodyDigest firstInput method path upstream transport semanticHeaders operationId)

    closed?(spec, fields, fields) and
      Enum.all?(~w(sessionBinding llmCall), &ref_value?(spec[&1], fn r -> event_ref?(r) end)) and
      Enum.all?(~w(inboundBody outboundBody), &bytes_ref?(spec[&1])) and
      Enum.all?(~w(bodyDigest method path upstream transport operationId), &text?(spec[&1])) and
      closed?(spec["firstInput"], ~w(fieldPath digest), ~w(fieldPath digest)) and
      Enum.all?(Map.values(spec["firstInput"]), &text?/1) and
      is_list(spec["semanticHeaders"]) and
      Enum.all?(
        spec["semanticHeaders"],
        &(closed?(&1, ~w(name value), ~w(name value)) and
            Enum.all?(Map.values(&1), fn v -> text?(v) end))
      )
  end

  defp closed?(map, required, allowed) when is_map(map),
    do: Enum.all?(required, &Map.has_key?(map, &1)) and Map.keys(map) -- allowed == []

  defp closed?(_, _, _), do: false

  defp optional?(map, keys, predicate),
    do: Enum.all?(keys, &(not Map.has_key?(map, &1) or predicate.(map[&1])))

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp event_ref?(value),
    do: text?(value) and Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, value)

  defp bytes_ref?(value),
    do: ref_value?(value, &(text?(&1) and Regex.match?(~r/\Abytes:sha256:[0-9a-f]{64}\z/, &1)))

  defp resource_ref?(value, kind),
    do:
      ref_value?(
        value,
        &(text?(&1) and String.starts_with?(&1, "gateway.r5e.io/v1alpha1/" <> kind <> "/") and
            byte_size(&1) > byte_size("gateway.r5e.io/v1alpha1/" <> kind <> "/"))
      )

  defp ref_value?(%{"$ref" => value} = map, predicate),
    do: map_size(map) == 1 and predicate.(value)

  defp ref_value?(_, _), do: false
  defp ref(value), do: %{"$ref" => value}
  defp body_ref(bytes), do: "bytes:" <> Canonical.hash_bytes(bytes)
end
