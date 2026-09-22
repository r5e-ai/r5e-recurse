defmodule R5eRecurse.HarnessInputs do
  @moduledoc "Closed canonical descriptor syntax; no admission or completeness assertion."

  def valid?(items, primary) when is_list(items) do
    paths = Enum.map(items, & &1["fieldPath"])

    pointer?(primary) and paths == Enum.sort(paths) and
      length(paths) == length(Enum.uniq(paths)) and primary not in paths and
      Enum.all?(items, fn item ->
        Enum.sort(Map.keys(item)) == ~w(digest fieldPath provenance) and
          pointer?(item["fieldPath"]) and digest?(item["digest"]) and
          match?(%{"$ref" => _}, item["provenance"]) and
          map_size(item["provenance"]) == 1 and event_ref?(item["provenance"]["$ref"])
      end)
  rescue
    _ -> false
  end

  def valid?(_, _), do: false
  def pointer?(""), do: true

  def pointer?("/" <> rest),
    do: String.valid?(rest) and not Regex.match?(~r/~(?:[^01]|$)/, rest)

  def pointer?(_), do: false
  def digest?(value) when is_binary(value), do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)
  def digest?(_), do: false

  defp event_ref?("event:" <> digest), do: digest?(digest)
  defp event_ref?(_), do: false
end
