validate_selection = fn snapshot ->
  expected = %{
    "codex" =>
      {"chatgpt.com", "openai_chatgpt", "openai_responses", "bearer_plus_chatgpt_account_id"},
    "claude" => {"api.anthropic.com", "anthropic", "anthropic_messages", "passthrough"}
  }

  # Only this allowlisted projection may leave the gateway. No config metadata,
  # environment dump, request headers, account identifiers or credentials.
  unless snapshot["default_upstream_host"] == nil and
           snapshot["fallback_unknown_hosts"] == false and
           snapshot["self_host_result"] == "not_configured" and
           snapshot["unknown_host_result"] == "not_configured" do
    raise "live endpoint check: fallback must be disabled and unconfigured hosts refused"
  end

  Enum.each(expected, fn {client, {host, provider, format, auth}} ->
    route = get_in(snapshot, ["routes", client]) || %{}

    unless route["inbound_host"] == host and route["upstream_host"] == host and
             route["upstream_port"] == 443 and route["scheme"] == "https" and
             route["provider"] == provider and route["api_format"] == format and
             route["auth_mode"] == auth and route["enabled"] == true and
             "https-sse" in (route["transport_modes"] || []) do
      raise "live endpoint check: #{client} does not select its required upstream"
    end
  end)

  snapshot
end
