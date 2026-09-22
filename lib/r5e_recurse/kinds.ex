defmodule R5eRecurse.Kinds do
  @moduledoc "Recurse-owned Kind declarations. Loading these files is not admission."
  @group "recurse.r5e.io"
  @version "v1alpha1"

  def definitions do
    :r5e_recurse
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("kinds/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
  end

  def group, do: @group
  def version, do: @version
  def path(kind), do: Enum.join([@group, @version, kind], "/")

  def governed_kinds,
    do:
      definitions() |> Enum.reject(&(&1["kind"] == "PolicyBundle")) |> Enum.map(&path(&1["kind"]))
end
