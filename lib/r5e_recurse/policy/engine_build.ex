defmodule R5eRecurse.Policy.EngineBuild do
  @moduledoc "Measurements of the deployed adapter, its presentation code, and kernel Cedar NIF."
  @compile {:no_warn_undefined, [R5e.Policy.EngineBuild, R5e.Canonical, R5e.CAS, R5e.RefIndex]}
  @modules [R5eRecurse.Policy, R5eRecurse.Policy.Presentation, __MODULE__]

  def media_type, do: "application/vnd.r5e.engine-build+json"

  def measure do
    descriptor =
      R5e.Policy.EngineBuild.descriptor()
      |> Map.put("module", inspect(R5eRecurse.Policy))
      |> Map.put("moduleSha256", module_hash(R5eRecurse.Policy))
      |> Map.put("adapterModules", Map.new(@modules, &{inspect(&1), module_hash(&1)}))

    bytes = R5e.Canonical.encode(descriptor)
    spec = R5e.CAS.object_spec(bytes, media_type())
    %{address: spec["address"], bytes: bytes, spec: spec}
  end

  @doc "Verify this deployment's measured descriptor has an admitted CasObject."
  def admitted do
    measurement = measure()

    with {:ok, object} <- R5e.RefIndex.cas_object(measurement.address),
         true <-
           object["mediaType"] == media_type() and object["size"] == byte_size(measurement.bytes),
         {:ok, bytes} <- R5e.CAS.get(measurement.address),
         true <- bytes == measurement.bytes do
      {:ok, measurement.address}
    else
      _ -> {:error, "this adapter's measured engine descriptor is not admitted"}
    end
  end

  defp module_hash(module) do
    case :code.get_object_code(module) do
      {^module, bytes, _path} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      :error -> raise "cannot measure deployed module #{inspect(module)}"
    end
  end
end
