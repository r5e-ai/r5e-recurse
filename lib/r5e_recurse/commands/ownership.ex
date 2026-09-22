defmodule R5eRecurse.Commands.Ownership do
  @moduledoc "OS-held single-host ownership, keyed by canonical chain origin."
  def acquire(origin) do
    if Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, origin) do
      directory = "/var/tmp/r5e-recurse-writer-" <> String.replace_prefix(origin, "sha256:", "")
      helper = Application.app_dir(:r5e_recurse, "priv/commands/ownership.py")

      case System.find_executable("python3") do
        nil ->
          {:error, :python3_required}

        executable ->
          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              :use_stdio,
              args: [helper, directory]
            ])

          receive do
            {^port, {:data, "acquired\n"}} ->
              {:ok, port, directory}

            {^port, _} ->
              close(port)
              {:error, :writer_ownership_unavailable}
          after
            5_000 ->
              close(port)
              {:error, :writer_ownership_timeout}
          end
      end
    else
      {:error, :invalid_origin}
    end
  end

  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
