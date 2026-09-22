defmodule R5eRecurse.Policy do
  @moduledoc "Admission-time narrowing policy with the fold fixed as its upstream."
  @compile {:no_warn_undefined,
            [
              R5e.Policy.Facts,
              R5e.Cedar,
              R5e.CAS,
              R5e.Canonical,
              R5e.RefIndex,
              R5e.KindRegistry,
              R5e.Policy.EvaluationRecord,
              Recurse.Fold.Policy.Cedar
            ]}
  alias R5eRecurse.Policy.{EngineBuild, Presentation}
  alias R5e.Policy.Facts
  @group "recurse.r5e.io"
  @version "v1alpha1"
  @bundle_ref "#{@group}/#{@version}/PolicyBundle/active"

  def upstream, do: Recurse.Fold.Policy.Cedar
  def bundle_ref, do: @bundle_ref

  def authorize(%{group: @group} = request) do
    case upstream_answer(request) do
      {:ok, upstream} ->
        compose(safely(fn -> local(request) end), upstream)

      {:deny, reason, upstream} ->
        compose(
          {:deny, reason,
           skipped(
             upstream["decision"],
             "upstreamRefused",
             "upstream refused; not evaluated here"
           )},
          upstream
        )
    end
  end

  def authorize(request), do: upstream_answer(request)

  defp upstream_answer(request) do
    case Recurse.Fold.Policy.Cedar.authorize(request) do
      {:ok, meta} when is_map(meta) -> {:ok, meta}
      {:deny, reason, meta} when is_map(meta) -> {:deny, reason, meta}
      _ -> error("malformed upstream policy answer", "upstreamInvalid")
    end
  rescue
    exception ->
      error("upstream policy raised: " <> Exception.message(exception), "upstreamError")
  end

  defp safely(fun) do
    fun.()
  rescue
    exception ->
      error("policy presentation failed: " <> Exception.message(exception), "presentationError")
  end

  defp local(%{version: @version, kind: "PolicyBundle"} = request) do
    # A bundle cannot decide its own replacement. The upstream governs this
    # management act; this layer checks only syntax and claimed jurisdiction.
    with :ok <- management(request) do
      {:ok,
       skipped(
         "allow",
         "policyManagement",
         "policy-management admission validated; upstream decides"
       )
       |> Map.put("engine", "recurse-management")}
    else
      {:error, reason} -> error(reason, "policyManagement")
    end
  end

  defp local(request) do
    with {:ok, bundle} <- Facts.fetch(@bundle_ref),
         :ok <- jurisdiction(bundle, request),
         {:ok, source, source_ref} <- source(bundle["spec"]),
         {:ok, engine_build} <- EngineBuild.admitted(),
         {:ok, question, entities} <- Presentation.present(request),
         {:ok, result} <- R5e.Cedar.evaluate(source, question, entities) do
      decision = Atom.to_string(result.decision)

      evaluation =
        R5e.Policy.EvaluationRecord.write(%{
          engine: "cedar",
          engine_build: engine_build,
          kind_definition: kind_definition(request),
          bundle: bundle["specAddress"],
          source: source_ref,
          request_bytes: question,
          entities_bytes: entities,
          resolution: request.resolved,
          decision: decision,
          matched: result.matched_policies,
          resolved_authority: request.resolved_authority
        })

      meta = %{
        "engine" => "cedar",
        "decision" => decision,
        "bundle" => bundle["specAddress"],
        "bundleRef" => @bundle_ref,
        "source" => source_ref,
        "shape" => nil,
        "evaluation" => evaluation,
        "engineBuild" => engine_build,
        "matched" => result.matched_policies,
        "generations" => %{@bundle_ref => bundle["admissionSeq"]},
        "derivedObjects" => [evaluation]
      }

      if result.decision == :allow,
        do: {:ok, meta},
        else: {:deny, "managed policy denied admission", meta}
    else
      {:error, reason} -> error("managed policy error: #{inspect(reason)}", "presentationError")
    end
  end

  defp management(request) do
    with {:ok, _facts} <- Facts.resolve(request),
         scope when is_list(scope) and scope != [] <- request.spec["governs"],
         true <- Enum.all?(scope, &governed_path?/1),
         granted <- authority_kinds(request.resolved_authority),
         true <- "*" in granted or Enum.all?(scope, &(&1 in granted)),
         {:ok, bytes, _} <- source(request.spec),
         :ok <- R5e.Cedar.validate_policy_syntax(bytes) do
      :ok
    else
      {:error, reason} ->
        {:error, "policy management refused: #{inspect(reason)}"}

      _ ->
        {:error,
         "governs must list application Kind paths within the cited authority, excluding PolicyBundle"}
    end
  end

  defp authority_kinds(resolved) do
    Enum.flat_map(resolved, fn entry ->
      case entry["chain"] do
        [%{"kinds" => kinds} | _] when is_list(kinds) -> kinds
        _ -> []
      end
    end)
  end

  defp governed_path?(path) when is_binary(path) do
    case String.split(path, "/") do
      [@group, @version, kind] when kind != "PolicyBundle" and kind != "" ->
        match?({:ok, _}, Facts.fetch("core.r5e.io/v1/KindDefinition/#{path}"))

      _ ->
        false
    end
  end

  defp governed_path?(_), do: false

  defp jurisdiction(bundle, request) do
    scope = get_in(bundle, ["spec", "governs"])
    path = "#{request.group}/#{request.version}/#{request.kind}"

    if is_list(scope) and path in scope and Enum.all?(scope, &governed_path?/1),
      do: :ok,
      else: {:error, "active bundle has no valid jurisdiction for #{path}"}
  end

  defp source(%{"engine" => "cedar", "sourceRef" => %{"$ref" => address}})
       when is_binary(address) do
    with true <- String.starts_with?(address, "bytes:sha256:"),
         {:ok, _} <- R5e.RefIndex.cas_object(address),
         {:ok, bytes} <- R5e.CAS.get(address),
         true <- address == "bytes:" <> R5e.Canonical.hash_bytes(bytes) do
      {:ok, bytes, address}
    else
      _ -> {:error, "policy source is not an available admitted CasObject"}
    end
  end

  defp source(_), do: {:error, "malformed Cedar bundle source"}

  defp kind_definition(request) do
    case Facts.fetch(
           "core.r5e.io/v1/KindDefinition/#{request.group}/#{request.version}/#{request.kind}"
         ) do
      {:ok, entry} -> entry["specAddress"]
      _ -> raise "target Kind definition is unavailable"
    end
  end

  defp error(reason, cause), do: {:deny, reason, skipped("error", cause, reason)}

  defp skipped(decision, reason, note) do
    %{
      "engine" => "cedar",
      "decision" => decision,
      "bundleRef" => @bundle_ref,
      "bundle" => nil,
      "source" => nil,
      "shape" => nil,
      "evaluation" => nil,
      "engineBuild" => nil,
      "matched" => [],
      "generations" => %{},
      "derivedObjects" => [],
      "evaluated" => false,
      "reason" => reason,
      "note" => note
    }
  end

  @doc false
  def compose(result, upstream) do
    meta = elem(result, tuple_size(result) - 1)
    left = upstream["generations"] || %{}
    right = meta["generations"] || %{}

    if is_map(left) and is_map(right) do
      conflicts = for {ref, seq} <- left, Map.has_key?(right, ref) and right[ref] != seq, do: ref
      derived = Enum.uniq((upstream["derivedObjects"] || []) ++ (meta["derivedObjects"] || []))
      nested = Map.put(meta, "upstreamPolicy", upstream)

      if conflicts == [] do
        put_elem(
          result,
          tuple_size(result) - 1,
          nested
          |> Map.put("generations", Map.merge(left, right))
          |> Map.put("derivedObjects", derived)
        )
      else
        wrapper =
          skipped("error", "conflictingGenerations", "policy layers read conflicting generations")
          |> Map.put("upstreamPolicy", nested)
          |> Map.put("derivedObjects", derived)
          |> Map.put(
            "generations",
            Map.merge(Map.drop(left, conflicts), Map.drop(right, conflicts))
          )

        {:deny, "policy generation conflict", wrapper}
      end
    else
      {:deny, "malformed generation report",
       skipped("error", "generationsInvalid", "malformed generation report")
       |> Map.put("upstreamPolicy", upstream)}
    end
  end
end
