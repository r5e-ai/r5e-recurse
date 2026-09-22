defmodule R5eRecurse.Commands.Dedup do
  @moduledoc "Rebuild semantic Command outcomes and chain-wide protocol nonce claims."
  alias R5eRecurse.Commands.Envelope
  alias RecurseVerify.Canonical
  @target Envelope.target()
  @bound_denial_stages ~w(validateStructure resolve authorize validateConstraints record)

  def rebuild(records, origin) do
    Enum.reduce_while(
      records,
      {:ok, %{commands: %{}, denials: %{}, nonces: MapSet.new()}},
      fn record, {:ok, index} ->
        case observe(index, record, origin) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp observe(index, %{event: event, payload: %{"identity" => "signed"} = payload}, origin) do
    with {:ok, %{caller: caller, request: request}} <- Envelope.verify_signed(payload["signed"]),
         ^caller <- get_in(payload, ["actor", "id"]),
         true <- payload["nonce"] == request["nonce"] and payload["origin"] == request["origin"],
         true <- payload["submittedTarget"] == request["target"] do
      # Kernel claims before checking origin or expiry. A wrong-origin denial
      # therefore still spends this signer's nonce on this chain.
      index =
        if nonce_claimed?(payload),
          do: %{index | nonces: MapSet.put(index.nonces, {caller, request["nonce"]})},
          else: index

      if semantic_outcome?(payload) and request["origin"] == origin and request["actor"] == caller and
           request["target"] == @target do
        observe_command(index, event, payload, request, caller)
      else
        {:ok, index}
      end
    else
      _ -> {:error, :malformed_signed_history}
    end
  end

  defp observe(index, _, _), do: {:ok, index}

  # The canonical kernel stage is the leading reason field, never a substring
  # in arbitrary diagnostics. These are the two pre-claim outcomes in core.
  defp nonce_claimed?(%{
         "outcome" => "denied",
         "reason" => "authenticate: actor mismatch: " <> _
       }),
       do: false

  defp nonce_claimed?(%{
         "outcome" => "denied",
         "reason" => "authenticate: nonce replayed: " <> _
       }),
       do: false

  defp nonce_claimed?(%{"outcome" => outcome}), do: outcome in ["admitted", "denied"]

  # Authentication denials precede body binding. Never derive a semantic ID
  # from their raw transport spec, even if it happens to look like a Command.
  defp semantic_outcome?(%{"outcome" => "admitted"}), do: true

  defp semantic_outcome?(%{"outcome" => "denied", "reason" => reason}) when is_binary(reason),
    do: hd(String.split(reason, ": ", parts: 2)) in @bound_denial_stages

  defp semantic_outcome?(_), do: false

  defp observe_command(index, event, payload, request, caller) do
    spec = payload["spec"]

    bound =
      is_map(spec) and Canonical.address(spec) == request["specAddress"] and
        Map.take(payload["target"] || %{}, ~w(group version kind)) == Map.drop(@target, ["name"]) and
        is_binary(spec["commandId"]) and is_binary(spec["payloadDigest"])

    if bound do
      key = {caller, spec["commandId"]}

      entry = %{
        digest: spec["payloadDigest"],
        result: %{
          event_ref: "event:" <> event["hash"],
          target: spec["target"],
          execution: :not_implemented,
          outcome: payload["outcome"]
        }
      }

      if payload["outcome"] == "denied" do
        {:ok, %{index | denials: Map.put_new(index.denials, key, entry)}}
      else
        case Map.fetch(index.commands, key) do
          :error -> {:ok, %{index | commands: Map.put(index.commands, key, entry)}}
          {:ok, ^entry} -> {:ok, index}
          {:ok, _} -> {:error, :contradictory_command_history}
        end
      end
    else
      if payload["outcome"] == "denied",
        do: {:ok, index},
        else: {:error, :malformed_command_history}
    end
  end
end
