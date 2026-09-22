defmodule R5eRecurse.ManagedRequest do
  @moduledoc """
  Pure preparation of ManagedRequest candidates. No signing, admission or dispatch.

  `build/1` receives trusted adapter state: admitted event refs, exact inbound and
  outbound binaries, `first_request` (a boolean from serialized session state),
  ContextManifest `rendered_input`, an RFC 6901 `input_path`, routing metadata,
  header pairs, and `harness_inputs` descriptors containing `fieldPath` and
  `provenance`. Provenance is an admitted event reference supplied by the adapter.
  Harness provenance is recorded in canonical harnessInputs. The builder checks
  exact strings, syntax and ordering, not source admission or inventory completeness.
  The caller must resolve those refs and the rendered bytes from verified records;
  syntactic ref validation here does not establish admission or authority.

  JSON is decoded with ordered objects so duplicate keys anywhere are rejected.
  Decoding is solely for string inspection: returned body bytes are never encoded
  again. Header recording uses a fixed semantic allowlist, never caller-supplied
  names. The caller remains responsible for forwarding these exact bound values.
  """
  @headers ~w(content-type accept anthropic-version anthropic-beta openai-beta)
  @fields ~w(session_binding llm_call inbound_body outbound_body first_request rendered_input input_path method path upstream transport headers operation_id harness_inputs)a

  def build(opts) when is_map(opts) do
    with true <- Enum.sort(Map.keys(opts)) == Enum.sort(@fields),
         true <- valid_options?(opts),
         :ok <- unchanged(opts.inbound_body, opts.outbound_body),
         {:ok, json} <- decode(opts.inbound_body),
         {:ok, input} <- input(json, opts.input_path),
         :ok <- first_input(opts.first_request, input, opts.rendered_input),
         {:ok, harness} <- harness_inputs(json, opts.harness_inputs),
         true <-
           R5eRecurse.HarnessInputs.valid?(harness, opts.input_path) or
             {:error, :invalid_harness_input},
         {:ok, headers} <- semantic_headers(opts.headers) do
      digest = digest(opts.inbound_body)
      body_ref = %{"$ref" => "bytes:" <> digest}

      spec = %{
        "sessionBinding" => %{"$ref" => opts.session_binding},
        "llmCall" => %{"$ref" => opts.llm_call},
        "inboundBody" => body_ref,
        "outboundBody" => body_ref,
        "bodyDigest" => digest,
        "firstInput" => %{"fieldPath" => opts.input_path, "digest" => digest(input)},
        "method" => opts.method,
        "path" => opts.path,
        "upstream" => opts.upstream,
        "transport" => opts.transport,
        "semanticHeaders" => headers,
        "harnessInputs" => harness,
        "operationId" => opts.operation_id
      }

      {:ok,
       %{
         target: %{
           "group" => "recurse.r5e.io",
           "version" => "v1alpha1",
           "kind" => "ManagedRequest",
           "name" => nil
         },
         spec: spec,
         harness_inputs: harness,
         bodies: %{inbound: opts.inbound_body, outbound: opts.outbound_body}
       }}
    else
      false -> {:error, :invalid_options}
      {:error, _} = error -> error
    end
  end

  def build(_), do: {:error, :invalid_options}

  defp valid_options?(o) do
    Enum.all?([o.session_binding, o.llm_call], &event_ref?/1) and
      Enum.all?([o.inbound_body, o.outbound_body, o.rendered_input, o.input_path], &is_binary/1) and
      String.valid?(o.rendered_input) and String.valid?(o.input_path) and
      is_boolean(o.first_request) and
      Enum.all?(
        [o.method, o.path, o.upstream, o.transport, o.operation_id],
        &(is_binary(&1) and &1 != "" and String.valid?(&1))
      )
  end

  defp unchanged(bytes, bytes), do: :ok
  defp unchanged(_, _), do: {:error, :body_transformation}
  defp first_input(true, bytes, bytes), do: :ok
  defp first_input(true, _, _), do: {:error, :first_input_mismatch}
  defp first_input(false, _, _), do: :ok

  defp decode(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, json} -> if unique?(json), do: {:ok, json}, else: {:error, :duplicate_json_key}
      _ -> {:error, :invalid_json}
    end
  end

  defp unique?(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(keys) == length(Enum.uniq(keys)) and Enum.all?(pairs, fn {_, v} -> unique?(v) end)
  end

  defp unique?(items) when is_list(items), do: Enum.all?(items, &unique?/1)
  defp unique?(_), do: true

  defp input(json, path) when is_binary(path) do
    with true <- String.valid?(path),
         {:ok, tokens} <- pointer(path),
         value when is_binary(value) <- Enum.reduce(tokens, json, &step/2) do
      {:ok, value}
    else
      _ -> {:error, :unidentifiable_input}
    end
  end

  defp input(_, _), do: {:error, :unidentifiable_input}

  defp pointer(""), do: {:ok, []}

  defp pointer("/" <> rest) do
    if Regex.match?(~r/~(?:[^01]|$)/, rest) do
      :error
    else
      {:ok,
       rest
       |> String.split("/")
       |> Enum.map(&(String.replace(&1, "~1", "/") |> String.replace("~0", "~")))}
    end
  end

  defp pointer(_), do: :error

  defp step(key, %Jason.OrderedObject{values: pairs}), do: case_fetch(pairs, key)

  defp step(key, list) when is_list(list) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, key),
      do: Enum.at(list, String.to_integer(key)),
      else: nil
  end

  defp step(_, _), do: nil
  defp case_fetch(pairs, key), do: pairs |> List.keyfind(key, 0, {key, nil}) |> elem(1)

  defp harness_inputs(json, items) when is_list(items) and length(items) >= 0 do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      with %{"fieldPath" => path, "provenance" => %{"$ref" => ref} = provenance} <- item,
           true <- map_size(item) == 2 and map_size(provenance) == 1 and event_ref?(ref),
           {:ok, value} <- input(json, path) do
        {:cont,
         {:ok,
          acc ++ [%{"fieldPath" => path, "digest" => digest(value), "provenance" => provenance}]}}
      else
        _ -> {:halt, {:error, :invalid_harness_input}}
      end
    end)
  end

  defp harness_inputs(_, _), do: {:error, :invalid_harness_input}

  defp semantic_headers(headers) when is_list(headers) and length(headers) >= 0 do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        if String.valid?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name) and
             String.valid?(value) and
             not String.contains?(value, ["\r", "\n", <<0>>]) do
          name = String.downcase(name)
          entry = %{"name" => name, "value" => value}
          {:cont, {:ok, if(name in @headers, do: acc ++ [entry], else: acc)}}
        else
          {:halt, {:error, :invalid_headers}}
        end

      _, _ ->
        {:halt, {:error, :invalid_headers}}
    end)
  end

  defp semantic_headers(_), do: {:error, :invalid_headers}

  defp event_ref?(ref) when is_binary(ref),
    do: String.valid?(ref) and Regex.match?(~r/\Aevent:sha256:[0-9a-f]{64}\z/, ref)

  defp event_ref?(_), do: false
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
