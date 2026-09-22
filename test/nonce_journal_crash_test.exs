defmodule R5eRecurse.NonceJournalCrashTest do
  use ExUnit.Case, async: true
  @moduletag timeout: 10_000
  alias R5eRecurse.{Commands.Envelope, KernelClient, NonceJournal}
  alias RecurseVerify.{Canonical, DSSE}

  setup do
    Process.flag(:trap_exit, true)

    directory =
      Path.join(System.tmp_dir!(), "journal-crash-#{System.unique_integer([:positive])}")

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    origin = "sha256:" <> String.duplicate("a", 64)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      listener: listener,
      origin: origin,
      generation: %{"bootId" => "boot", "runId" => "run"},
      candidate: %{"target" => Envelope.target(), "spec" => %{"value" => "original"}},
      opts: [
        directory: directory,
        origin: origin,
        boot_id: "boot",
        client: KernelClient.new("http://127.0.0.1:#{port}", timeout: 100)
      ]
    }
  end

  test "durable intent survives signer process death and prevents signing after restart", ctx do
    journal = start_journal(ctx.opts)
    helper = :sys.get_state(journal).lock
    helper_down = :erlang.monitor(:port, helper)
    journal_down = Process.monitor(journal)
    parent = self()

    call(journal, ctx, fn ->
      send(parent, {:signing, self()})

      receive do
        :crash -> Process.exit(self(), :kill)
      end
    end)

    assert_receive {:signing, ^journal}, 2_000
    intent = path(ctx, ".intent")
    assert %{"status" => "reserved"} = Jason.decode!(File.read!(intent))
    bytes = File.read!(intent)
    send(journal, :crash)
    assert_receive {:DOWN, ^journal_down, :process, ^journal, :killed}, 2_000
    assert_receive {:DOWN, ^helper_down, :port, ^helper, _}, 2_000
    assert_receive {:call_result, {:exit, _}}, 2_000

    restarted = start_journal(Keyword.put(ctx.opts, :boot_id, "next-boot"))

    assert {:outcome_unknown, %{reason: :signing_unconfirmed}} =
             NonceJournal.submit_once(restarted, "op", ctx.generation, ctx.candidate, fn ->
               flunk("reserved operation signed again")
             end)

    assert File.read!(intent) == bytes
    refute File.exists?(path(ctx, ".json"))
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)
  end

  test "helper death while signer is blocked fences prepared publication and HTTP submission",
       ctx do
    journal = start_journal(ctx.opts)
    helper = :sys.get_state(journal).lock
    {:os_pid, os_pid} = Port.info(helper, :os_pid)
    helper_down = :erlang.monitor(:port, helper)
    journal_down = Process.monitor(journal)
    envelope = signed(ctx)
    parent = self()

    call(journal, ctx, fn ->
      send(parent, {:signing, self()})

      receive do
        :release -> {:ok, envelope}
      end
    end)

    assert_receive {:signing, ^journal}, 2_000
    assert File.exists?(path(ctx, ".intent"))

    assert {_, 0} =
             System.cmd("python3", [
               "-c",
               "import os, signal, sys; os.kill(int(sys.argv[1]), signal.SIGKILL)",
               Integer.to_string(os_pid)
             ])

    assert_receive {:DOWN, ^helper_down, :port, ^helper, _}, 2_000
    send(journal, :release)
    assert_receive {:call_result, {:outcome_unknown, %{reason: :preparation_unconfirmed}}}, 2_000
    assert_receive {:DOWN, ^journal_down, :process, ^journal, :writer_lock_lost}, 2_000
    refute File.exists?(path(ctx, ".json"))
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)

    restarted = start_journal(ctx.opts)

    assert {:outcome_unknown, %{reason: :signing_unconfirmed}} =
             NonceJournal.lookup(restarted, "op")
  end

  test "well formed JSON with malformed prepared signature refuses startup", ctx do
    journal = start_journal(ctx.opts)

    assert {:outcome_unknown, _} =
             NonceJournal.submit_once(journal, "op", ctx.generation, ctx.candidate, fn ->
               {:error, :signer_unavailable}
             end)

    GenServer.stop(journal)
    reservation = Jason.decode!(File.read!(path(ctx, ".intent")))
    envelope = signed(ctx)
    {:ok, verified} = Envelope.verify_signed(envelope)
    malformed = put_in(envelope["signatures"], [%{"keyid" => verified.caller, "sig" => "bad"}])

    entry =
      Map.merge(reservation, %{
        "status" => "prepared",
        "envelope" => malformed,
        "request" => verified.request
      })

    File.write!(path(ctx, ".json"), Canonical.encode(entry))
    assert {:error, :journal_unavailable} = NonceJournal.start_link(ctx.opts)
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)
  end

  test "reserved operation rejects changed candidate or generation without altering immutable intent",
       ctx do
    journal = start_journal(ctx.opts)

    assert {:outcome_unknown, _} =
             NonceJournal.submit_once(journal, "op", ctx.generation, ctx.candidate, fn ->
               {:error, :signer_unavailable}
             end)

    bytes = File.read!(path(ctx, ".intent"))
    GenServer.stop(journal)
    restarted = start_journal(ctx.opts)

    for {candidate, generation} <- [
          {put_in(ctx.candidate["spec"]["value"], "changed"), ctx.generation},
          {ctx.candidate, Map.put(ctx.generation, "runId", "different")}
        ] do
      assert {:conflict, %{operation_id: "op", reason: :candidate_changed}} =
               NonceJournal.submit_once(restarted, "op", generation, candidate, fn ->
                 flunk("conflicting operation signed")
               end)
    end

    assert File.read!(path(ctx, ".intent")) == bytes
    refute File.exists?(path(ctx, ".json"))
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)
  end

  test "publication linked before sync failure survives restart without another signature", ctx do
    for suffix <- [".intent", ".json"] do
      directory = ctx.directory <> String.replace(suffix, ".", "-")
      on_exit(fn -> File.rm_rf!(directory) end)
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)

      reservation = %{
        "operationId" => "op",
        "origin" => ctx.origin,
        "generation" => ctx.generation,
        "candidate" => ctx.candidate,
        "candidateDigest" => Canonical.hash(ctx.candidate),
        "status" => "reserved"
      }

      envelope = signed(ctx)
      {:ok, verified} = Envelope.verify_signed(envelope)

      prepared =
        Map.merge(reservation, %{
          "status" => "prepared",
          "envelope" => envelope,
          "request" => verified.request
        })

      entry = if suffix == ".intent", do: reservation, else: prepared
      assert R5eRecurse.NonceJournal.Entry.valid?(entry, ctx.origin)
      helper = Application.app_dir(:r5e_recurse, "priv/nonce_journal/journal_io.py")

      script = """
      import importlib.util, sys
      spec = importlib.util.spec_from_file_location("journal_io", sys.argv[1])
      helper = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(helper)
      directory, name, content, reservation = sys.argv[2:]
      if name.endswith(".json"):
          helper.publish(directory, name[:-5] + ".intent", reservation)
      def fail_after_link(path):
          raise OSError("injected failure after immutable link")
      helper.sync_directory = fail_after_link
      try:
          helper.publish(directory, name, content)
      except OSError:
          print("publication_unconfirmed")
      else:
          sys.exit(1)
      """

      name = Canonical.hash("op") <> suffix
      bytes = Canonical.encode(entry)

      assert {"publication_unconfirmed\n", 0} =
               System.cmd("python3", [
                 "-c",
                 script,
                 helper,
                 directory,
                 name,
                 bytes,
                 Canonical.encode(reservation)
               ])

      assert File.read!(Path.join(directory, name)) == bytes
      assert Path.wildcard(Path.join(directory, ".pending-*")) == []
      journal = start_journal(Keyword.put(ctx.opts, :directory, directory))
      parent = self()

      if suffix == ".json" do
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
          :ok = :inet.setopts(socket, packet: :line)
          {:ok, request_line} = :gen_tcp.recv(socket, 0, 2_000)
          send(parent, {:history_request, request_line})

          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

          :gen_tcp.close(socket)
        end)
      end

      assert {:outcome_unknown, _} =
               NonceJournal.submit_once(journal, "op", ctx.generation, ctx.candidate, fn ->
                 flunk("linked operation signed again")
               end)

      if suffix == ".json" do
        assert_receive {:history_request, "GET /events HTTP/1.1\r\n"}, 2_000
      else
        assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)
      end

      assert File.read!(Path.join(directory, name)) == bytes
      GenServer.stop(journal)
    end
  end

  test "colliding signer envelope keys keep only reservation and permit restart", ctx do
    journal = start_journal(ctx.opts)
    malformed = Map.put(signed(ctx), :payload, "colliding")

    assert {:outcome_unknown, %{reason: :preparation_unconfirmed}} =
             NonceJournal.submit_once(journal, "op", ctx.generation, ctx.candidate, fn ->
               {:ok, malformed}
             end)

    assert File.exists?(path(ctx, ".intent"))
    refute File.exists?(path(ctx, ".json"))
    GenServer.stop(journal)
    restarted = start_journal(ctx.opts)

    assert {:outcome_unknown, %{reason: :signing_unconfirmed}} =
             NonceJournal.lookup(restarted, "op")

    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 0)
  end

  defp start_journal(opts) do
    {:ok, journal} = NonceJournal.start_link(opts)

    on_exit(fn ->
      monitor = Process.monitor(journal)
      Process.exit(journal, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^journal, _} -> :ok
      after
        2_000 -> flunk("journal cleanup did not finish")
      end
    end)

    journal
  end

  defp call(journal, ctx, signer) do
    parent = self()

    spawn(fn ->
      result =
        try do
          NonceJournal.submit_once(journal, "op", ctx.generation, ctx.candidate, signer)
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:call_result, result})
    end)
  end

  defp path(ctx, suffix), do: Path.join(ctx.directory, Canonical.hash("op") <> suffix)

  defp signed(ctx) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    actor = DSSE.key_id!("ed25519", public)

    request = %{
      "origin" => ctx.origin,
      "actor" => actor,
      "target" => ctx.candidate["target"],
      "specAddress" => Canonical.hash(ctx.candidate["spec"]),
      "derivedFrom" => nil,
      "authority" => [],
      "nonce" => Base.encode64(<<0::128>>),
      "expires" => "2099-01-01T00:00:00Z"
    }

    payload = Canonical.encode(request)
    type = "application/vnd.r5e.admission-request+json;v=1"
    signature = :crypto.sign(:eddsa, :none, DSSE.pae(type, payload), [private, :ed25519])

    %{
      "payloadType" => type,
      "payload" => Base.encode64(payload),
      "signatures" => [%{"keyid" => actor, "sig" => Base.encode64(signature)}],
      "publicKeys" => [
        %{"keyid" => actor, "algorithm" => "ed25519", "bytes" => Base.encode64(public)}
      ]
    }
  end
end
