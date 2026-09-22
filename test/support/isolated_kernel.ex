defmodule R5eRecurse.IsolatedKernel do
  @moduledoc """
  Starts a throwaway kernel release only from MIX_ENV=test.

  R5E_TEST_KERNEL_IMAGE must name the kernel image under test. Every start has
  its own random container name, loopback port and tmpfs data directory. No
  host directory or existing volume can be supplied. The image's development
  data default is overridden before boot; no genesis checkout is mounted.
  """

  @enforce_keys [:container, :url]
  defstruct [:container, :url]

  def start! do
    unless Mix.env() == :test, do: raise("isolated kernels are test-only")
    image = System.fetch_env!("R5E_TEST_KERNEL_IMAGE")
    name = "r5e-recurse-test-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    args = [
      "run",
      "--detach",
      "--rm",
      "--name",
      name,
      "--label",
      "r5e.recurse.test=" <> name,
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges:true",
      "--tmpfs",
      "/tmp:rw,nosuid,size=64m",
      "--tmpfs",
      "/data:rw,nosuid,noexec,size=256m,mode=0700",
      "--publish",
      "127.0.0.1::4545",
      "--env",
      "R5E_DATA_DIR=/data/r5e-recurse-test",
      "--env",
      "R5E_PORT=4545",
      image
    ]

    case docker(args) do
      {_, 0} -> :ok
      _ -> raise "isolated kernel failed to start; inspect the named test image"
    end

    # Register cleanup before port discovery/readiness so failed setup leaves
    # neither a kernel process nor a key-bearing data volume behind.
    ExUnit.Callbacks.on_exit({__MODULE__, name}, fn -> remove!(name) end)
    {binding, 0} = docker(["port", name, "4545/tcp"])
    [_, port] = Regex.run(~r/\A127\.0\.0\.1:(\d+)\s*\z/, binding)
    host = System.get_env("R5E_TEST_KERNEL_HOST", "127.0.0.1")

    unless host in ["127.0.0.1", "host.docker.internal"],
      do: raise("test kernel host must name the local Docker host")

    kernel = %__MODULE__{container: name, url: "http://" <> host <> ":" <> port}
    {:ok, _} = Application.ensure_all_started(:inets)
    ready!(kernel, System.monotonic_time(:millisecond) + 30_000)
    kernel
  end

  def stop!(%__MODULE__{container: name}), do: remove!(name)

  defp remove!(name) do
    {label, status} =
      docker(["inspect", "--format", "{{index .Config.Labels \"r5e.recurse.test\"}}", name])

    cond do
      status != 0 ->
        :ok

      String.trim(label) != name ->
        raise "refusing to remove a container not owned by this test"

      true ->
        case docker(["rm", "--force", name]) do
          {_, 0} -> :ok
          _ -> raise "isolated kernel cleanup failed"
        end
    end
  end

  defp ready!(kernel, deadline) do
    case :httpc.request(
           :get,
           {String.to_charlist(kernel.url <> "/apis"), []},
           [timeout: 1_000, connect_timeout: 1_000],
           []
         ) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "isolated kernel did not become ready"
        end

        Process.sleep(100)
        ready!(kernel, deadline)
    end
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)
end
