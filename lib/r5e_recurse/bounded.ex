defmodule R5eRecurse.Bounded do
  @moduledoc "Deadline-bound callback isolation with parent-death cleanup and cancellable replies."

  def run(fun, deadline) when is_function(fun, 0) and is_integer(deadline) do
    if remaining(deadline) > 0 do
      parent = self()
      reply = :erlang.alias()
      {watchdog, monitor} = spawn_monitor(fn -> watch(parent, reply, fun, deadline) end)

      result =
        receive do
          {^reply, result} -> result
          {:DOWN, ^monitor, :process, ^watchdog, _} -> :error
        after
          remaining(deadline) -> :error
        end

      :erlang.unalias(reply)
      # The watchdog owns worker cleanup even if the caller times out or dies.
      send(watchdog, {:cancel, reply})
      Process.demonitor(monitor, [:flush])

      receive do
        {^reply, _} -> :ok
      after
        0 -> :ok
      end

      if remaining(deadline) > 0, do: result, else: :error
    else
      :error
    end
  end

  defp watch(parent, reply, fun, deadline) do
    Process.flag(:trap_exit, true)
    parent_monitor = Process.monitor(parent)
    watchdog = self()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              if remaining(deadline) > 0 and Process.alive?(parent),
                do: {:ok, fun.()},
                else: :error
            rescue
              _ -> :error
            catch
              _, _ -> :error
            end

          send(watchdog, {:result, self(), result})
          # Keep the worker alive for abnormal-exit propagation to ordinary
          # linked dependencies. Arbitrary trapping/unlinked descendants are
          # the trusted callback's responsibility, not a containment guarantee.
          receive do
          after
            :infinity -> :ok
          end
        end,
        [:link, :monitor]
      )

    result =
      receive do
        {:result, ^worker, result} -> result
        {:DOWN, ^parent_monitor, :process, ^parent, _} -> :error
        {:DOWN, ^worker_monitor, :process, ^worker, _} -> :error
        {:EXIT, ^worker, _} -> :error
        {:cancel, ^reply} -> :error
      after
        remaining(deadline) -> :error
      end

    Process.exit(worker, :kill)
    Process.demonitor(worker_monitor, [:flush])
    Process.demonitor(parent_monitor, [:flush])
    send(reply, {reply, result})
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
