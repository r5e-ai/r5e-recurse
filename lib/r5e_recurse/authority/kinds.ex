defmodule R5eRecurse.Authority.Kinds do
  @moduledoc "Exact admission Kind sets; these lists confer no field-level scope."
  @runtime ~w(gateway.r5e.io/v1alpha1/AgentSession gateway.r5e.io/v1alpha1/ToolCall recurse.r5e.io/v1alpha1/SessionBinding recurse.r5e.io/v1alpha1/Artifact core.r5e.io/v1/CasObject)
  @model @runtime ++
           ~w(gateway.r5e.io/v1alpha1/Prompt gateway.r5e.io/v1alpha1/LlmCall recurse.r5e.io/v1alpha1/ManagedRequest)

  def for_role(:runtime_action), do: {:ok, Enum.sort(@runtime)}
  def for_role(:producer), do: {:ok, Enum.sort(@model)}
  def for_role(:reviewer), do: {:ok, Enum.sort(@model ++ ["recurse.r5e.io/v1alpha1/Review"])}

  def for_role(:delegated_decision),
    do:
      {:ok,
       Enum.sort(@model ++ ~w(recurse.r5e.io/v1alpha1/Review recurse.r5e.io/v1alpha1/Decision))}

  def for_role(_), do: {:error, :unknown_role}
  def task_creation, do: ["recurse.r5e.io/v1alpha1/Task"]
end
