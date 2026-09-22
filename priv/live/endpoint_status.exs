# Executed inside the running gateway release by check_endpoints.sh.
alias Recurse.Gateway.LlmProxy.ProxyRouter

tenant = Application.fetch_env!(:recurse_gateway, :llm_proxy_default_tenant_id)

routes =
  for {client, host, path} <- [
        {"codex", "chatgpt.com", "/backend-api/codex/responses"},
        {"claude", "api.anthropic.com", "/v1/messages"}
      ],
      into: %{} do
    route =
      case ProxyRouter.select_upstream(tenant, host) do
        {:ok, row} ->
          %{
            "inbound_host" => host,
            "path" => path,
            "upstream_host" => row.upstream_host,
            "upstream_port" => row.upstream_port,
            "scheme" => Map.get(row.metadata, "scheme", "https"),
            "provider" => row.provider,
            "api_format" => Atom.to_string(row.api_format),
            "auth_mode" => Atom.to_string(row.auth_mode),
            "enabled" => row.enabled,
            "transport_modes" => row.transport_modes
          }

        {:error, reason} ->
          %{"inbound_host" => host, "path" => path, "error" => Atom.to_string(reason)}
      end

    {client, route}
  end

miss = fn host ->
  case ProxyRouter.select_upstream(tenant, host) do
    {:error, :not_configured} -> "not_configured"
    _ -> "unexpected_selection"
  end
end

snapshot = %{
  "format" => "r5e-recurse-upstream-selection/v1",
  "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
  "selection_basis" => "running gateway ProxyRouter.select_upstream/2; Host-based routing",
  "default_upstream_host" => ProxyRouter.default_upstream_host(),
  "fallback_unknown_hosts" => ProxyRouter.fallback_unknown_hosts?(),
  "self_host_result" => miss.("localhost"),
  "unknown_host_result" => miss.("unconfigured.invalid"),
  "routes" => routes
}

validate_selection.(snapshot)
IO.puts("R5E_UPSTREAM_STATUS=" <> Jason.encode!(snapshot))
