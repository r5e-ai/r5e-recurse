defmodule R5eRecurse.Commands.OperatorSignature do
  @moduledoc "External Ed25519 operator custody via bounded argv helper; no runtime-key fallback."
  alias RecurseVerify.DSSE

  @payload_type "application/vnd.r5e.admission-request+json;v=1"

  @doc "Sign an already-built canonical Command admission request with the external operator."
  def envelope(opts, request) do
    public = Keyword.fetch!(opts, :public_key)
    key_id = DSSE.key_id!("ed25519", public)

    with true <-
           Enum.sort(Map.keys(request)) ==
             Enum.sort(~w(origin actor target specAddress derivedFrom authority nonce expires)),
         ^key_id <- request["actor"],
         true <- request["target"] == R5eRecurse.Commands.Envelope.target(),
         payload <- RecurseVerify.Canonical.encode(request),
         {:ok, signature} <- sign(opts, DSSE.pae(@payload_type, payload)) do
      {:ok,
       %{
         "payloadType" => @payload_type,
         "payload" => Base.encode64(payload),
         "signatures" => [%{"keyid" => key_id, "sig" => Base.encode64(signature)}],
         "publicKeys" => [
           %{"keyid" => key_id, "algorithm" => "ed25519", "bytes" => Base.encode64(public)}
         ]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_operator_request}
    end
  rescue
    _ -> {:error, :invalid_operator_request}
  end

  def public_key(opts), do: run(opts, "public-key", "\n", 32)

  def sign(opts, message) when is_binary(message) do
    with {:ok, public} <- public_key(opts),
         true <- public == Keyword.fetch!(opts, :public_key),
         {:ok, signature} <- run(opts, "sign", Base.encode16(message, case: :lower) <> "\n", 64),
         true <- DSSE.verify_ed25519(message, signature, public) do
      {:ok, signature}
    else
      false -> {:error, :operator_signature_invalid}
      {:error, _} = error -> error
    end
  end

  defp run(opts, operation, input, size) do
    [executable | arguments] = Keyword.fetch!(opts, :command)
    timeout = Keyword.get(opts, :timeout, 5_000)
    wrapper = Application.app_dir(:r5e_recurse, "priv/commands/operator_helper.py")
    python = System.find_executable("python3")

    if python && Path.type(executable) == :absolute && Enum.all?(arguments, &is_binary/1) &&
         is_integer(timeout) && timeout > 0 && timeout <= 120_000 &&
         byte_size(input) <= 1_048_576 do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: [
            wrapper,
            "256",
            Integer.to_string(timeout),
            executable | arguments ++ [operation]
          ]
        ])

      Port.command(port, input)
      collect(port, "", System.monotonic_time(:millisecond) + timeout + 1_000, size)
    else
      {:error, :operator_helper_configuration}
    end
  rescue
    _ -> {:error, :operator_helper_configuration}
  end

  defp collect(port, output, deadline, size) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= 256 ->
        collect(port, output <> bytes, deadline, size)

      {^port, {:exit_status, 0}} ->
        decode(output, size)

      {^port, {:exit_status, _}} ->
        {:error, :operator_helper_refused}

      {^port, _} ->
        R5eRecurse.Commands.Ownership.close(port)
        {:error, :operator_helper_output}
    after
      remaining ->
        R5eRecurse.Commands.Ownership.close(port)
        {:error, :operator_helper_timeout}
    end
  end

  defp decode(output, size) do
    decoded =
      if Regex.match?(~r/\A[0-9a-fA-F]+\n?\z/, output),
        do: Base.decode16(String.trim_trailing(output, "\n"), case: :mixed),
        else: :error

    case decoded do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _ -> {:error, :operator_helper_output}
    end
  end
end
