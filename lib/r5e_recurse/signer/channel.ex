defmodule R5eRecurse.Signer.Channel do
  @moduledoc """
  Cooperative local signer transport: private Unix socket, gateway secret, and live routes.
  The trusted runtime registers bindings; the gateway authenticates each after rotation.
  Provisioning is owned by the calling trusted gateway bridge process. Its death
  invalidates the secret and route authentication; a replacement must provision
  and reauthenticate. A remote gateway needs a bridge owner that dies on disconnect.
  `handler.(binding, request)` is the separately implemented validating signer boundary.
  This transport does not establish Badge/delegation or request policy validity.
  Wire format is packet-4 JSON, capped at 8 MiB including authentication fields
  and JSON escaping; Request separately caps decoded specBytes at 1 MiB.
  A 4-second monotonic attempt deadline starts at full-packet arrival before queuing. Secret provisioning is in-process only, never a CLI API.
  """
  use GenServer
  alias R5eRecurse.SessionKeys
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def provision(server), do: GenServer.call(server, :provision)
  def rotate(server), do: GenServer.call(server, :rotate)

  def register(server, owner, generation, binding),
    do:
      GenServer.call(
        server,
        {:register, owner, generation, binding, System.monotonic_time(:millisecond) + 4_000}
      )

  def close(server, route), do: GenServer.call(server, {:close, route})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    directory = Keyword.fetch!(opts, :directory)
    # Require a fresh directory: never chmod or unlink a caller's existing socket/path.
    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         path = Path.join(directory, "signer.sock"),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             active: false,
             packet: 4,
             packet_size: 8 * 1_048_576,
             ifaddr: {:local, String.to_charlist(path)}
           ]),
         :ok <- File.chmod(path, 0o600) do
      server = self()
      acceptor = spawn_link(fn -> accept(socket, server) end)

      {:ok,
       %{
         socket: socket,
         acceptor: acceptor,
         path: path,
         directory: directory,
         secret: token(),
         routes: %{},
         gateway: nil,
         keys: Keyword.fetch!(opts, :keys),
         handler: Keyword.fetch!(opts, :handler)
       }}
    else
      error -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:provision, {owner, _}, s) do
    s =
      case s.gateway do
        %{owner: ^owner} ->
          s

        previous ->
          if previous, do: Process.demonitor(previous.monitor, [:flush])
          %{rotate_state(s) | gateway: %{owner: owner, monitor: Process.monitor(owner)}}
      end

    {:reply, %{path: s.path, secret: s.secret}, s}
  end

  def handle_call(:rotate, _, s) do
    s = rotate_state(s)
    {:reply, %{path: s.path, secret: s.secret}, s}
  end

  def handle_call({:register, owner, generation, binding, deadline}, _, s)
      when is_pid(owner) and is_map(binding) do
    with true <- Process.alive?(owner),
         {:ok, true} <- SessionKeys.owned_by_before(s.keys, generation, owner, deadline) do
      route = token()
      credential = token()

      entry = %{
        owner: owner,
        monitor: Process.monitor(owner),
        generation: generation,
        credential: credential,
        binding: binding,
        authenticated: false
      }

      {:reply, {:ok, %{route: route, credential: credential, generation: generation}},
       put_in(s.routes[route], entry)}
    else
      _ -> {:reply, {:error, :stale_binding}, s}
    end
  end

  def handle_call({:close, route}, _, s), do: {:reply, :ok, drop(s, route)}

  def handle_call({:wire, bytes, deadline}, _, s) do
    if System.monotonic_time(:millisecond) < deadline do
      case RecurseVerify.Canonical.decode_json(bytes) do
        {:ok, message} when is_map(message) -> dispatch(message, s, deadline)
        _ -> {:reply, %{"error" => "malformed"}, s}
      end
    else
      {:reply, %{"error" => "deadline"}, s}
    end
  end

  defp rotate_state(s),
    do: %{
      s
      | secret: token(),
        routes: Map.new(s.routes, fn {id, b} -> {id, %{b | authenticated: false}} end)
    }

  defp dispatch(message, s, deadline) do
    required = ["secret", "route", "credential", "generation", "operation", "request"]

    with true <- System.monotonic_time(:millisecond) < deadline,
         true <- Enum.sort(Map.keys(message)) == Enum.sort(required),
         true <- is_map(s.gateway) and Process.alive?(s.gateway.owner),
         true <- equal?(message["secret"], s.secret),
         {:ok, entry} <- Map.fetch(s.routes, message["route"]),
         true <- equal?(message["credential"], entry.credential),
         true <- message["generation"] == entry.generation,
         true <- Process.alive?(entry.owner),
         {:ok, _} <- SessionKeys.public_key_before(s.keys, entry.generation, deadline) do
      case message["operation"] do
        "authenticate" ->
          {:reply, %{"ok" => true}, put_in(s.routes[message["route"]].authenticated, true)}

        "sign" when entry.authenticated ->
          result =
            try do
              s.handler.(
                Map.merge(entry.binding, %{
                  generation: entry.generation,
                  deadline: deadline,
                  attempt_started_at: deadline - 4_000
                }),
                message["request"]
              )
            rescue
              _ -> {:error, :signer_failed}
            catch
              _, _ -> {:error, :signer_failed}
            end

          reply =
            case result do
              {:ok, envelope} -> %{"ok" => envelope}
              _ -> %{"error" => "signer_refused"}
            end

          {:reply, reply, s}

        _ ->
          {:reply, %{"error" => "reauthentication_required"}, s}
      end
    else
      _ -> {:reply, %{"error" => "unauthenticated"}, s}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{gateway: %{monitor: ref}} = s),
    do: {:noreply, %{rotate_state(s) | gateway: nil}}

  def handle_info({:DOWN, ref, :process, _, _}, s),
    do: {:noreply, %{s | routes: Map.reject(s.routes, fn {_, b} -> b.monitor == ref end)}}

  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = s),
    do: {:stop, {:acceptor_exit, reason}, s}

  @impl true
  def terminate(_, s) do
    :gen_tcp.close(s.socket)
    File.rm(s.path)
    File.rmdir(s.directory)
  end

  defp drop(s, route) do
    case Map.pop(s.routes, route) do
      {nil, _} ->
        s

      {entry, routes} ->
        Process.demonitor(entry.monitor, [:flush])
        %{s | routes: routes}
    end
  end

  defp accept(socket, server) do
    case :gen_tcp.accept(socket) do
      {:ok, peer} ->
        # One bounded request per connection; no unbounded peer processes or buffered frames.
        case :gen_tcp.recv(peer, 0, 1000) do
          {:ok, bytes} ->
            deadline = System.monotonic_time(:millisecond) + 4_000
            # A call exit otherwise includes its arguments (and the wire secret) in
            # the linked acceptor crash report. Never propagate those arguments.
            try do
              reply = GenServer.call(server, {:wire, bytes, deadline}, 5_000)
              :gen_tcp.send(peer, Jason.encode!(reply))
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end

          _ ->
            :ok
        end

        :gen_tcp.close(peer)
        accept(socket, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp equal?(a, b) when is_binary(a) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp equal?(_, _), do: false
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  @impl true
  def format_status(status), do: Map.new(status, fn {key, _value} -> {key, :redacted} end)
end
