# Per-invocation closures: concurrent diagnostic calls share no module state.

kind = fn row -> get_in(row.payload, ["target", "kind"]) end
event_ref = fn row -> "event:" <> row.event["hash"] end

target_ref = fn row ->
  target = row.payload["target"]
  Enum.map_join(["group", "version", "kind", "name"], "/", &Map.fetch!(target, &1))
end

read_bytes = fn row ->
  ref = get_in(row.payload, ["spec", "contentRef", "$ref"])
  {:ok, bytes} = R5e.CAS.get(ref)
  actual = "bytes:sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  unless actual == ref, do: raise("retained payload digest mismatch")
  bytes
end

response_text = fn bytes, client ->
  data =
    bytes
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)

  case client do
    "codex" ->
      data
      |> Enum.filter(&(&1["type"] == "response.output_text.delta"))
      |> Enum.map_join(& &1["delta"])

    "claude" ->
      data
      |> Enum.filter(&(get_in(&1, ["delta", "type"]) == "text_delta"))
      |> Enum.map_join(&get_in(&1, ["delta", "text"]))
  end
end

collect_probe = fn client, marker ->
  unless Regex.match?(~r/^R5E_(CODEX|CLAUDE)_PROBE_[a-f0-9]{32}$/, marker),
    do: raise("invalid probe marker")

  {host, provider, path} =
    case client do
      "codex" -> {"chatgpt.com", "openai_chatgpt", "/backend-api/codex/responses"}
      "claude" -> {"api.anthropic.com", "anthropic", "/v1/messages"}
    end

  events =
    for event <- R5e.Log.events(),
        {:ok, payload} <- [R5e.Log.payload(event)],
        do: %{event: event, payload: payload}

  prompts =
    Enum.filter(events, fn row ->
      kind.(row) == "Prompt" and row.payload["outcome"] == "admitted" and
        String.contains?(read_bytes.(row), marker)
    end)

  [prompt] = prompts
  request = prompt |> read_bytes.() |> Jason.decode!()
  unless Map.get(request, "tools", []) == [], do: raise("probe advertised tools")

  [call] =
    Enum.filter(events, fn row ->
      kind.(row) == "LlmCall" and
        get_in(row.payload, ["spec", "prompt", "$ref"]) == target_ref.(prompt)
    end)

  spec = call.payload["spec"]

  unless call.payload["outcome"] == "admitted" and spec["upstreamHost"] == host and
           spec["provider"] == provider and URI.parse(spec["requestPath"]).path == path,
         do: raise("probe call admission or routing mismatch")

  [response] =
    Enum.filter(events, fn row ->
      kind.(row) == "LlmResponse" and
        get_in(row.payload, ["spec", "llmCall", "$ref"]) == event_ref.(call)
    end)

  response_spec = response.payload["spec"]

  unless response.payload["outcome"] == "admitted" and response_spec["upstreamStatus"] == 200 and
           response_spec["outcome"] == "ok" and response_spec["toolCalls"] == [],
         do: raise("probe response was not an admitted successful no-tool response")

  [completion] =
    Enum.filter(events, fn row ->
      kind.(row) == "Completion" and
        target_ref.(row) == get_in(response_spec, ["completion", "$ref"])
    end)

  unless completion.payload["outcome"] == "admitted", do: raise("completion not admitted")
  output = completion |> read_bytes.() |> response_text.(client)
  unless String.trim(output) == marker, do: raise("retained response marker mismatch")
  {:ok, count} = R5e.Log.verify()

  sources = "/app/etc/fold/repos.lock.json" |> File.read!() |> Jason.decode!()

  revisions =
    Map.new(["r5e-core", "r5e-kernel", "r5e-enterprise"], fn name ->
      {name, get_in(sources, ["repositories", name, "commit"])}
    end)

  %{
    "source_revisions" => revisions,
    "request_path" => spec["requestPath"],
    "selected_upstream" => host,
    "provider" => provider,
    "model" => spec["model"],
    "upstream_status" => response_spec["upstreamStatus"],
    "advertised_tools" => 0,
    "observed_tool_calls" => 0,
    "marker_in_retained_request" => true,
    "retained_response_matches_marker" => true,
    "prompt_event" => event_ref.(prompt),
    "call_admission_event" => event_ref.(call),
    "completion_event" => event_ref.(completion),
    "response_event" => event_ref.(response),
    "request_bytes" => get_in(prompt.payload, ["spec", "contentRef", "$ref"]),
    "response_bytes" => get_in(completion.payload, ["spec", "contentRef", "$ref"]),
    "admission_actor" => get_in(call.payload, ["actor", "id"]),
    "attribution" => "gateway fold key; not yet a Recurse session-bound signature",
    "chain_integrity_verified_events" => count
  }
end
