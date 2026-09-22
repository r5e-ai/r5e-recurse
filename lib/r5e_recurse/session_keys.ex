defmodule R5eRecurse.SessionKeys do
  @moduledoc "Ephemeral runtime custody. Generation and public key are evidence; private keys never leave this process."
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def boot_id(server), do: GenServer.call(server, :boot_id)
  def create(server, session, owner), do: GenServer.call(server, {:create, session, owner})

  def owned_by?(server, generation, owner),
    do: GenServer.call(server, {:owner, generation, owner})

  def bind_signer(server, generation, signer),
    do: GenServer.call(server, {:bind_signer, generation, signer})

  def public_key(server, generation), do: GenServer.call(server, {:public, generation})

  def sign(server, generation, bytes) when is_binary(bytes),
    do: GenServer.call(server, {:sign, generation, bytes})

  # Internal deadline-bearing APIs; deadlines are monotonic milliseconds, never wire fields.
  def binding_before(server, generation, owner, signer, deadline, bind \\ false),
    do:
      before_call(server, {:binding_before, generation, owner, signer, deadline, bind}, deadline)

  def owned_by_before(server, generation, owner, deadline),
    do: before_call(server, {:owner_before, generation, owner, deadline}, deadline)

  def public_key_before(server, generation, deadline),
    do: before_call(server, {:public_before, generation, deadline}, deadline)

  def sign_before(server, generation, owner, signer, bytes, deadline, validity),
    do:
      before_call(
        server,
        {:sign_before, generation, owner, signer, bytes, deadline, validity},
        deadline
      )

  # Final release linearizes here in custody. A later retirement cannot revoke an
  # already authorized release; no blocking callback follows this operation.
  def release_before(server, generation, owner, signer, public, deadline, validity),
    do:
      before_call(
        server,
        {:release_before, generation, owner, signer, public, deadline, validity},
        deadline
      )

  defp before_call(server, request, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: GenServer.call(server, request, remaining), else: {:error, :deadline}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def destroy(server, generation), do: GenServer.call(server, {:destroy, generation})

  @impl true
  def init(_), do: {:ok, %{boot: token(), keys: %{}}}
  @impl true
  def handle_call(:boot_id, _, state), do: {:reply, state.boot, state}

  def handle_call({:create, session, owner}, _, state)
      when is_binary(session) and is_pid(owner) do
    cond do
      not Process.alive?(owner) ->
        {:reply, {:error, :dead_owner}, state}

      Enum.any?(state.keys, fn {_, k} -> k.session == session end) ->
        {:reply, {:error, :session_exists}, state}

      true ->
        {public, private} = :crypto.generate_key(:eddsa, :ed25519)
        generation = %{"bootId" => state.boot, "runId" => token()}

        key = %{
          session: session,
          owner: owner,
          monitor: Process.monitor(owner),
          public: public,
          private: private,
          signer: nil,
          signer_monitor: nil
        }

        {:reply, {:ok, %{generation: generation, public_key: public}},
         put_in(state.keys[generation], key)}
    end
  end

  def handle_call({:destroy, generation}, _, state) do
    {:reply, :ok, remove(state, generation)}
  end

  def handle_call({:bind_signer, generation, signer}, _, state) when is_pid(signer) do
    case Map.fetch(state.keys, generation) do
      {:ok, key} ->
        cond do
          not live?(key) ->
            {:reply, {:error, :stale_binding}, remove(state, generation)}

          not Process.alive?(signer) ->
            {:reply, {:error, :dead_signer}, state}

          key.signer == signer ->
            {:reply, :ok, state}

          key.signer != nil ->
            {:reply, {:error, :signer_already_bound}, state}

          true ->
            key = %{key | signer: signer, signer_monitor: Process.monitor(signer)}
            {:reply, :ok, put_in(state.keys[generation], key)}
        end

      :error ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:owner_before, generation, owner, deadline}, from, state) do
    if before?(deadline),
      do: handle_call({:owner, generation, owner}, from, state),
      else: {:reply, {:error, :deadline}, state}
  end

  def handle_call({:public_before, generation, deadline}, from, state) do
    if before?(deadline),
      do: handle_call({:public, generation}, from, state),
      else: {:reply, {:error, :deadline}, state}
  end

  def handle_call({:binding_before, generation, owner, signer, deadline, bind}, _, state) do
    with true <- before?(deadline),
         {:ok, key} <- Map.fetch(state.keys, generation),
         true <- live?(key) and key.owner == owner and Process.alive?(signer),
         true <- key.signer == signer or (bind and key.signer == nil) do
      key =
        if key.signer == nil,
          do: %{key | signer: signer, signer_monitor: Process.monitor(signer)},
          else: key

      {:reply, {:ok, key.public}, put_in(state.keys[generation], key)}
    else
      _ -> {:reply, {:error, :stale_binding_or_deadline}, state}
    end
  end

  def handle_call(
        {:release_before, generation, owner, signer, public, deadline, validity},
        _,
        state
      ) do
    result =
      with true <- valid_now?(deadline, validity),
           {:ok, key} <- Map.fetch(state.keys, generation),
           true <- key.owner == owner and key.signer == signer and key.public == public,
           true <- live?(key) and before?(deadline),
           do: :ok,
           else: (_ -> {:error, :stale_release})

    {:reply, result, state}
  end

  def handle_call({:sign, generation, bytes}, _, state) do
    case Map.fetch(state.keys, generation) do
      {:ok, %{signer: nil} = key} ->
        if live?(key),
          do: {:reply, {:ok, :crypto.sign(:eddsa, :none, bytes, [key.private, :ed25519])}, state},
          else: {:reply, {:error, :stale_binding}, remove(state, generation)}

      {:ok, _} ->
        {:reply, {:error, :managed_generation}, state}

      :error ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:sign_before, generation, owner, signer, bytes, deadline, validity}, _, state) do
    result =
      with {:ok, key} <- Map.fetch(state.keys, generation),
           true <- key.owner == owner and key.signer == signer and live?(key),
           true <- valid_now?(deadline, validity) and live?(key) and before?(deadline),
           signature = :crypto.sign(:eddsa, :none, bytes, [key.private, :ed25519]),
           true <- valid_now?(deadline, validity) and live?(key) and before?(deadline) do
        {:ok, signature}
      else
        _ -> {:error, :stale_signing_attempt}
      end

    {:reply, result, state}
  end

  def handle_call(request, _, state) do
    generation = elem(request, 1)

    case Map.fetch(state.keys, generation) do
      {:ok, key} ->
        if live?(key) do
          result =
            case request do
              {:owner, _, owner} -> key.owner == owner
              {:public, _} -> key.public
            end

          {:reply, {:ok, result}, state}
        else
          {:reply, {:error, :stale_binding}, remove(state, generation)}
        end

      :error ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    generations =
      for {generation, key} <- state.keys,
          key.monitor == ref or key.signer_monitor == ref,
          do: generation

    {:noreply, Enum.reduce(generations, state, fn generation, acc -> remove(acc, generation) end)}
  end

  # Removal releases the BEAM reference; it is not a claim of physical memory zeroization.
  defp remove(state, generation) do
    case Map.pop(state.keys, generation) do
      {nil, _} ->
        state

      {key, keys} ->
        Process.demonitor(key.monitor, [:flush])
        if key.signer_monitor, do: Process.demonitor(key.signer_monitor, [:flush])
        if key.signer, do: send(key.signer, {:session_key_retired, self(), generation})
        %{state | keys: keys}
    end
  end

  # Synchronous checks fence reuse even before either monitor DOWN is handled.
  defp live?(key),
    do: Process.alive?(key.owner) and (key.signer == nil or Process.alive?(key.signer))

  defp before?(deadline),
    do: is_integer(deadline) and System.monotonic_time(:millisecond) < deadline

  defp valid_now?(deadline, validity) do
    with true <- before?(deadline),
         {:ok, %DateTime{} = now} <- bounded_clock(validity.clock, deadline),
         age = DateTime.diff(now, validity.observed_at, :microsecond),
         true <- age >= 0 and age <= validity.max_age_seconds * 1_000_000,
         {:ok, :lt} <- RecurseVerify.Instant.compare(DateTime.to_iso8601(now), validity.expires) do
      before?(deadline)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp bounded_clock(clock, deadline), do: R5eRecurse.Bounded.run(clock, deadline)

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  @impl true
  def format_status(status), do: Map.new(status, fn {key, _value} -> {key, :redacted} end)
end
