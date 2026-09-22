defmodule R5eRecurse.SessionKeysTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.SessionKeys

  test "keys are distinct, verify, and cannot be reconstructed from a recorded generation" do
    {:ok, keys} = SessionKeys.start_link()
    {:ok, a} = SessionKeys.create(keys, "a", self())
    {:ok, b} = SessionKeys.create(keys, "b", self())
    refute a.public_key == b.public_key
    refute inspect(:sys.get_status(keys), limit: :infinity) =~ inspect(a.public_key)
    assert inspect(:sys.get_status(keys)) =~ "redacted"
    {:ok, signature} = SessionKeys.sign(keys, a.generation, "evidence")
    assert :crypto.verify(:eddsa, :none, "evidence", signature, [a.public_key, :ed25519])
    {:ok, restarted} = SessionKeys.start_link()
    assert {:error, :stale_generation} = SessionKeys.sign(restarted, a.generation, "evidence")
    assert :ok = SessionKeys.destroy(keys, a.generation)
    assert {:error, :stale_generation} = SessionKeys.sign(keys, a.generation, "evidence")
  end

  test "dead execution owner cannot sign" do
    {:ok, keys} = SessionKeys.start_link()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, key} = SessionKeys.create(keys, "owner", owner)
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert {:error, _} = SessionKeys.sign(keys, key.generation, "evidence")
  end
end
