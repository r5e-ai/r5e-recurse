defmodule R5eRecurse.BoundedTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Bounded

  test "successful callback retires its ordinary linked dependency" do
    parent = self()

    assert {:ok, :done} =
             Bounded.run(
               fn ->
                 dependency =
                   spawn_link(fn ->
                     receive do
                       :never -> :ok
                     end
                   end)

                 send(parent, {:dependency, dependency})
                 :done
               end,
               System.monotonic_time(:millisecond) + 1000
             )

    assert_receive {:dependency, dependency}
    monitor = Process.monitor(dependency)
    assert_receive {:DOWN, ^monitor, :process, ^dependency, _}
  end

  test "parent death kills blocked callback and linked dependency" do
    parent = self()

    caller =
      spawn(fn ->
        Bounded.run(
          fn ->
            dependency =
              spawn_link(fn ->
                receive do
                  :never -> :ok
                end
              end)

            send(parent, {:workers, self(), dependency})

            receive do
              :never -> :ok
            end
          end,
          System.monotonic_time(:millisecond) + 4000
        )
      end)

    assert_receive {:workers, worker, dependency}
    refs = for pid <- [worker, dependency], do: {pid, Process.monitor(pid)}
    Process.exit(caller, :kill)
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
  end

  test "externally killed callback refuses without killing caller" do
    parent = self()

    caller =
      Task.async(fn ->
        Bounded.run(
          fn ->
            send(parent, {:worker, self()})

            receive do
              :never -> :ok
            end
          end,
          System.monotonic_time(:millisecond) + 1000
        )
      end)

    assert_receive {:worker, worker}
    Process.exit(worker, :kill)
    assert :error = Task.await(caller)
  end

  test "timeout deactivates reply alias and kills callback" do
    parent = self()

    caller =
      Task.async(fn ->
        result =
          Bounded.run(
            fn ->
              send(parent, {:worker, self()})

              receive do
                :release -> :late
              end
            end,
            System.monotonic_time(:millisecond) + 30
          )

        send(parent, {:result, result})

        receive do
          :inspect -> Process.info(self(), :messages)
        end
      end)

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert_receive {:result, :error}
    send(worker, :release)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    send(caller.pid, :inspect)
    assert {:messages, []} = Task.await(caller)
  end
end
