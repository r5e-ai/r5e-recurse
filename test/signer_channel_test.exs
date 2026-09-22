defmodule R5eRecurse.SignerChannelTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.{SessionKeys, Signer.Channel}

  setup do
    keys = start_supervised!(SessionKeys)
    {:ok, key} = SessionKeys.create(keys, "session", self())

    directory =
      Path.join(System.tmp_dir!(), "recurse-channel-#{System.unique_integer([:positive])}")

    parent = self()

    channel =
      start_supervised!(
        {Channel,
         keys: keys,
         directory: directory,
         handler: fn binding, request ->
           send(parent, {:handled, binding, request})
           {:ok, "test-envelope"}
         end}
      )

    {:ok, route} = Channel.register(channel, self(), key.generation, %{session: "trusted"})
    provision = Channel.provision(channel)
    %{channel: channel, route: route, provision: provision, keys: keys}
  end

  defp request(c, operation, overrides \\ %{}) do
    message =
      Map.merge(
        %{
          "secret" => c.provision.secret,
          "route" => c.route.route,
          "credential" => c.route.credential,
          "generation" => c.route.generation,
          "operation" => operation,
          "request" => %{}
        },
        overrides
      )

    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(c.provision.path)},
        0,
        [:binary, active: false, packet: 4],
        1000
      )

    :ok = :gen_tcp.send(socket, Jason.encode!(message))
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
    :gen_tcp.close(socket)
    Jason.decode!(bytes)
  end

  test "frame budget accommodates JSON escaping around the 1 MiB decoded spec limit", c do
    assert %{"ok" => true} = request(c, "authenticate")
    # A valid JSON string containing many escaped quotes: the outer packet escapes
    # the backslashes again. This crosses 1 MiB without exceeding the frame cap.
    spec = Jason.encode!(%{"x" => String.duplicate("\"", 262_140)})
    assert byte_size(spec) <= 1_048_576
    wire = %{"kind" => "example", "specBytes" => spec, "authority" => []}
    assert byte_size(Jason.encode!(wire)) > 1_048_576
    assert %{"ok" => "test-envelope"} = request(c, "sign", %{"request" => wire})
    assert_receive {:handled, %{deadline: deadline}, ^wire}
    assert deadline > System.monotonic_time(:millisecond)
  end

  test "frames above 8 MiB are refused before the handler", c do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, String.to_charlist(c.provision.path)},
        0,
        [:binary, active: false, packet: 0],
        1_000
      )

    assert :ok = :gen_tcp.send(socket, <<8 * 1_048_576 + 1::unsigned-big-32>>)
    assert {:error, reason} = :gen_tcp.recv(socket, 0, 2_000)
    assert reason in [:closed, :econnreset]
    :gen_tcp.close(socket)
    refute_receive {:handled, _, _}, 0
  end

  test "secret, live credential and explicit authentication are all required", c do
    status = inspect(:sys.get_status(c.channel), limit: :infinity)
    refute status =~ c.provision.secret
    refute status =~ c.route.credential
    assert status =~ "redacted"
    assert %{"error" => "unauthenticated"} = request(c, "authenticate", %{"secret" => "wrong"})
    assert %{"error" => "reauthentication_required"} = request(c, "sign")
    assert %{"error" => "unauthenticated"} = request(c, "authenticate", %{"session" => "session"})
    assert %{"error" => "unauthenticated"} = request(c, "authenticate", %{"account" => "account"})

    assert %{"error" => "unauthenticated"} =
             request(c, "authenticate", %{"generation" => %{"bootId" => "old", "runId" => "old"}})

    refute_received {:handled, _, _}
    assert %{"ok" => true} = request(c, "authenticate")
    assert %{"ok" => "test-envelope"} = request(c, "sign")
    assert_received {:handled, %{session: "trusted"}, %{}}
    assert {:ok, stat} = File.stat(c.provision.path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "rotation invalidates old secret and requires current binding reauthentication", c do
    assert %{"ok" => true} = request(c, "authenticate")
    new = Channel.rotate(c.channel)
    assert %{"error" => "unauthenticated"} = request(c, "sign")
    c = %{c | provision: new}
    assert %{"error" => "reauthentication_required"} = request(c, "sign")
    assert %{"ok" => true} = request(c, "authenticate")
    assert %{"ok" => _} = request(c, "sign")
  end

  test "gateway bridge death rotates automatically before its replacement reauthenticates", c do
    parent = self()

    bridge =
      spawn(fn ->
        send(parent, {:provisioned, Channel.provision(c.channel)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:provisioned, provision}
    c = %{c | provision: provision}
    assert %{"ok" => true} = request(c, "authenticate")
    monitor = Process.monitor(bridge)
    send(bridge, :stop)
    assert_receive {:DOWN, ^monitor, _, _, _}
    assert %{"error" => "unauthenticated"} = request(c, "sign")
    replacement = Channel.provision(c.channel)
    refute replacement.secret == provision.secret
    assert %{"error" => "unauthenticated"} = request(c, "authenticate")
    c = %{c | provision: replacement}
    assert %{"error" => "reauthentication_required"} = request(c, "sign")
    assert %{"ok" => true} = request(c, "authenticate")
    assert %{"ok" => _} = request(c, "sign")
  end

  test "owner death and terminal key closure revoke live route", c do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:error, :stale_binding} = Channel.register(c.channel, owner, c.route.generation, %{})
    {:ok, key} = SessionKeys.create(c.keys, "other", owner)
    {:ok, route} = Channel.register(c.channel, owner, key.generation, %{})
    c2 = %{c | route: route}
    assert %{"ok" => true} = request(c2, "authenticate")
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert %{"error" => "unauthenticated"} = request(c2, "sign")
    SessionKeys.destroy(c.keys, c.route.generation)
    assert %{"error" => "unauthenticated"} = request(c, "authenticate")
    assert {:error, :stale_binding} = Channel.register(c.channel, self(), c.route.generation, %{})
  end
end
