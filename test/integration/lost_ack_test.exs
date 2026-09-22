defmodule R5eRecurse.LostAckTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.{KernelClient, IsolatedKernel, DroppingProxy, NonceJournal}
  @moduletag skip: is_nil(System.get_env("R5E_TEST_KERNEL_IMAGE"))

  setup do
    kernel = IsolatedKernel.start!()
    client = KernelClient.new(kernel.url)
    {:ok, [first | _]} = KernelClient.events_from(client, 1)
    {:ok, bytes} = KernelClient.get_cas(client, first["payload"])

    directory =
      Path.join(System.tmp_dir!(), "nonce-journal-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      kernel: kernel,
      client: client,
      origin: Jason.decode!(bytes)["origin"],
      directory: directory,
      generation: %{"bootId" => "boot-a", "runId" => "run-a"}
    }
  end

  test "lost acknowledgement recovers by nonce and never signs or submits twice, including restart",
       ctx do
    proxy = KernelClient.new(DroppingProxy.start!(ctx.kernel.url, :post_retry_after))
    opts = options(ctx, proxy)
    {:ok, journal} = NonceJournal.start_link(opts)
    candidate = candidate("Lost")
    signer = fn -> {:ok, sign(ctx, candidate)} end
    {:ok, before} = KernelClient.events_from(ctx.client, 1)

    assert {:outcome_unknown, _} =
             NonceJournal.submit_once(journal, "op", ctx.generation, candidate, signer)

    never = fn -> flunk("a recovered operation must not mint another nonce") end

    assert {:ok, receipt, _} =
             NonceJournal.submit_once(journal, "op", ctx.generation, candidate, never)

    assert {:ok, [event]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    assert receipt["eventRef"] == "event:" <> event["hash"]
    GenServer.stop(journal)

    {:ok, recovered} =
      NonceJournal.start_link(Keyword.put(options(ctx, ctx.client), :boot_id, "boot-b"))

    assert {:ok, ^receipt, _} = NonceJournal.lookup(recovered, "op")

    assert {:error, :stale_generation_or_operation} =
             NonceJournal.submit_once(recovered, "fresh", ctx.generation, candidate, never)

    assert {:conflict, %{reason: :candidate_changed}} =
             NonceJournal.submit_once(
               recovered,
               "op",
               ctx.generation,
               candidate("Different"),
               never
             )

    assert {:ok, [_]} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    GenServer.stop(recovered)
  end

  test "a recorded structural denial is recovered without replaying the nonce", ctx do
    {:ok, journal} = NonceJournal.start_link(options(ctx, ctx.client))
    candidate = %{candidate("Invalid") | spec: %{}}

    assert {:denied, receipt, _} =
             NonceJournal.submit_once(journal, "deny", ctx.generation, candidate, fn ->
               {:ok, sign(ctx, candidate)}
             end)

    assert {:denied, recovered, _} = NonceJournal.lookup(journal, "deny")
    assert recovered["eventRef"] == receipt["eventRef"]
    GenServer.stop(journal)
  end

  test "persisted unobserved admission stays uncertain after restart, with zero resubmissions",
       ctx do
    # Connection failure leaves the exact attempted envelope durable. Absence from
    # the later canonical scan is still not permission to try that operation again.
    dead = KernelClient.new("http://127.0.0.1:1", timeout: 100)
    {:ok, journal} = NonceJournal.start_link(options(ctx, dead))
    candidate = candidate("Unobserved")
    {:ok, before} = KernelClient.events_from(ctx.client, 1)

    assert {:transport_failure, _} =
             NonceJournal.submit_once(journal, "pending", ctx.generation, candidate, fn ->
               {:ok, sign(ctx, candidate)}
             end)

    assert [path] = Path.wildcard(Path.join(ctx.directory, "*.json"))
    {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert {:ok, entry} = path |> File.read!() |> RecurseVerify.Canonical.decode_json()
    assert entry["request"]["nonce"] != nil
    refute File.read!(path) =~ "private"
    GenServer.stop(journal)
    {:ok, journal} = NonceJournal.start_link(options(ctx, ctx.client))

    assert {:outcome_unknown, %{reason: :not_observed}} =
             NonceJournal.submit_once(journal, "pending", ctx.generation, candidate, fn ->
               flunk("must not sign")
             end)

    assert {:ok, []} = KernelClient.events_from(ctx.client, List.last(before)["seq"] + 1)
    GenServer.stop(journal)
  end

  test "initial replay response and later lookup both return the original consuming receipt",
       ctx do
    candidate = candidate("ExternalNonce")
    envelope = sign(ctx, candidate)

    assert {:ok, original} =
             KernelClient.submit(ctx.client, candidate.target, envelope, candidate.spec)

    {:ok, journal} = NonceJournal.start_link(options(ctx, ctx.client))

    assert {:ok, first, ^envelope} =
             NonceJournal.submit_once(journal, "external", ctx.generation, candidate, fn ->
               {:ok, envelope}
             end)

    assert first["eventRef"] == original["eventRef"]
    assert {:ok, ^first, ^envelope} = NonceJournal.lookup(journal, "external")
    GenServer.stop(journal)
  end

  test "largest supported integer crosses actual helper and kernel transport", ctx do
    large = Integer.pow(10, 1023)

    candidate =
      put_in(candidate("LargeInteger"), [:spec, "schema", "properties", "amount"], %{
        "type" => "integer",
        "enum" => [large, -Integer.pow(10, 1022)]
      })

    {:ok, journal} = NonceJournal.start_link(options(ctx, ctx.client))
    envelope = sign(ctx, candidate)

    assert {outcome, receipt, ^envelope} =
             NonceJournal.submit_once(journal, "large", ctx.generation, candidate, fn ->
               {:ok, envelope}
             end)

    assert outcome in [:ok, :denied]
    assert receipt["recorded"] == true
    GenServer.stop(journal)
    {:ok, journal} = NonceJournal.start_link(options(ctx, ctx.client))
    assert {^outcome, ^receipt, ^envelope} = NonceJournal.lookup(journal, "large")
    GenServer.stop(journal)
  end

  defp options(ctx, client),
    do: [directory: ctx.directory, origin: ctx.origin, boot_id: "boot-a", client: client]

  defp candidate(kind),
    do: %{
      target: %{
        "group" => "core.r5e.io",
        "version" => "v1",
        "kind" => "KindDefinition",
        "name" => nil
      },
      spec: %{
        "group" => "journal.test",
        "version" => "v1",
        "kind" => kind,
        "substrate" => "event",
        "naming" => %{"mode" => "content"},
        "schema" => %{"properties" => %{}, "required" => [], "additionalProperties" => false},
        "predicates" => []
      }
    }

  defp sign(ctx, candidate) do
    encoded = Base.encode64(Jason.encode!(Map.put(candidate, :origin, ctx.origin)))

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
