# Also runnable before the application scaffold lands:
# elixir test/live/endpoint_selection_test.exs
unless Process.whereis(ExUnit.Server) do
  ExUnit.start(exclude: if(System.get_env("R5E_LIVE") == "1", do: [], else: [:live]))
end

defmodule R5eRecurse.Live.EndpointSelectionTest do
  use ExUnit.Case, async: true

  setup_all do
    {validate, _} = Code.eval_file(Path.expand("../../priv/live/endpoint_selection.exs", __DIR__))
    %{validate: validate}
  end

  defp selection do
    routes =
      for {client, host, provider, format, auth} <- [
            {"codex", "chatgpt.com", "openai_chatgpt", "openai_responses",
             "bearer_plus_chatgpt_account_id"},
            {"claude", "api.anthropic.com", "anthropic", "anthropic_messages", "passthrough"}
          ],
          into: %{} do
        {client,
         %{
           "inbound_host" => host,
           "upstream_host" => host,
           "upstream_port" => 443,
           "scheme" => "https",
           "provider" => provider,
           "api_format" => format,
           "auth_mode" => auth,
           "enabled" => true,
           "transport_modes" => ["https-sse"]
         }}
      end

    %{
      "routes" => routes,
      "default_upstream_host" => nil,
      "fallback_unknown_hosts" => false,
      "self_host_result" => "not_configured",
      "unknown_host_result" => "not_configured"
    }
  end

  test "explicit subscription routes pass without a default", %{validate: validate} do
    assert validate.(selection()) == selection()
  end

  test "ChatGPT must not select Anthropic, API billing, or an absent provider", %{
    validate: validate
  } do
    for replacement <- [
          selection()["routes"]["claude"],
          nil,
          %{"upstream_host" => "api.openai.com"}
        ] do
      snapshot = put_in(selection(), ["routes", "codex"], replacement)

      assert_raise RuntimeError, ~r/codex does not select/, fn ->
        validate.(snapshot)
      end
    end
  end

  test "fallback or unconfigured-host selection refuses the credential gate", %{
    validate: validate
  } do
    for {field, value} <- [
          {"default_upstream_host", "api.anthropic.com"},
          {"fallback_unknown_hosts", true},
          {"self_host_result", "unexpected_selection"},
          {"unknown_host_result", "unexpected_selection"}
        ] do
      assert_raise RuntimeError, ~r/fallback must be disabled/, fn ->
        validate.(Map.put(selection(), field, value))
      end
    end
  end

  test "disabled, cleartext, or incompatible transport configuration fails", %{validate: validate} do
    for client <- ["codex", "claude"],
        {field, value} <- [
          {"enabled", false},
          {"scheme", "http"},
          {"upstream_port", 80},
          {"transport_modes", ["wss"]}
        ] do
      assert_raise RuntimeError, fn ->
        selection() |> put_in(["routes", client, field], value) |> validate.()
      end
    end
  end

  @tag :live
  @tag skip: System.get_env("R5E_LIVE") != "1"
  test "running gateway selects both expected upstreams before credentials are supplied" do
    script = Path.expand("../../priv/live/check_endpoints.sh", __DIR__)
    {output, code} = System.cmd("bash", [script], stderr_to_stdout: true)
    assert code == 0, output
    # The RPC validates the live selector before returning this status. This
    # test deliberately never reads the checked-in historical snapshot.
    assert output =~ ~s("format":"r5e-recurse-upstream-selection/v1")
    assert output =~ ~s("upstream_host":"chatgpt.com")
    assert output =~ ~s("upstream_host":"api.anthropic.com")
  end
end
