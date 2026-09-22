defmodule R5eRecurse.CommandsKernelIntegrationTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{Commands, KernelClient, IsolatedKernel, DroppingProxy}
  alias R5eRecurse.Commands.{Envelope, KernelStore}
  @moduletag skip: is_nil(System.get_env("R5E_TEST_KERNEL_IMAGE"))

  test "real HTTP Command grant, dedup, replay, and lost acknowledgement recovery" do
    kernel = IsolatedKernel.start!()
    client = KernelClient.new(kernel.url)
    {:ok, [first | _]} = KernelClient.events_from(client, 1)
    {:ok, payload} = KernelClient.get_cas(client, first["payload"])
    ctx = %{kernel: kernel, client: client, origin: Jason.decode!(payload)["origin"]}
    # Deliberately minimal transport fixture; this does not claim Recurse policy enforcement.
    kind =
      File.read!("test/fixtures/commands/transport-kind.json")
      |> Jason.decode!()
      |> Map.delete("requiresAuthority")

    kt = %{"group" => "core.r5e.io", "version" => "v1", "kind" => "KindDefinition", "name" => nil}
    assert {:ok, _} = KernelClient.submit(client, kt, sign(ctx, kt, kind), kind)
    probe = sign(ctx, Envelope.target(), %{})
    caller = probe["payload"] |> Base.decode64!() |> Jason.decode!() |> Map.fetch!("actor")

    command = %{
      "command_id" => "transport",
      "operation" => "submit_task",
      "origin" => ctx.origin,
      "target" => "test-node",
      "expected_state_ref" => nil,
      "payload" => %{"objective" => "test"}
    }

    {:ok, spec} = Commands.command_spec(command, caller)
    envelope = sign(ctx, Envelope.target(), spec)
    opts = [origin: ctx.origin, store: {KernelStore, client}]
    {:ok, server} = Commands.start_link(opts)
    assert {:accepted, result} = Commands.submit(server, command, envelope)

    assert {:existing, ^result} =
             Commands.submit(server, command, sign(ctx, Envelope.target(), spec))

    assert {:denied, %{"recorded" => true}} = Commands.submit(server, command, envelope)
    GenServer.stop(server)
    {:ok, before} = KernelClient.events_from(client, 1)
    # Retry-after proxy preserves GET history but loses the POST acknowledgement.
    proxy = KernelClient.new(DroppingProxy.start!(kernel.url, :post_retry_after))
    {:ok, server} = Commands.start_link(Keyword.put(opts, :store, {KernelStore, proxy}))
    dropped = %{command | "command_id" => "lost"}
    {:ok, dropped_spec} = Commands.command_spec(dropped, caller)

    assert {:outcome_unknown, _} =
             Commands.submit(server, dropped, sign(ctx, Envelope.target(), dropped_spec))

    assert {:existing, %{outcome: "admitted"}} = Commands.lookup(server, caller, "lost")
    GenServer.stop(server)
    {:ok, restarted} = Commands.start_link(opts)
    assert {:existing, %{outcome: "admitted"}} = Commands.lookup(restarted, caller, "lost")
    GenServer.stop(restarted)
    assert {:ok, [event]} = KernelClient.events_from(client, List.last(before)["seq"] + 1)
    assert event["kind"] == "admission.granted"
  end

  # Uses the actual pinned signer, only in this test's disposable container.
  # No private key leaves the container and no host key is accessed.
  defp sign(ctx, target, spec) do
    encoded = Base.encode64(Jason.encode!(%{target: target, spec: spec, origin: ctx.origin}))

    script =
      "Application.put_env(:r5e, :data_dir, System.fetch_env!(\"R5E_DATA_DIR\")); x = Jason.decode!(Base.decode64!(\"#{encoded}\")); IO.puts(Jason.encode!(R5e.Request.sign(%{target: x[\"target\"], spec: x[\"spec\"]}, [:node], origin: x[\"origin\"])))"

    {output, 0} =
      System.cmd(
        "docker",
        ["exec", ctx.kernel.container, "/app/bin/audit_console", "eval", script],
        stderr_to_stdout: true
      )

    output |> String.trim() |> Jason.decode!()
  end
end
