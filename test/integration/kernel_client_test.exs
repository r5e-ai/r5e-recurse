defmodule R5eRecurse.KernelClientTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{KernelClient, IsolatedKernel, DroppingProxy}

  setup_all do
    kernel = IsolatedKernel.start!()
    client = KernelClient.new(kernel.url)
    {:ok, [first | _]} = KernelClient.events_from(client, 1)
    {:ok, payload} = KernelClient.get_cas(client, first["payload"])
    %{kernel: kernel, client: client, origin: Jason.decode!(payload)["origin"]}
  end

  test "CAS grant, attributable replay denial, digest mismatch and refusal", ctx do
    bytes = "client integration bytes"

    spec = %{
      "address" => "bytes:" <> digest(bytes),
      "size" => byte_size(bytes),
      "class" => "raw",
      "mediaType" => "application/octet-stream"
    }

    target = target("CasObject")
    envelope = sign(ctx, target, spec)
    assert {:ok, receipt} = KernelClient.put_cas(ctx.client, envelope, bytes)
    assert {:ok, ^bytes} = KernelClient.get_cas(ctx.client, receipt["address"])
    assert {:denied, denial} = KernelClient.put_cas(ctx.client, envelope, bytes)
    assert denial["recorded"] and denial["identity"] == "signed"

    assert {:error, :admission_mismatch} =
             KernelClient.resource_at_admission(ctx.client, denial["eventRef"], target)

    assert {:error, :not_found} =
             KernelClient.resource_at_admission(
               ctx.client,
               "event:sha256:" <> String.duplicate("0", 64),
               target
             )

    assert {:refused, %{"recorded" => false}} = KernelClient.submit(ctx.client, target, %{}, spec)
    corrupt = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :corrupt))
    assert {:error, :digest_mismatch} = KernelClient.get_cas(corrupt, receipt["address"])
  end

  test "historical exact admission, sequence filter and server-side export", ctx do
    target = target("KindDefinition")
    spec = kind("Historical")
    assert {:ok, receipt} = KernelClient.submit(ctx.client, target, sign(ctx, target, spec), spec)
    recorded_target = %{target | "name" => "client.test/v1/Historical"}

    assert {:ok, %{spec: ^spec, event: event}} =
             KernelClient.resource_at_admission(ctx.client, receipt["eventRef"], recorded_target)

    assert event["seq"] == receipt["seq"]
    assert {:ok, events} = KernelClient.events_from(ctx.client, receipt["seq"])
    assert Enum.all?(events, &(&1["seq"] >= receipt["seq"]))

    assert {:error, :admission_mismatch} =
             KernelClient.resource_at_admission(ctx.client, receipt["eventRef"], target)

    assert {:ok, %{server_path: "/tmp/client-export", manifest: manifest}} =
             KernelClient.export(ctx.client, "/tmp/client-export")

    assert is_map(manifest)
  end

  test "lost reply after actual admission is unknown with exactly one write", ctx do
    target = target("KindDefinition")
    spec = kind("Dropped")
    envelope = sign(ctx, target, spec)
    {:ok, before} = KernelClient.events_from(ctx.client, 1)
    proxy = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :drop))
    assert {:outcome_unknown, _} = KernelClient.submit(proxy, target, envelope, spec)
    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    assert event["kind"] == "admission.granted"
  end

  test "503 Retry-After following admission never resubmits", ctx do
    target = target("KindDefinition")
    spec = kind("RetryAfter")
    envelope = sign(ctx, target, spec)
    {:ok, before} = KernelClient.events_from(ctx.client, 1)
    proxy = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :retry_after))

    assert {:outcome_unknown, {:http_status, 503}} =
             KernelClient.submit(proxy, target, envelope, spec)

    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
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

  defp kind(name),
    do: %{
      "group" => "client.test",
      "version" => "v1",
      "kind" => name,
      "substrate" => "resource",
      "naming" => %{"mode" => "caller"},
      "schema" => %{"required" => [], "properties" => %{}, "additionalProperties" => false},
      "predicates" => [],
      "description" => "Test resource",
      "epistemicScope" => %{
        "claims" => ["Test claim only"],
        "doesNotClaim" => ["Production correctness"]
      }
    }

  defp target(kind),
    do: %{"group" => "core.r5e.io", "version" => "v1", "kind" => kind, "name" => nil}

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
