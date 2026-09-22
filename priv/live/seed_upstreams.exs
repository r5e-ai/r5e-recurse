# Run only in the designated, newly provisioned A1 test gateway.
alias Recurse.Gateway.LlmProxy.ProxyRouter
alias Recurse.Providers.{LlmProviders, Repo}
alias Recurse.Providers.Schemas.LlmProviderConfig

unless System.get_env("R5E_LIVE_TEST_ONLY") == "true" and
         System.get_env("R5E_TENANT_ID") == "01TEN_RECURSE_A1" and
         ProxyRouter.default_upstream_host() == nil and
         ProxyRouter.fallback_unknown_hosts?() == false do
  raise "refusing to seed outside the explicitly designated A1 test deployment"
end

attrs = %{
  tenant_id: "01TEN_RECURSE_A1",
  provider: "openai_chatgpt",
  upstream_host: "chatgpt.com",
  upstream_port: 443,
  transport_modes: ["https-sse"],
  auth_mode: :bearer_plus_chatgpt_account_id,
  api_format: :openai_responses,
  enabled: true,
  metadata: %{"scheme" => "https"}
}

case LlmProviders.lookup(attrs.tenant_id, attrs.upstream_host) do
  {:error, :not_configured} ->
    %LlmProviderConfig{} |> LlmProviderConfig.changeset(attrs) |> Repo.insert!()
    IO.puts("A1 ChatGPT upstream created; run check_endpoints.sh before supplying credentials")

  {:ok, _} ->
    IO.puts("A1 ChatGPT upstream already exists; unchanged; run check_endpoints.sh")

  _ ->
    raise "existing ChatGPT upstream is disabled; no changes made"
end

# The collapsed test broker serves its JWKS locally. The cache warms on demand;
# make the readiness state explicit without minting a browser login cookie.
idp = Application.fetch_env!(:recurse_gateway, :browser_oidc_idp)

case Recurse.Gateway.Identity.JwksCache.refresh(Keyword.fetch!(idp, :issuer_url)) do
  :ok -> IO.puts("A1 local test JWKS cache refreshed")
  {:ok, _} -> IO.puts("A1 local test JWKS cache refreshed")
  _ -> raise "A1 local test JWKS refresh failed"
end
