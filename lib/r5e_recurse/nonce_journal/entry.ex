defmodule R5eRecurse.NonceJournal.Entry do
  @moduledoc false
  alias RecurseVerify.{Canonical, DSSE, Instant}
  alias R5eRecurse.Commands.Envelope
  @base ~w(operationId origin generation candidate candidateDigest status)
  @max_integer_bytes 1024

  def valid?(entry, origin) do
    with true <- is_map(entry),
         true <- json_value?(entry),
         {:ok, ^entry} <- Canonical.decode_json(Canonical.encode(entry)),
         true <- entry["origin"] == origin and is_binary(origin),
         true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, origin),
         true <- is_binary(entry["operationId"]) and entry["operationId"] != "",
         true <- generation?(entry["generation"]),
         %{"target" => target, "spec" => spec} = candidate <- entry["candidate"],
         true <- map_size(candidate) == 2 and is_map(spec) and is_map(target),
         true <- json_value?(candidate),
         true <- Enum.sort(Map.keys(target)) == ~w(group kind name version),
         true <- Enum.all?(~w(group kind version), &(is_binary(target[&1]) and target[&1] != "")),
         true <- is_nil(target["name"]) or is_binary(target["name"]),
         true <- Canonical.hash(candidate) == entry["candidateDigest"] do
      case entry["status"] do
        "reserved" ->
          Enum.sort(Map.keys(entry)) == Enum.sort(@base)

        "prepared" ->
          Enum.sort(Map.keys(entry)) == Enum.sort(@base ++ ~w(envelope request)) and
            signed?(entry)

        _ ->
          false
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp json_value?(v) when is_map(v),
    do: Enum.all?(v, fn {k, x} -> is_binary(k) and String.valid?(k) and json_value?(x) end)

  defp json_value?(v) when is_list(v), do: Enum.all?(v, &json_value?/1)
  defp json_value?(v) when is_binary(v), do: String.valid?(v)

  defp json_value?(v) when is_integer(v),
    do: byte_size(Integer.to_string(v)) <= @max_integer_bytes

  defp json_value?(v), do: is_boolean(v) or is_nil(v)

  def generation?(%{"bootId" => boot, "runId" => run} = g) when map_size(g) == 2,
    do: is_binary(boot) and boot != "" and is_binary(run) and run != ""

  def generation?(_), do: false

  def nonce_key(%{"status" => "prepared", "request" => r}), do: {r["actor"], r["nonce"]}
  def nonce_key(_), do: nil

  def reservation(entry), do: entry |> Map.take(@base) |> Map.put("status", "reserved")

  defp signed?(entry) do
    with {:ok, verified} <- Envelope.verify_signed(entry["envelope"]),
         true <- verified.request == entry["request"],
         r = verified.request,
         true <- verified.caller == r["actor"] and r["origin"] == entry["origin"],
         true <- r["target"] == entry["candidate"]["target"],
         true <- r["specAddress"] == Canonical.hash(entry["candidate"]["spec"]),
         {:ok, nonce} <- DSSE.decode64(r["nonce"]),
         true <- byte_size(nonce) == 16,
         true <- Instant.valid?(r["expires"]),
         true <- is_list(r["authority"]),
         true <-
           is_nil(r["derivedFrom"]) or
             (is_binary(r["derivedFrom"]) and
                Regex.match?(~r/\Abytes:sha256:[0-9a-f]{64}\z/, r["derivedFrom"])) do
      true
    else
      _ -> false
    end
  end
end
