defmodule R5eRecurse.ManagedRequestTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.ManagedRequest

  defp opts(body \\ ~s({"messages":[{"content":"hello\\nworld"}],"extra":"harness"})) do
    %{
      session_binding: "event:sha256:" <> String.duplicate("1", 64),
      llm_call: "event:sha256:" <> String.duplicate("2", 64),
      inbound_body: body,
      outbound_body: body,
      first_request: true,
      rendered_input: "hello\nworld",
      input_path: "/messages/0/content",
      method: "POST",
      path: "/v1/messages",
      upstream: "https://api.example.test",
      transport: "https",
      operation_id: "operation-1",
      headers: [],
      harness_inputs: []
    }
  end

  test "preserves original JSON bytes and hashes the decoded input" do
    o = opts(" { \"messages\" : [{\"content\":\"hello\\u000aworld\"}],\"n\":9007199254740993 } ")
    assert {:ok, result} = ManagedRequest.build(o)
    assert result.bodies == %{inbound: o.inbound_body, outbound: o.outbound_body}
    assert result.spec["inboundBody"] == result.spec["outboundBody"]
    assert result.spec["bodyDigest"] == hash(o.inbound_body)

    assert result.spec["firstInput"] == %{
             "fieldPath" => o.input_path,
             "digest" => hash(o.rendered_input)
           }

    assert result.spec["inboundBody"] == %{"$ref" => "bytes:" <> hash(o.inbound_body)}
  end

  test "first input is exact UTF-8 equality with no trimming or normalization" do
    for value <- ["hello\nworld ", "hello\r\nworld", "héllo\nworld"] do
      assert {:error, :first_input_mismatch} =
               ManagedRequest.build(%{opts() | rendered_input: value})
    end
  end

  test "missing, invalid, and non-string selected segments refuse" do
    for path <- [
          "messages/0/content",
          "/messages/01/content",
          "/messages/-/content",
          "/messages/0",
          "/absent",
          "/bad~2"
        ] do
      assert {:error, :unidentifiable_input} = ManagedRequest.build(%{opts() | input_path: path})
    end

    assert {:error, :invalid_json} = ManagedRequest.build(opts("not json"))
  end

  test "JSON pointer escaping and root strings work" do
    assert {:ok, _} =
             ManagedRequest.build(%{
               opts(~s({"a/b":{"~":"hello\\nworld"}}))
               | input_path: "/a~1b/~0"
             })

    assert {:ok, _} = ManagedRequest.build(%{opts(~s("hello\\nworld")) | input_path: ""})
  end

  test "duplicates anywhere including escaped equivalent keys refuse" do
    for body <- [~s({"x":1,"x":2}), ~s({"x":{"a":1,"\\u0061":2}}), ~s({"x":[{"a":1,"a":2}]})] do
      assert {:error, :duplicate_json_key} = ManagedRequest.build(opts(body))
    end
  end

  test "even semantically identical outbound JSON transformation refuses" do
    assert {:error, :body_transformation} =
             ManagedRequest.build(%{opts() | outbound_body: opts().inbound_body <> " "})
  end

  test "only fixed semantic headers are retained, case insensitively" do
    headers = [
      {"Authorization", "Bearer secret"},
      {"X-Api-Key", "secret"},
      {"Cookie", "secret"},
      {"Proxy-Authorization", "secret"},
      {"X-Unknown", "secret"},
      {"Content-Type", "application/json"},
      {"Anthropic-Version", "2023-06-01"},
      {"Anthropic-Beta", "one"},
      {"anthropic-beta", "two"}
    ]

    assert {:ok, r} = ManagedRequest.build(%{opts() | headers: headers})

    assert r.spec["semanticHeaders"] ==
             Enum.map(Enum.drop(headers, 5), fn {k, v} ->
               %{"name" => String.downcase(k), "value" => v}
             end)

    refute inspect(r) =~ "secret"

    assert {:error, :invalid_headers} =
             ManagedRequest.build(%{opts() | headers: [{"Accept", "x\r\ny"}]})
  end

  test "later inputs skip manifest equality but still require an identified string" do
    assert {:ok, r} =
             ManagedRequest.build(%{
               opts()
               | first_request: false,
                 rendered_input: "different",
                 harness_inputs: [
                   %{"fieldPath" => "/extra", "provenance" => %{"$ref" => opts().session_binding}}
                 ]
             })

    assert r.harness_inputs == [
             %{
               "fieldPath" => "/extra",
               "digest" => hash("harness"),
               "provenance" => %{"$ref" => opts().session_binding}
             }
           ]

    assert r.spec["harnessInputs"] == r.harness_inputs

    assert {:error, :unidentifiable_input} =
             ManagedRequest.build(%{opts() | first_request: false, input_path: "/missing"})

    assert {:error, :invalid_harness_input} =
             ManagedRequest.build(%{opts() | harness_inputs: [%{"fieldPath" => "/extra"}]})
  end

  test "malformed adapter arguments and caller signing fields refuse" do
    for o <- [
          Map.put(opts(), :nonce, "caller"),
          Map.delete(opts(), :first_request),
          %{opts() | first_request: nil},
          %{opts() | llm_call: "not-admitted-ref"},
          nil
        ] do
      assert {:error, :invalid_options} = ManagedRequest.build(o)
    end
  end

  test "malformed UTF-8 adapter values refuse without raising" do
    assert {:error, :invalid_options} = ManagedRequest.build(%{opts() | input_path: <<255>>})

    assert {:error, :invalid_headers} =
             ManagedRequest.build(%{opts() | headers: [{<<255>>, "value"}]})

    assert {:error, :invalid_harness_input} =
             ManagedRequest.build(%{
               opts()
               | harness_inputs: [
                   %{"fieldPath" => <<255>>, "provenance" => %{"$ref" => opts().session_binding}}
                 ]
             })
  end

  test "improper adapter lists refuse without raising" do
    assert {:error, :invalid_headers} =
             ManagedRequest.build(%{
               opts()
               | headers: [{"accept", "application/json"} | :invalid]
             })

    assert {:error, :invalid_harness_input} =
             ManagedRequest.build(%{
               opts()
               | harness_inputs: [
                   %{"fieldPath" => "/extra", "provenance" => %{"$ref" => opts().session_binding}}
                   | :invalid
                 ]
             })
  end

  test "canonical inventory preserves pointer bytes and rejects ambiguity" do
    provenance = %{"$ref" => opts().session_binding}
    descriptor = fn path -> %{"fieldPath" => path, "provenance" => provenance} end

    body =
      Jason.encode!(%{
        "input" => "hello\nworld",
        "a/b" => "slash",
        "a" => %{"b" => "nested"},
        "é" => "composed",
        "é" => "decomposed"
      })

    o = %{opts(body) | input_path: "/input"}
    paths = Enum.sort(["/a~1b", "/a/b", "/é", "/é"])

    assert {:ok, result} =
             ManagedRequest.build(%{o | harness_inputs: Enum.map(paths, descriptor)})

    assert Enum.map(result.spec["harnessInputs"], & &1["fieldPath"]) == paths
    assert result.bodies.inbound == body

    assert Enum.map(result.spec["harnessInputs"], & &1["digest"]) ==
             Enum.map(["nested", "slash", "decomposed", "composed"], &hash/1)

    for paths <- [["/a~1b", "/a/b"], ["/a/b", "/a/b"], ["/input"]] do
      assert {:error, :invalid_harness_input} =
               ManagedRequest.build(%{o | harness_inputs: Enum.map(paths, descriptor)})
    end

    assert {:ok, %{spec: %{"harnessInputs" => []}}} = ManagedRequest.build(o)
  end

  defp hash(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
