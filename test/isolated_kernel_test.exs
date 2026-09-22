defmodule R5eRecurse.IsolatedKernelTest do
  use ExUnit.Case, async: false
  alias R5eRecurse.IsolatedKernel
  @moduletag skip: is_nil(System.get_env("R5E_TEST_KERNEL_IMAGE"))

  test "separate test boots have separate chains and no persistent host storage" do
    first = IsolatedKernel.start!()
    second = IsolatedKernel.start!()
    assert first.url != second.url
    assert first.container != second.container
    assert first_event(first) != first_event(second)

    for kernel <- [first, second] do
      {json, 0} = System.cmd("docker", ["inspect", kernel.container])
      [container] = Jason.decode!(json)
      assert container["Mounts"] == []
      assert Map.has_key?(container["HostConfig"]["Tmpfs"], "/data")
      assert "R5E_DATA_DIR=/data/r5e-recurse-test" in container["Config"]["Env"]
      IsolatedKernel.stop!(kernel)
    end
  end

  defp first_event(kernel) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :get,
        {String.to_charlist(kernel.url <> "/events"), []},
        [timeout: 5_000],
        []
      )

    body |> to_string() |> Jason.decode!() |> Map.fetch!("events") |> hd() |> Map.fetch!("hash")
  end
end
