defmodule R5eRecurse.KernelKindsTest do
  use ExUnit.Case, async: false
  @moduletag :kernel
  @moduletag skip: not Code.ensure_loaded?(R5e.Kind)
  @compile {:no_warn_undefined, [R5e.Kind, R5e.Kind.Definition]}

  test "every declaration and valid/invalid fixture is checked by the actual kernel schema validator" do
    for path <- Path.wildcard(Path.expand("../../priv/kinds/*.json", __DIR__)) do
      definition = path |> File.read!() |> Jason.decode!()
      assert :ok == R5e.Kind.Definition.check(definition), Path.basename(path)
      {:ok, kind} = R5e.Kind.from_map(definition)

      fixture =
        Path.join([__DIR__, "..", "fixtures", "kinds", Path.basename(path)])
        |> File.read!()
        |> Jason.decode!()

      assert :ok == R5e.Kind.validate_structure(kind, fixture["valid"]), Path.basename(path)
      assert :ok == R5e.Kind.validate_constraints(kind, fixture["valid"]), Path.basename(path)
      assert {:error, _} = R5e.Kind.validate_constraints(kind, fixture["invalid"])
    end
  end
end
