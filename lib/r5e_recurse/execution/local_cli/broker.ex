# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.LocalCLI.Broker do
  @moduledoc false
  use GenServer
  alias R5eRecurse.Execution.{LocalCLI, Spool}
  alias R5eRecurse.Execution.Adapter.{Handle, Observation, Ownership}

  def start(prepared), do: GenServer.start(__MODULE__, prepared)
  def handle(pid), do: GenServer.call(pid, :handle)
  def observe(pid, token, handle), do: GenServer.call(pid, {:observe, token, handle})
  def cancel(pid, token), do: GenServer.call(pid, {:cancel, token}, 12_000)
  def reconcile(pid, token), do: GenServer.call(pid, {:reconcile, token})
  def account(pid, token, bytes), do: GenServer.call(pid, {:account, token, bytes})

  @impl true
  def init(prepared) do
    Process.flag(:trap_exit, true)
    owner = prepared.session.owner
    monitor = Process.monitor(owner)
    broker = self()
    # Spool filesystem operations may block this mailbox. Independent ownership
    # cleanup must still close the Port on Worker death, even in that state.
    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      broker_monitor = Process.monitor(broker)

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _} -> Process.exit(broker, :kill)
        {:DOWN, ^broker_monitor, :process, ^broker, _} -> :ok
      end
    end)

    inv = prepared.invocation
    helper = Application.app_dir(:r5e_recurse, "priv/launcher/r5e_launch")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(helper)},
        [:binary, {:packet, 4}, :exit_status, :use_stdio, {:args, []}]
      )

    true = Port.command(port, config(prepared))

    {:ok,
     %{
       prepared: prepared,
       owner: owner,
       monitor: monitor,
       port: port,
       token: make_ref(),
       handle: nil,
       waiting_handle: nil,
       waiting_cancel: [],
       spool: inv.spool,
       queue: :queue.new(),
       expected: 0,
       outcome: nil,
       port_exit: nil,
       stopping: false
     }}
  end

  @impl true
  def handle_call(:handle, from, %{handle: nil} = s), do: {:noreply, %{s | waiting_handle: from}}
  def handle_call(:handle, _, s), do: {:reply, {:ok, s.handle}, s}

  def handle_call({:observe, token, _handle}, _, %{token: token} = s) do
    {items, queue} = take(s.queue, 32, [])

    case materialize(items, s.spool) do
      {:ok, events} ->
        {:reply, {:ok, events, s.handle}, %{s | queue: queue}}

      :error ->
        s = stop_capture(s, :spool_corrupt)
        {:reply, {:error, :spool_corrupt}, s}
    end
  end

  def handle_call({:cancel, token}, from, %{token: token, outcome: nil} = s) do
    command(s.port, "C")
    {:noreply, %{s | stopping: true, waiting_cancel: [from | s.waiting_cancel]}}
  end

  def handle_call({:cancel, token}, _, %{token: token} = s), do: {:reply, {:ok, ownership(s)}, s}

  def handle_call({:reconcile, token}, _, %{token: token} = s),
    do: {:reply, {:ok, ownership(s)}, s}

  def handle_call({:account, _token, _bytes}, _, %{outcome: outcome} = s) when outcome != nil,
    do: {:reply, {:error, :execution_finished}, s}

  def handle_call({:account, token, bytes}, _, %{token: token} = s)
      when is_integer(bytes) and bytes >= 0 do
    case Spool.account(s.spool, bytes) do
      {:ok, spool} ->
        {:reply, :ok, %{s | spool: spool}}

      {:error, spool} ->
        {:reply, {:error, :trace_budget}, stop_capture(%{s | spool: spool}, :trace_budget)}
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_live_capability}, s}

  @impl true
  def handle_info(
        {port, {:data, <<type, seq::64, payload::binary>>}},
        %{port: port, expected: seq} = s
      ) do
    frame(type, payload, seq, %{s | expected: seq + 1})
  end

  def handle_info({port, {:data, _}}, %{port: port} = s),
    do: {:noreply, stop_capture(s, :invalid_helper_frame)}

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    s = %{s | port_exit: code}

    s =
      if s.outcome == nil,
        do:
          finish(s, %{
            code: nil,
            signal: nil,
            capture_incomplete: true,
            cleanup: :unknown,
            helper_exit: code
          }),
        else: s

    {:noreply, s}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = s) do
    # Closing the only control pipe is a cleanup instruction independently of BEAM.
    close(s.port)
    {:stop, :normal, s}
  end

  def handle_info({:EXIT, port, _}, %{port: port} = s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s), do: close(s.port)

  defp frame(?R, <<1::32, pgid::32>>, 0, %{handle: nil} = s) do
    session = s.prepared.session

    identity = %{
      run: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      generation: session.generation,
      group: pgid
    }

    handle = %Handle{
      adapter: LocalCLI,
      session_id: session.id,
      generation: session.generation,
      owner: s.owner,
      identity: identity,
      state: {self(), s.token}
    }

    # Identity is written before release; this file conveys no recovery kill authority.
    case File.write(Path.join(s.spool.root, "identity.json"), Jason.encode!(identity), [
           :exclusive,
           :sync
         ]) do
      :ok ->
        if Process.alive?(s.owner) and not s.stopping,
          do: command(s.port, "G"),
          else: command(s.port, "C")

        if s.waiting_handle, do: GenServer.reply(s.waiting_handle, {:ok, handle})
        {:noreply, %{s | handle: handle, waiting_handle: nil}}

      _ ->
        {:noreply, stop_capture(s, :identity_spool_failed)}
    end
  end

  defp frame(type, payload, seq, s) when type in [?O, ?E, ?L] and byte_size(payload) <= 65_536 do
    stream = %{?O => :stdout, ?E => :stderr, ?L => :result_file}[type]

    case Spool.append(s.spool, stream, seq, payload) do
      {:ok, spool, entry} ->
        command(s.port, <<?A, seq::64>>)
        {:noreply, %{s | spool: spool, queue: :queue.in({:raw, entry}, s.queue)}}

      {:error, spool} ->
        # ACK releases the helper's one outstanding frame so cancellation can drain.
        command(s.port, <<?A, seq::64>>)
        {:noreply, stop_capture(%{s | spool: spool}, spool.incomplete)}
    end
  end

  defp frame(?F, <<code::signed-32, signal::32, incomplete::32, cleanup::32>>, _seq, s) do
    outcome = %{
      code: if(code < 0, do: nil, else: code),
      signal: signal,
      capture_incomplete: incomplete != 0 or s.spool.incomplete != nil,
      cleanup: if(cleanup == 0, do: :observed_group_gone, else: :unknown)
    }

    {:noreply, finish(s, outcome)}
  end

  defp frame(_, _, _, s), do: {:noreply, stop_capture(s, :invalid_helper_frame)}

  defp stop_capture(s, reason) do
    command(s.port, "C")
    %{s | stopping: true, spool: %{s.spool | incomplete: s.spool.incomplete || reason}}
  end

  defp finish(s, outcome) do
    observed = is_integer(outcome.code) or (is_integer(outcome.signal) and outcome.signal > 0)

    outcome =
      outcome
      |> Map.put(:target_status, if(observed, do: :observed, else: :unobserved))
      |> Map.put(:capture_incomplete, outcome.capture_incomplete or not observed)

    {s, outcome} =
      case Spool.finish(s.spool, outcome) do
        {:ok, spool} -> {%{s | spool: spool}, outcome}
        {:error, spool} -> {%{s | spool: spool}, %{outcome | capture_incomplete: true}}
      end

    sequence = s.expected

    events =
      if outcome.capture_incomplete,
        do: [
          %Observation{
            sequence: sequence,
            source: :process,
            kind: :capture_incomplete,
            value: outcome,
            coverage: []
          }
        ],
        else: []

    events =
      events ++
        if(is_integer(outcome.code) or (is_integer(outcome.signal) and outcome.signal > 0),
          do: [
            %Observation{
              sequence: sequence + 1,
              source: :process,
              kind: :os_exit,
              value: outcome,
              coverage: []
            }
          ],
          else: []
        )

    s = %{s | outcome: outcome, queue: :queue.in({:terminal, events}, s.queue)}
    Enum.each(s.waiting_cancel, &GenServer.reply(&1, {:ok, ownership(s)}))
    if s.waiting_handle, do: GenServer.reply(s.waiting_handle, {:error, :launch_unconfirmed})
    %{s | waiting_cancel: [], waiting_handle: nil}
  end

  defp ownership(s) do
    state =
      cond do
        s.outcome != nil and s.outcome.cleanup == :observed_group_gone -> :stopped
        s.outcome != nil -> :unknown
        s.handle != nil -> :live
        true -> :unknown
      end

    %Ownership{
      state: state,
      identity: if(s.handle, do: s.handle.identity),
      evidence: if(s.outcome, do: [s.outcome], else: []),
      spool: Spool.manifest(s.spool)
    }
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, {:terminal, events} = bundle}, next} ->
        if length(events) <= n,
          do: take(next, n - length(events), [bundle | acc]),
          else: {Enum.reverse(acc), queue}

      {{:value, item}, next} ->
        take(next, n - 1, [item | acc])

      {:empty, _} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp materialize(items, spool) do
    Enum.reduce_while(items, {:ok, []}, fn
      {:terminal, events}, {:ok, acc} ->
        {:cont, {:ok, Enum.reverse(events) ++ acc}}

      {:raw, entry}, {:ok, acc} ->
        case Spool.read(spool, entry) do
          {:ok, bytes} ->
            {:cont,
             {:ok,
              [
                %Observation{
                  sequence: entry.sequence,
                  source: entry.stream,
                  kind: :raw_chunk,
                  value: bytes,
                  coverage: [Map.take(entry, [:sequence, :path, :bytes, :sha256])]
                }
                | acc
              ]}}

          _ ->
            {:halt, :error}
        end

      event, {:ok, acc} ->
        {:cont, {:ok, [event | acc]}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp config(p) do
    i = p.invocation
    env = Enum.map(i.env, fn {key, value} -> key <> "=" <> value end)

    IO.iodata_to_binary([
      <<"S", 1::32>>,
      str(p.session.workspace),
      str(i.spool.root),
      str("input"),
      str(i.spool.root),
      str(i.final),
      list([i.executable | i.args]),
      list(env),
      <<i.spool.limit - i.spool.used::32, i.grace::32, i.drain::32>>
    ])
  end

  defp str(s), do: [<<byte_size(s)::32>>, s]
  defp list(items), do: [<<length(items)::32>>, Enum.map(items, &str/1)]

  defp command(port, bytes) do
    try do
      Port.command(port, bytes)
    catch
      _, _ -> false
    end
  end

  defp close(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
