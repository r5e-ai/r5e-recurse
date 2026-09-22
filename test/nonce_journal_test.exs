defmodule R5eRecurse.NonceJournalTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.{NonceJournal, KernelClient}

  setup do
    # Failed start_link is an expected refusal, not a test-process crash.
    Process.flag(:trap_exit, true)

    directory =
      Path.join(System.tmp_dir!(), "journal-owner-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      opts: [
        directory: directory,
        origin: "sha256:" <> String.duplicate("a", 64),
        boot_id: "boot",
        client: KernelClient.new("http://127.0.0.1:1", timeout: 50)
      ]
    }
  end

  test "OS ownership refuses another writer and releases after shutdown", ctx do
    {:ok, first} = NonceJournal.start_link(ctx.opts)
    assert {:error, :journal_unavailable} = NonceJournal.start_link(ctx.opts)
    GenServer.stop(first)
    {:ok, second} = NonceJournal.start_link(ctx.opts)

    assert {:outcome_unknown, %{reason: :operation_not_journaled}} =
             NonceJournal.lookup(second, "missing")

    GenServer.stop(second)
  end

  test "corrupt restart data refuses startup rather than forgetting an attempted operation",
       ctx do
    {:ok, journal} = NonceJournal.start_link(ctx.opts)
    GenServer.stop(journal)
    File.write!(Path.join(ctx.directory, "broken.json"), "{\"operationId\":\"lost\"")
    assert {:error, :journal_unavailable} = NonceJournal.start_link(ctx.opts)
  end

  test "non-JSON candidate keys are refused before reserving an operation", ctx do
    {:ok, journal} = NonceJournal.start_link(ctx.opts)
    generation = %{"bootId" => "boot", "runId" => "run"}
    target = %{"group" => "test", "version" => "v1", "kind" => "Test", "name" => nil}

    for spec <- [
          %{value: "atom"},
          %{:value => "a", "value" => "b"},
          %{"nested" => [%{value: "atom"}]},
          %{"huge" => Integer.pow(10, 1024)},
          %{"negative" => -Integer.pow(10, 1023)}
        ] do
      assert {:error, :invalid_candidate} =
               NonceJournal.submit_once(
                 journal,
                 "invalid",
                 generation,
                 %{target: target, spec: spec},
                 fn -> flunk("invalid candidate signed") end
               )
    end

    assert Path.wildcard(Path.join(ctx.directory, "*.intent")) == []
    GenServer.stop(journal)
    {:ok, restarted} = NonceJournal.start_link(ctx.opts)
    GenServer.stop(restarted)
  end

  test "prior boot cannot invoke signing even without a matching journal entry", ctx do
    {:ok, journal} = NonceJournal.start_link(ctx.opts)

    assert {:error, :stale_generation_or_operation} =
             NonceJournal.submit_once(
               journal,
               "old",
               %{"bootId" => "previous", "runId" => "run"},
               %{target: %{}, spec: %{}},
               fn -> flunk("old generation signed") end
             )

    GenServer.stop(journal)
  end
end
