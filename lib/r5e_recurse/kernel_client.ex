defmodule R5eRecurse.KernelClient do
  @moduledoc """
  HTTP boundary for the pinned kernel API. Accepts already-signed envelopes;
  never signs, redirects or retries. A write without a usable acknowledgement
  is uncertain. Receipts are kernel claims, not offline verification results.

  `/events` has no sequence query: filtering is local. Historical reads use
  an exact granted event and digest-checked CAS payload, never the resource
  projection. Export writes on the server and does not download a bundle.
  """
  @enforce_keys [:url]
  defstruct [:url, timeout: 15_000]
  @type t :: %__MODULE__{url: String.t(), timeout: pos_integer()}
  @type result(a) ::
          {:ok, a}
          | {:denied, map()}
          | {:refused, map()}
          | {:transport_failure, term()}
          | {:outcome_unknown, term()}
          | {:error, term()}

  def new(url, opts \\ []) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        %__MODULE__{
          url: String.trim_trailing(url, "/"),
          timeout: Keyword.get(opts, :timeout, 15_000)
        }

      _ ->
        raise ArgumentError, "expected an HTTP kernel URL without credentials, query or fragment"
    end
  end

  @spec submit(t(), map(), map(), map()) :: result(map())
  def submit(client, target, envelope, spec) do
    path =
      "/apis/" <>
        Enum.map_join(~w(group version kind), "/", &URI.encode_www_form(Map.fetch!(target, &1)))

    write(
      client,
      :post,
      path,
      Jason.encode!(%{envelope: envelope, spec: spec, name: target["name"]}),
      [],
      "application/json"
    )
  end

  @spec put_cas(t(), map(), binary(), String.t()) :: result(map())
  def put_cas(client, envelope, bytes, media_type \\ "application/octet-stream") do
    header = Base.encode64(Jason.encode!(envelope))

    if byte_size(header) > 8192 do
      {:error, :envelope_header_too_large}
    else
      case write(
             client,
             :put,
             "/cas",
             bytes,
             [{~c"x-r5e-request", String.to_charlist(header)}],
             media_type
           ) do
        {:ok, %{"address" => address, "size" => size} = receipt} ->
          if address == "bytes:" <> digest(bytes) and size == byte_size(bytes),
            do: {:ok, receipt},
            else: {:outcome_unknown, :cas_receipt_mismatch}

        {:ok, _} ->
          {:outcome_unknown, :invalid_cas_receipt}

        other ->
          other
      end
    end
  end

  @spec get_cas(t(), String.t()) :: result(binary())
  def get_cas(client, address) do
    if is_binary(address) and Regex.match?(~r/\A(?:bytes:)?sha256:[0-9a-f]{64}\z/, address) do
      case request(client, :get, "/cas/" <> address, nil, [], nil) do
        {:ok, 200, bytes} ->
          if String.replace_prefix(address, "bytes:", "") == digest(bytes),
            do: {:ok, bytes},
            else: {:error, :digest_mismatch}

        {:ok, 404, _} ->
          {:error, :not_found}

        other ->
          read_error(other)
      end
    else
      {:error, :invalid_object_address}
    end
  end

  @spec events_from(t(), pos_integer()) :: result([map()])
  def events_from(client, sequence) when is_integer(sequence) and sequence >= 1 do
    with {:ok, 200, body} <- request(client, :get, "/events", nil, [], nil),
         {:ok, %{"events" => events}} when is_list(events) <- Jason.decode(body),
         true <-
           Enum.all?(
             events,
             &(is_map(&1) and is_integer(&1["seq"]) and is_binary(&1["hash"]) and
                 is_binary(&1["payload"]))
           ) do
      {:ok, Enum.filter(events, &(&1["seq"] >= sequence))}
    else
      other -> read_error(other)
    end
  end

  @spec resource_at_admission(t(), String.t(), map()) :: result(map())
  def resource_at_admission(client, event_ref, target) do
    with {:ok, events} <- events_from(client, 1),
         event when not is_nil(event) <- Enum.find(events, &("event:" <> &1["hash"] == event_ref)),
         true <- RecurseVerify.Canonical.address(Map.delete(event, "hash")) == event["hash"],
         "admission.granted" <- event["kind"],
         {:ok, bytes} <- get_cas(client, event["payload"]),
         {:ok, %{"outcome" => "admitted", "target" => ^target, "spec" => spec} = payload} <-
           Jason.decode(bytes) do
      {:ok, %{event: event, payload: payload, spec: spec}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      {:transport_failure, _} = error -> error
      _ -> {:error, :admission_mismatch}
    end
  end

  @doc "Request an export to an explicit server-side path; result is server location and manifest."
  @spec export(t(), String.t()) :: result(map())
  def export(client, server_path) when is_binary(server_path) and byte_size(server_path) > 0 do
    case request(
           client,
           :post,
           "/export",
           Jason.encode!(%{path: server_path}),
           [],
           "application/json"
         ) do
      {:ok, 201, body} ->
        case Jason.decode(body) do
          {:ok, %{"bundle" => location, "manifest" => manifest}}
          when is_binary(location) and is_map(manifest) ->
            {:ok, %{server_path: location, manifest: manifest}}

          _ ->
            {:outcome_unknown, :invalid_export_response}
        end

      other ->
        write_error(other)
    end
  end

  defp write(client, method, path, body, headers, type) do
    decode_write(request(client, method, path, body, headers, type))
  end

  @doc "Decode a raw write response using the shared kernel receipt contract."
  def decode_write(response) do
    case response do
      {:ok, status, body} when status in [201, 403] ->
        case {status, Jason.decode(body)} do
          {201, {:ok, %{"outcome" => "admitted", "recorded" => true} = receipt}} ->
            receipt_result(:ok, receipt)

          {403,
           {:ok, %{"outcome" => "denied", "recorded" => true, "identity" => "signed"} = receipt}} ->
            receipt_result(:denied, receipt)

          {403, {:ok, %{"outcome" => "refused", "recorded" => false} = receipt}} ->
            {:refused, receipt}

          _ ->
            {:outcome_unknown, :invalid_receipt}
        end

      other ->
        write_error(other)
    end
  end

  defp receipt_result(tag, %{"seq" => seq, "event" => hash, "eventRef" => ref} = receipt)
       when is_integer(seq) and seq > 0 and is_binary(hash) do
    if Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, hash) and ref == "event:" <> hash,
      do: {tag, receipt},
      else: {:outcome_unknown, :invalid_receipt}
  end

  defp receipt_result(_, _), do: {:outcome_unknown, :invalid_receipt}

  defp request(client, method, path, body, headers, type) do
    url = String.to_charlist(client.url <> path)
    headers = [{~c"connection", ~c"close"} | headers]
    req = if body == nil, do: {url, headers}, else: {url, headers, String.to_charlist(type), body}

    case :httpc.request(
           method,
           req,
           [
             timeout: client.timeout,
             connect_timeout: client.timeout,
             autoredirect: false,
             autoretry: 0,
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]
           ],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, bytes}} -> {:ok, status, bytes}
      {:error, {:failed_connect, _}} -> {:transport_failure, :connection_failed}
      {:error, _} -> {:transport_failure, :connection_lost}
    end
  end

  defp write_error({:transport_failure, :connection_failed} = error), do: error
  defp write_error({:transport_failure, _}), do: {:outcome_unknown, :connection_lost}

  defp write_error({:ok, status, _}), do: {:outcome_unknown, {:http_status, status}}
  defp read_error({:transport_failure, _} = error), do: error
  defp read_error({:ok, status, _}), do: {:error, {:http_status, status}}
  defp read_error(_), do: {:error, :invalid_response}
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
