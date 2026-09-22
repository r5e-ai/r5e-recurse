defmodule R5eRecurse.Policy.Boot do
  @moduledoc "Deployment gate: run after kernel replay and policy bootstrap, before admitting traffic."
  @compile {:no_warn_undefined, [R5e.ResourceStore, R5e.Policy, Recurse.Fold.Policy.Cedar]}

  def check! do
    for {module, function, arity} <- [
          {R5e.Policy.Facts, :resolve, 1},
          {R5e.Policy.Facts, :fetch, 1},
          {R5e.Policy.Facts, :event, 1},
          {Recurse.Fold.Policy.Cedar, :authorize, 1},
          {Recurse.Fold.Policy.Cedar, :upstream, 0}
        ] do
      unless Code.ensure_loaded?(module) and function_exported?(module, function, arity),
        do: raise("deployment requires #{inspect(module)}.#{function}/#{arity}")
    end

    case R5e.ResourceStore.get("recurse.r5e.io", "v1alpha1", "PolicyBundle", "active") do
      {:ok, _, _} ->
        unless R5e.Policy.active() == R5eRecurse.Policy and
                 R5eRecurse.Policy.upstream() == Recurse.Fold.Policy.Cedar and
                 Recurse.Fold.Policy.Cedar.upstream() == R5e.Policy.KernelCedar,
               do:
                 raise(
                   "active managed PolicyBundle requires Recurse → fold → kernel policy composition"
                 )

        case R5eRecurse.Policy.EngineBuild.admitted() do
          {:ok, _} -> :ok
          {:error, reason} -> raise reason
        end

      {:error, :not_found} ->
        :ok

      other ->
        raise "cannot inspect active managed PolicyBundle: #{inspect(other)}"
    end
  end
end
