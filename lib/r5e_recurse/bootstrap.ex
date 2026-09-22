defmodule R5eRecurse.Bootstrap do
  @moduledoc """
  Ordered, non-replacing bootstrap using a deployment-supplied two-argument driver.

  The driver handles `:authority_plan`, `:measure_engine`, `:current_resource`,
  `:admit`, `:put_bytes`, and `:get_bytes`. Candidates contain atom keys `group`, `version`,
  `kind`, `name`, and `spec`. Reads return `:missing` or
  `{:ok, %{"spec" => spec, "eventRef" => admission_ref}}` for a granted admission.
  Content-named candidates have nil names; the driver resolves their canonical
  content name. Raw CAS presence is never evidence of admission.

  The authority plan returns `node_endorsement` and `operator_badge` candidates
  with stable terms and the same operator subject, scoped to the supplied Kinds.
  Both are issued by `:node`; the Badge requires the operator countersignature.
  The driver must obtain operator signatures from an external configured signer,
  never substitute the node or runtime key. Engine measurement returns the exact
  deployment's `%{bytes: bytes, address: address, spec: spec}`.

  Writes receive `%{candidate: candidate, role: :node | :operator, authority: refs}`.
  `:put_bytes` additionally receives `bytes` and MUST perform signed CasObject
  admission and byte storage, returning `{:ok, receipt}` only after both succeed.
  `:get_bytes` receives `%{address: address}` and returns `{:ok, bytes}` or
  an error. Every CasObject, including existing admissions, is read back and
  checked against the exact expected bytes and digest. Missing or corrupt bytes
  stop bootstrap; the driver/operator must repair storage separately without
  re-admitting the object. Admission metadata alone never completes bootstrap.
  `:admit` returns the same receipt shape. Failures (including uncertain outcomes)
  stop immediately without retry. No default transport or signer is installed.
  """
  alias R5eRecurse.Kinds

  def run(driver, opts \\ []) when is_function(driver, 2) do
    dir =
      Keyword.get(opts, :policy_dir, Path.join(to_string(:code.priv_dir(:r5e_recurse)), "policy"))

    definitions = Keyword.get(opts, :definitions, Kinds.definitions())
    paths = Enum.map(definitions, &path/1) |> Enum.sort()

    with {:ok, source} <- source(dir),
         {:ok, measurement} <- driver.(:measure_engine, %{}),
         :ok <- measurement_valid(measurement),
         {:ok, plan} <- driver.(:authority_plan, %{kinds: paths}),
         :ok <- plan_valid(plan, paths) do
      execute(driver, definitions, source, measurement, plan)
    end
  end

  defp execute(driver, definitions, source, measurement, plan) do
    # Definitions only refer to already-built-in schema primitives; their instance
    # references do not require admitting instances of the target Kind first.
    declarations = Enum.sort_by(definitions, &path/1)

    result =
      Enum.reduce_while(declarations, {:ok, []}, fn spec, {:ok, rows} ->
        candidate = candidate("KindDefinition", path(spec), spec)

        case ensure(driver, candidate, :node, []) do
          {:ok, row} -> {:cont, {:ok, rows ++ [row]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, rows} <- result,
         {:ok, endorsement} <- ensure(driver, plan.node_endorsement, :node, []),
         {:ok, badge} <- ensure(driver, plan.operator_badge, :node, []),
         {:ok, source_row} <- ensure_object(driver, source, "text/plain"),
         {:ok, engine_row} <-
           ensure_object(driver, measurement.bytes, measurement.spec["mediaType"]),
         authority = [endorsement.receipt["eventRef"], badge.receipt["eventRef"]],
         true <- Enum.all?(authority, &is_binary/1),
         spec = %{
           "engine" => "cedar",
           "sourceRef" => %{"$ref" => address(source)},
           "governs" =>
             definitions
             |> Enum.reject(&(&1["kind"] == "PolicyBundle"))
             |> Enum.map(&path/1)
             |> Enum.sort()
         },
         bundle = %{
           group: Kinds.group(),
           version: Kinds.version(),
           kind: "PolicyBundle",
           name: "active",
           spec: spec
         },
         {:ok, bundle_row} <- ensure(driver, bundle, :operator, authority) do
      {:ok, rows ++ [endorsement, badge, source_row, engine_row, bundle_row]}
    else
      false -> {:error, :missing_authority_admission_ref}
      error -> error
    end
  end

  defp ensure_object(driver, bytes, media) do
    with {:ok, row} <-
           ensure(
             driver,
             candidate("CasObject", nil, object_spec(bytes, media)),
             :node,
             [],
             bytes
           ) do
      case driver.(:get_bytes, %{address: address(bytes)}) do
        {:ok, stored} when is_binary(stored) ->
          if stored == bytes and address(stored) == row.candidate.spec["address"],
            do: {:ok, row},
            else: {:error, :cas_bytes_mismatch}

        _ ->
          {:error, :cas_bytes_unavailable}
      end
    end
  end

  defp ensure(driver, candidate, role, authority, bytes \\ nil) do
    case driver.(:current_resource, candidate) do
      {:ok, %{"spec" => spec} = receipt} when spec == candidate.spec ->
        {:ok, %{status: :existing, candidate: candidate, receipt: receipt}}

      {:ok, _} ->
        {:error, {:conflict, candidate.group, candidate.kind, candidate.name}}

      :missing ->
        payload = %{candidate: candidate, role: role, authority: authority}

        {operation, payload} =
          if is_binary(bytes),
            do: {:put_bytes, Map.put(payload, :bytes, bytes)},
            else: {:admit, payload}

        case driver.(operation, payload) do
          {:ok, receipt} -> {:ok, %{status: :admitted, candidate: candidate, receipt: receipt}}
          error -> error
        end

      error ->
        error
    end
  end

  defp source(dir) do
    with {:ok, manifest_bytes} <- File.read(Path.join(dir, "bundle.json")),
         {:ok,
          %{"engine" => "cedar", "sources" => [%{"file" => "base.cedar", "sha256" => digest}]}} <-
           Jason.decode(manifest_bytes),
         {:ok, bytes} <- File.read(Path.join(dir, "base.cedar")),
         true <- digest == hash(bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_policy_manifest}
    end
  end

  defp measurement_valid(%{bytes: bytes, address: addr, spec: spec}) when is_binary(bytes) do
    if addr == address(bytes) and
         spec == object_spec(bytes, "application/vnd.r5e.engine-build+json"),
       do: :ok,
       else: {:error, :invalid_engine_measurement}
  end

  defp measurement_valid(_), do: {:error, :invalid_engine_measurement}

  defp plan_valid(%{node_endorsement: e, operator_badge: b}, paths) do
    valid =
      Enum.all?([{e, "Endorsement"}, {b, "Badge"}], fn {c, kind} ->
        c[:group] == "core.r5e.io" and c[:version] == "v1" and c[:kind] == kind and
          is_map(c[:spec]) and Enum.sort(c.spec["kinds"] || []) == paths
      end)

    if valid and is_binary(e.spec["subject"]) and e.spec["subject"] == b.spec["subject"],
      do: :ok,
      else: {:error, :invalid_authority_plan}
  end

  defp plan_valid(_, _), do: {:error, :invalid_authority_plan}

  defp candidate(kind, name, spec),
    do: %{group: "core.r5e.io", version: "v1", kind: kind, name: name, spec: spec}

  defp path(spec), do: Enum.join([spec["group"], spec["version"], spec["kind"]], "/")

  defp object_spec(bytes, media),
    do: %{
      "address" => address(bytes),
      "size" => byte_size(bytes),
      "class" => "raw",
      "mediaType" => media
    }

  defp address(bytes), do: "bytes:sha256:" <> hash(bytes)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
