defmodule R5eRecurse.Commands.Envelope do
  @moduledoc false
  alias RecurseVerify.{Canonical, DSSE}

  @operations ~w(submit_task start_session cancel_session record_decision request_push recover_attempt select_lesson)
  @type_name "application/vnd.r5e.admission-request+json;v=1"
  @target %{
    "group" => "recurse.r5e.io",
    "version" => "v1alpha1",
    "kind" => "Command",
    "name" => nil
  }

  def operations, do: @operations
  def target, do: @target
  def scoped_id(origin, caller, id), do: Canonical.hash([origin, caller, id])

  def spec(command, caller) do
    fields = ~w(command_id operation origin target expected_state_ref payload)

    with true <- is_map(command) and Enum.sort(Map.keys(command)) == Enum.sort(fields),
         true <- command["operation"] in @operations,
         true <-
           Enum.all?(
             ~w(command_id origin target),
             &(is_binary(command[&1]) and command[&1] != "")
           ),
         true <- is_map(command["payload"]),
         true <- is_nil(command["expected_state_ref"]) or is_binary(command["expected_state_ref"]) do
      digest = Canonical.hash(Map.drop(command, ["command_id"]))

      spec = %{
        "commandId" => scoped_id(command["origin"], caller, command["command_id"]),
        "operation" => command["operation"],
        "payloadDigest" => digest,
        "target" => command["target"]
      }

      spec =
        if command["expected_state_ref"],
          do: Map.put(spec, "expectedState", %{"$ref" => command["expected_state_ref"]}),
          else: spec

      {:ok, spec}
    else
      _ -> {:error, :invalid_command}
    end
  rescue
    _ -> {:error, :invalid_command}
  end

  # Verify the first signer: the kernel's nonce identity. Other signatures may
  # exist on non-Command records (for example subject-countersigned Badges).
  def verify_signed(envelope) do
    with %{"payloadType" => @type_name, "publicKeys" => keys, "signatures" => [signature | _]} <-
           envelope,
         key_id when is_binary(key_id) <- signature["keyid"],
         %{"algorithm" => "ed25519", "bytes" => encoded} <-
           Enum.find(keys, &(&1["keyid"] == key_id)),
         {:ok, public} <- DSSE.decode64(encoded),
         ^key_id <- DSSE.key_id!("ed25519", public),
         {:ok, bytes, ^key_id} <- DSSE.verify(envelope, public),
         {:ok, request} <- Canonical.decode_json(bytes),
         ^bytes <- Canonical.encode(request),
         true <-
           Enum.sort(Map.keys(request)) ==
             Enum.sort(~w(origin actor target specAddress derivedFrom authority nonce expires)) do
      {:ok, %{caller: key_id, public_key: public, request: request}}
    else
      _ -> {:error, :invalid_command_signature}
    end
  rescue
    _ -> {:error, :invalid_command_signature}
  end

  def authenticate(command, envelope, origin) do
    with %{"publicKeys" => [_], "signatures" => [_]} <- envelope,
         {:ok, verified} <- verify_signed(envelope),
         true <- verified.caller == verified.request["actor"],
         ^origin <- verified.request["origin"],
         ^origin <- command["origin"],
         @target <- verified.request["target"],
         {:ok, spec} <- spec(command, verified.caller),
         address <- Canonical.hash(spec),
         ^address <- verified.request["specAddress"] do
      {:ok, Map.put(verified, :spec, spec)}
    else
      _ -> {:error, :invalid_command_signature}
    end
  rescue
    _ -> {:error, :invalid_command_signature}
  end
end
