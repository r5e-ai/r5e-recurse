# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Callback do
  @moduledoc false
  # Guardian is independent of the execution worker so even an abrupt worker
  # death cannot strand a trapping callback. It reports only after callback DOWN.
  def start(owner, generation, ref, fun, timeout)
      when is_integer(timeout) and timeout in 1..4_294_967_295 do
    spawn_monitor(fn ->
      owner_monitor = Process.monitor(owner)
      guardian = self()

      {callback, callback_monitor} =
        spawn_monitor(fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              _ -> :error
            catch
              _, _ -> :error
            end

          send(guardian, {:result, self(), result})

          receive do
            :release -> :ok
          end
        end)

      result =
        try do
          receive do
            {:result, ^callback, result} -> result
            {:DOWN, ^owner_monitor, :process, ^owner, _} -> :error
            {:DOWN, ^callback_monitor, :process, ^callback, _} -> :error
            {:cancel, ^ref} -> :error
          after
            timeout -> :error
          end
        after
          Process.exit(callback, :kill)
          # A fresh monitor also handles an earlier consumed callback DOWN.
          death = Process.monitor(callback)

          receive do
            {:DOWN, ^death, :process, ^callback, _} -> :ok
          end

          Process.demonitor(callback_monitor, [:flush])
          Process.demonitor(owner_monitor, [:flush])
        end

      send(owner, {:callback, generation, ref, result})
    end)
  end
end
