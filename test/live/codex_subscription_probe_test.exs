# Standalone before R5E-204, or included by Mix after the scaffold merges.
unless Process.whereis(ExUnit.Server) do
  ExUnit.start(exclude: if(System.get_env("R5E_LIVE") == "1", do: [], else: [:live]))
end

defmodule R5eRecurse.Live.CodexSubscriptionProbeTest do
  use ExUnit.Case
  @moduletag :live
  @moduletag skip: System.get_env("R5E_LIVE") != "1"
  @tag timeout: 180_000
  test "isolated Codex subscription produces correlated no-tool evidence" do
    root = Path.expand("../..", __DIR__)
    script = Path.join(root, "priv/live/codex/probe.sh")
    {output, status} = System.cmd("bash", [script], cd: root, stderr_to_stdout: true)
    assert status == 0, output
    directory = System.get_env("R5E_PROBE_EVIDENCE_DIR", Path.join(root, "test/live/evidence"))
    bytes = File.read!(Path.join(directory, "codex-probe.json"))
    evidence = JSON.decode!(bytes)
    assert evidence["outcome"] == "passed"
    assert evidence["subscription_auth_verified"] == true
    assert evidence["auth_mode"] == "chatgpt_subscription"
    assert evidence["cli_version"] == "codex-cli 0.149.1"
    assert evidence["refresh"] in ["unverified", "observed_access_token_rotation"]
    assert evidence["canonical"]["selected_upstream"] == "chatgpt.com"
    assert evidence["canonical"]["request_path"] == "/backend-api/codex/responses"
    assert evidence["canonical"]["upstream_status"] == 200
    assert evidence["canonical"]["advertised_tools"] == 0
    assert evidence["canonical"]["observed_tool_calls"] == 0
    assert evidence["canonical"]["retained_response_matches_marker"] == true
    assert evidence["canonical"]["call_admission_event"] =~ "event:sha256:"
    assert evidence["canonical"]["response_event"] =~ "event:sha256:"
    refute bytes =~ ~r/(?i)bearer\s+\S+|"access_token"|"refresh_token"|"authorization"/
  end
end
