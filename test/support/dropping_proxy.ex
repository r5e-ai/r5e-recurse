defmodule R5eRecurse.DroppingProxy do
  @moduledoc "Test-only proxy: forwards once to a real kernel, then drops or corrupts the reply."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  def start!(upstream, mode) do
    {:ok, pid} =
      Bandit.start_link(plug: {__MODULE__, {upstream, mode}}, port: 0, ip: {0, 0, 0, 0})

    Process.unlink(pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    "http://127.0.0.1:#{port}"
  end

  def init(opts), do: opts

  def call(conn, {upstream, mode}),
    do: super(Plug.Conn.assign(conn, :proxy, {upstream, mode}), [])

  match _ do
    {upstream, mode} = conn.assigns.proxy
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    headers =
      for {k, v} <- conn.req_headers,
          k not in ["host", "content-length", "connection"],
          do: {String.to_charlist(k), String.to_charlist(v)}

    url = String.to_charlist(upstream <> conn.request_path)
    method = if conn.method == "GET", do: :get, else: :post

    request =
      if method == :get, do: {url, headers}, else: {url, headers, ~c"application/json", body}

    {:ok, {{_, status, _}, _, response}} =
      :httpc.request(method, request, [autoredirect: false, autoretry: 0], body_format: :binary)

    case mode do
      {:fail_history_after_post, state} ->
        if method == :post, do: Agent.update(state, fn _ -> true end)

        if method == :get and conn.request_path == "/events" and Agent.get(state, & &1),
          do: Plug.Conn.send_resp(conn, 503, "history unavailable"),
          else: Plug.Conn.send_resp(conn, status, response)

      :post_retry_after ->
        if method == :post,
          do: Plug.Conn.send_resp(conn, 503, "lost acknowledgement"),
          else: Plug.Conn.send_resp(conn, status, response)

      :drop ->
        # Upstream has replied (and thus committed) before this process exits.
        Process.exit(self(), :kill)

      :retry_after ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(503, "unavailable")

      :bad_status ->
        Plug.Conn.send_resp(conn, 400, "response replaced after admission")

      :alter_event ->
        changed =
          Jason.decode!(response)
          |> Map.update!("events", fn events ->
            List.update_at(events, -1, &Map.put(&1, "ts", "altered"))
          end)

        Plug.Conn.send_resp(conn, status, Jason.encode!(changed))

      :corrupt ->
        Plug.Conn.send_resp(conn, status, response <> "corruption")
    end
  end
end
