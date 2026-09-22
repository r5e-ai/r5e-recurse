defmodule R5eRecurse.SessionKeys do
  @moduledoc "Ephemeral runtime custody. Generation and public key are evidence; private keys never leave this process."
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def boot_id(server), do: GenServer.call(server, :boot_id)
  def create(server, session, owner), do: GenServer.call(server, {:create, session, owner})

  def owned_by?(server, generation, owner),
    do: GenServer.call(server, {:owner, generation, owner})

  def public_key(server, generation), do: GenServer.call(server, {:public, generation})

  def sign(server, generation, bytes) when is_binary(bytes),
    do: GenServer.call(server, {:sign, generation, bytes})

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
          private: private
        }

        {:reply, {:ok, %{generation: generation, public_key: public}},
         put_in(state.keys[generation], key)}
    end
  end

  def handle_call({:destroy, generation}, _, state) do
    {:reply, :ok, remove(state, generation)}
  end

  def handle_call(request, _, state) do
    generation = elem(request, 1)

    case Map.fetch(state.keys, generation) do
      {:ok, key} ->
        if Process.alive?(key.owner) do
          result =
            case request do
              {:owner, _, owner} -> key.owner == owner
              {:public, _} -> key.public
              {:sign, _, bytes} -> :crypto.sign(:eddsa, :none, bytes, [key.private, :ed25519])
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
    {:noreply, %{state | keys: Map.reject(state.keys, fn {_, key} -> key.monitor == ref end)}}
  end

  # Removal releases the BEAM reference; it is not a claim of physical memory zeroization.
  defp remove(state, generation) do
    case Map.pop(state.keys, generation) do
      {nil, _} ->
        state

      {key, keys} ->
        Process.demonitor(key.monitor, [:flush])
        %{state | keys: keys}
    end
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  @impl true
  def format_status(status), do: Map.new(status, fn {key, _value} -> {key, :redacted} end)
end
