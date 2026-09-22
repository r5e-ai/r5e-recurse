defmodule R5eRecurse.KindsTest do
  use ExUnit.Case, async: true

  test "all declared Kinds have paired fixtures and an explicit epistemic scope" do
    definitions = R5eRecurse.Kinds.definitions()
    assert length(definitions) == 16

    for definition <- definitions do
      assert definition["requiresAuthority"] == true
      assert definition["epistemicScope"]["claims"] != []
      assert definition["epistemicScope"]["doesNotClaim"] != []
    end
  end

  test "policy management cannot appear in workload scope" do
    bundle = Enum.find(R5eRecurse.Kinds.definitions(), &(&1["kind"] == "PolicyBundle"))
    scope = bundle["schema"]["properties"]["governs"]["items"]["enum"]
    refute R5eRecurse.Kinds.path("PolicyBundle") in scope
    assert Enum.sort(scope) == Enum.sort(R5eRecurse.Kinds.governed_kinds())
    assert bundle["requiresAuthority"]
  end

  test "both manifest and binding declare all cooperative custody labels" do
    for kind <- ["SessionBinding", "ContextManifest"] do
      definition = Enum.find(R5eRecurse.Kinds.definitions(), &(&1["kind"] == kind))

      for label <- ~w(custody profile signerReachability) do
        assert label in definition["schema"]["required"]
      end
    end
  end
end
