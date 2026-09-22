defmodule R5eRecurse.Signer.RequestTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Signer.Request
  alias RecurseVerify.Canonical
  @prompt "gateway.r5e.io/v1alpha1/Prompt"
  @call "gateway.r5e.io/v1alpha1/LlmCall"
  @managed "recurse.r5e.io/v1alpha1/ManagedRequest"

  setup do
    body = " {\"messages\":[{\"content\":\"hello\"}],\"temperature\":0.5} "
    span = "gateway.r5e.io/v1alpha1/AgentSession/session"
    actor = "key:ed25519:sha256:" <> String.duplicate("a", 64)
    authority = [event("a"), event("b")]

    prompt = %{
      "contentRef" => ref("bytes:" <> Canonical.hash_bytes(body)),
      "session" => ref(span)
    }

    prompt_ref = @prompt <> "/" <> Canonical.hash(prompt)

    call = %{
      "prompt" => ref(prompt_ref),
      "session" => ref(span),
      "model" => "model-1",
      "upstreamHost" => "provider.test"
    }

    managed = %{
      "sessionBinding" => ref(event("c")),
      "llmCall" => ref(event("d")),
      "inboundBody" => prompt["contentRef"],
      "outboundBody" => prompt["contentRef"],
      "bodyDigest" => Canonical.hash_bytes(body),
      "firstInput" => %{
        "fieldPath" => "/messages/0/content",
        "digest" => Canonical.hash_bytes("hello")
      },
      "method" => "POST",
      "path" => "/v1/messages",
      "upstream" => "https://provider.test",
      "transport" => "https",
      "semanticHeaders" => [],
      "operationId" => "op"
    }

    records = %{
      prompt_ref => %{ref: prompt_ref, kind: @prompt, actor: actor, spec: prompt},
      event("d") => %{ref: event("d"), kind: @call, actor: actor, spec: call}
    }

    targets =
      Map.new([@prompt, @call, @managed], fn kind ->
        [g, v, k] = String.split(kind, "/")
        {kind, %{"group" => g, "version" => v, "kind" => k, "name" => nil}}
      end)

    context = %{
      role: :producer,
      actor: actor,
      authority: authority,
      targets: targets,
      span: span,
      model: "model-1",
      upstream_host: "provider.test",
      call_routing: %{},
      body: body,
      session_binding: event("c"),
      llm_call: event("d"),
      managed: managed,
      read_record: fn reference -> Map.fetch(records, reference) end,
      read_bytes: fn reference ->
        if reference == prompt["contentRef"]["$ref"], do: {:ok, body}, else: :error
      end
    }

    %{context: context, prompt: prompt, call: call, managed: managed, records: records}
  end

  test "supported candidates bind exact body and return caller bytes plus core canonical digest",
       c do
    for {kind, spec} <- [{@prompt, c.prompt}, {@call, c.call}, {@managed, c.managed}] do
      bytes = " \n" <> Jason.encode!(spec) <> "\n"
      assert {:ok, result} = Request.prepare(wire(kind, spec, c, bytes), c.context)
      assert result.spec_bytes == bytes
      assert result.canonical_spec_bytes == Canonical.encode(spec)
      assert result.spec_address == Canonical.hash(spec)
      assert result.spec == spec
      assert result.authority == c.context.authority
    end
  end

  test "all caller signing fields and unknown wire fields refuse", c do
    for key <- ~w(specAddress nonce expires actor origin target generation extra) do
      assert {:error, _} =
               Request.prepare(Map.put(wire(@prompt, c.prompt, c), key, "supplied"), c.context)
    end

    for key <- ~w(kind specBytes authority) do
      assert {:error, _} = Request.prepare(Map.delete(wire(@prompt, c.prompt, c), key), c.context)
    end
  end

  test "closed specs and nested objects reject extras and wrong scalar types", c do
    for spec <- [
          Map.put(c.call, "requestBody", c.prompt["contentRef"]),
          Map.put(c.call, "specAddress", "forged"),
          Map.put(c.call, "sourceIds", %{"unknown" => "x"}),
          Map.put(c.call, "parameters", %{"temperature" => []}),
          Map.put(c.call, "tools", [1]),
          Map.put(c.call, "transport", "smtp"),
          Map.put(c.call, "provider", 1),
          put_in(c.call, ["prompt", "extra"], true)
        ] do
      assert {:error, _} = Request.prepare(wire(@call, spec, c), c.context)
    end

    for spec <- [
          Map.put(c.prompt, "role", "root"),
          Map.put(c.prompt, "extra", true),
          Map.delete(c.prompt, "contentRef")
        ] do
      assert {:error, _} = Request.prepare(wire(@prompt, spec, c), c.context)
    end

    assert {:error, _} =
             Request.prepare(
               wire(@managed, put_in(c.managed, ["firstInput", "extra"], true), c),
               c.context
             )
  end

  test "duplicate keys, noncanonical numbers, nonobjects and oversized input refuse", c do
    for bytes <- [
          ~s({"contentRef":{},"contentRef":{}}),
          ~s({"x":{"a":1,"\u0061":2}}),
          ~s({"x":1.0}),
          ~s({"x":-0}),
          "[]",
          "null",
          "{",
          <<255>>,
          String.duplicate(" ", 1_048_577)
        ] do
      assert {:error, _} = Request.prepare(wire(@prompt, c.prompt, c, bytes), c.context)
    end
  end

  test "exact authority set rejects empty, extra, missing, duplicate or malformed refs", c do
    for authority <- [
          [],
          [event("a")],
          [event("a"), event("b"), event("c")],
          [event("a"), event("a"), event("b")],
          ["bad"],
          nil,
          [event("a") | :bad]
        ] do
      assert {:error, _} =
               Request.prepare(
                 %{wire(@prompt, c.prompt, c) | "authority" => authority},
                 c.context
               )
    end

    assert {:ok, _} =
             Request.prepare(
               %{wire(@prompt, c.prompt, c) | "authority" => Enum.reverse(c.context.authority)},
               c.context
             )
  end

  test "role and supported Kind intersect; runtime alone selects target name", c do
    assert {:error, _} =
             Request.prepare(wire(@prompt, c.prompt, c), %{c.context | role: :runtime_action})

    for kind <- [
          "recurse.r5e.io/v1alpha1/Review",
          "core.r5e.io/v1/CasObject",
          "Prompt",
          "unknown"
        ] do
      assert {:error, _} =
               Request.prepare(wire(kind, c.prompt, c), %{c.context | role: :reviewer})
    end

    context = put_in(c.context, [:targets, @prompt, "name"], "registered-name")

    assert {:ok, %{target: %{"name" => "registered-name"}}} =
             Request.prepare(wire(@prompt, c.prompt, c), context)

    assert {:error, _} =
             Request.prepare(
               wire(@prompt, c.prompt, c),
               put_in(context.targets[@prompt]["group"], "wrong")
             )
  end

  test "span, model, upstream and body mismatch refuse", c do
    for {kind, spec} <- [
          {@prompt,
           Map.put(c.prompt, "session", ref("gateway.r5e.io/v1alpha1/AgentSession/other"))},
          {@prompt,
           Map.put(c.prompt, "contentRef", ref("bytes:" <> Canonical.hash_bytes("changed")))},
          {@call, Map.put(c.call, "model", "other")},
          {@call, Map.put(c.call, "upstreamHost", "evil.test")},
          {@call, Map.delete(c.call, "upstreamHost")},
          {@call, Map.delete(c.call, "session")},
          {@call, Map.put(c.call, "prompt", ref(@prompt <> "/missing"))}
        ] do
      assert {:error, _} = Request.prepare(wire(kind, spec, c), c.context)
    end

    assert {:error, _} =
             Request.prepare(wire(@prompt, c.prompt, c), %{
               c.context
               | read_bytes: fn _ -> {:ok, c.context.body <> " "} end
             })
  end

  test "linked records must have exact ref, Kind, actor, closed shape and bound body", c do
    record = c.records[c.call["prompt"]["$ref"]]

    for bad <- [
          %{record | ref: "wrong"},
          %{record | kind: @call},
          %{record | actor: "other"},
          %{record | spec: Map.put(c.prompt, "extra", true)},
          %{
            record
            | spec:
                Map.put(c.prompt, "contentRef", ref("bytes:" <> Canonical.hash_bytes("other")))
          }
        ] do
      context = %{c.context | read_record: fn _ -> {:ok, bad} end}
      assert {:error, _} = Request.prepare(wire(@call, c.call, c), context)
    end

    assert {:error, _} =
             Request.prepare(wire(@call, c.call, c), %{
               c.context
               | read_record: fn _ -> raise "private diagnostic" end
             })

    assert {:error, :invalid_signer_request} =
             Request.prepare(wire(@call, c.call, c), %{
               c.context
               | read_record: fn _ -> exit(:unavailable) end
             })
  end

  test "ManagedRequest binds all registered fields and follows LlmCall then Prompt", c do
    for field <-
          ~w(sessionBinding llmCall inboundBody outboundBody bodyDigest firstInput method path upstream transport semanticHeaders operationId) do
      changed = Map.put(c.managed, field, "changed")
      assert {:error, _} = Request.prepare(wire(@managed, changed, c), c.context)
    end

    # Even a mismatched expected spec cannot bypass the independent body/ref binding.
    changed = Map.put(c.managed, "outboundBody", ref("bytes:" <> Canonical.hash_bytes("changed")))

    assert {:error, _} =
             Request.prepare(wire(@managed, changed, c), %{c.context | managed: changed})

    call_record = %{c.records[event("d")] | spec: Map.put(c.call, "model", "wrong")}
    records = Map.put(c.records, event("d"), call_record)

    assert {:error, _} =
             Request.prepare(wire(@managed, c.managed, c), %{
               c.context
               | read_record: &Map.fetch(records, &1)
             })
  end

  test "all optional call routing values and their presence are runtime bound", c do
    routing = %{
      "provider" => "provider",
      "transport" => "https",
      "requestPath" => "/v1/messages",
      "apiFormat" => "provider-json"
    }

    call = Map.merge(c.call, routing)
    context = %{c.context | call_routing: routing}
    assert {:ok, _} = Request.prepare(wire(@call, call, c), context)

    for {key, _} <- routing do
      assert {:error, _} =
               Request.prepare(wire(@call, Map.put(call, key, "different"), c), context)

      assert {:error, _} = Request.prepare(wire(@call, Map.delete(call, key), c), context)

      assert {:error, _} =
               Request.prepare(wire(@call, Map.put(c.call, key, routing[key]), c), c.context)
    end

    assert {:ok, _} = Request.prepare(wire(@call, c.call, c), c.context)

    for invalid <- [%{"unknown" => "value"}, %{"transport" => "smtp"}, %{"provider" => 123}] do
      assert {:error, _} =
               Request.prepare(wire(@call, c.call, c), %{c.context | call_routing: invalid})
    end
  end

  test "duplicate otherwise-valid Prompt fields cannot be hidden by decoding", c do
    bytes = Canonical.encode(c.prompt)

    duplicate =
      binary_part(bytes, 0, byte_size(bytes) - 1) <>
        ",\"session\":" <> Canonical.encode(c.prompt["session"]) <> "}"

    assert {:error, _} = Request.prepare(wire(@prompt, c.prompt, c, duplicate), c.context)
  end

  defp wire(kind, spec, c, bytes \\ nil),
    do: %{
      "kind" => kind,
      "specBytes" => bytes || Canonical.encode(spec),
      "authority" => c.context.authority
    }

  defp event(char), do: "event:sha256:" <> String.duplicate(char, 64)
  defp ref(value), do: %{"$ref" => value}
end
