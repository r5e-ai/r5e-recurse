defmodule R5eRecurse.Signer do
  @moduledoc """
  Stateful signing of trusted registered operation slots, without admission/dispatch.

  Start with `keys: SessionKeys.pid`, `snapshot: fn now -> {:ok, snapshot} end`
  and optional trusted `clock: fn -> DateTime.utc_now() end`. Registration is an
  in-process runtime operation: `register(server, owner, generation, operation_id,
  %{request: Request.context, authority: Authority.context})`. The authority
  context fixes the operation Kind. Actor, role and exact authority refs must agree
  across contexts; the generation and actor must match the live owner/key.

  `sign(server, slot, wire)` accepts Request's exact three wire fields and returns
  only `{:ok, dsse_envelope}` or a bounded error. Each slot is consumed before its
  first attempt, including validation/read/key failures. No retry re-signs. The
  generation/operation/Kind tuple cannot be registered again during this service's life.
  One HTTP operation can have separate Prompt, LlmCall and ManagedRequest slots.
  A ManagedRequest slot ID must equal its registered canonical operationId.
  `channel_handler(server)` adapts a trusted Channel binding containing `slot`
  and the Channel-supplied `generation`, checking that generation against the slot.

  First registration immutably binds the generation to this signer process in
  SessionKeys. Signer death destroys/fences that generation synchronously, so a
  replacement signer cannot reuse its key or operation slots. This is not a
  crash-persistent journal; prior outcomes still require canonical recovery.
  Review and other unimplemented Request Kinds refuse.
  Calls carry a monotonic deadline originating before queuing (4 seconds by
  default, shorter trusted attempt_timeout_ms allowed). Preflight/clock callbacks
  are bounded in monitored workers; queued expired key requests never sign.
  Keys rechecks expiry and snapshot age at execution and after signing. Outer
  calls allow 5 seconds so the internal deadline completes first. Final envelope release
  is authorized atomically in SessionKeys after its last bounded clock check;
  owner, signer and generation must still be live at that custody authorization
  point. Retirement serialized after that point cannot retract an authorized
  envelope. No blocking callback runs between authorization and return.
  The snapshot callback's trust/completeness contract is Authority's contract.
  No gateway route, reader authenticity, first-input check or dispatch is implied.
  """
  use GenServer
  alias R5eRecurse.{SessionKeys, Signer.Request, Signer.Authority}
  alias RecurseVerify.{Canonical, DSSE}
  @attempt_ms 4_000
  @type_name "application/vnd.r5e.admission-request+json;v=1"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def register(server, owner, generation, operation_id, context),
    do: call(server, {:register, owner, generation, operation_id, context, attempt()})

  def sign(server, slot, wire), do: call(server, {:sign, slot, nil, wire, attempt()})

  def channel_handler(server) do
    fn binding, wire ->
      with %{slot: slot, generation: generation} <- binding do
        call(
          server,
          {:sign, slot, generation, wire,
           attempt(Map.get(binding, :deadline), Map.get(binding, :attempt_started_at))}
        )
      else
        _ -> {:error, :invalid_binding}
      end
    end
  end

  defp attempt(external_deadline \\ nil, original_start \\ nil) do
    started = original_start || System.monotonic_time(:millisecond)
    {started, external_deadline || started + @attempt_ms}
  end

  defp attempt_deadline({started, external}, budget), do: min(external, started + budget)

  defp call(server, message) do
    GenServer.call(server, message, 5_000)
  catch
    :exit, _ -> {:error, :signer_unavailable}
  end

  @impl true
  def init(opts) do
    keys = Keyword.fetch!(opts, :keys)

    {:ok,
     %{
       keys: keys,
       keys_monitor: Process.monitor(keys),
       snapshot: Keyword.fetch!(opts, :snapshot),
       clock: Keyword.get(opts, :clock, fn -> DateTime.utc_now() end),
       attempt_ms: min(@attempt_ms, max(1, Keyword.get(opts, :attempt_timeout_ms, @attempt_ms))),
       slots: %{},
       operations: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:register, owner, generation, operation_id, context, supplied_deadline}, _, s) do
    deadline = attempt_deadline(supplied_deadline, s.attempt_ms)
    operation = {generation, operation_id, registered_kind(context)}

    cond do
      MapSet.member?(s.operations, operation) ->
        {:reply, {:error, :operation_registered}, s}

      not registration?(s, owner, generation, operation_id, context, deadline) ->
        {:reply, {:error, :invalid_registration}, s}

      true ->
        slot = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        entry = %{
          owner: owner,
          generation: generation,
          context: context,
          consumed: false,
          monitor: Process.monitor(owner)
        }

        {:reply, {:ok, slot},
         %{
           s
           | slots: Map.put(s.slots, slot, entry),
             operations: MapSet.put(s.operations, operation)
         }}
    end
  end

  def handle_call({:sign, slot, generation, wire, supplied_deadline}, _, s) do
    deadline = attempt_deadline(supplied_deadline, s.attempt_ms)

    case Map.fetch(s.slots, slot) do
      {:ok, %{consumed: false} = entry}
      when is_nil(generation) or generation == entry.generation ->
        # All later calls see this consumed slot, including after a failed attempt.
        s = put_in(s.slots[slot], Map.drop(%{entry | consumed: true}, [:context]))
        {:reply, prepare_and_sign(s, entry, wire, deadline), s}

      {:ok, %{consumed: true}} ->
        {:reply, {:error, :operation_consumed}, s}

      _ ->
        {:reply, {:error, :invalid_binding}, s}
    end
  end

  @impl true
  def handle_info({:session_key_retired, keys, generation}, %{keys: keys} = s),
    do: {:noreply, retire(s, MapSet.new([generation]))}

  def handle_info({:DOWN, monitor, :process, keys, _}, %{keys_monitor: monitor, keys: keys} = s),
    do: {:noreply, retire(s, MapSet.new(s.slots, fn {_, e} -> e.generation end))}

  def handle_info({:DOWN, monitor, :process, owner, _}, s) do
    if Enum.any?(s.slots, fn {_, e} -> e.monitor == monitor and e.owner == owner end) do
      retired = Enum.filter(s.slots, fn {_, e} -> e.owner == owner end)
      generations = MapSet.new(retired, fn {_, e} -> e.generation end)
      {:noreply, retire(s, generations)}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # Retirement is irreversible: release request contexts and replay IDs only
  # once custody has discarded the generation, or its owner/service is dead.
  defp retire(s, generations) do
    {retired, retained} =
      Enum.split_with(s.slots, fn {_, e} -> MapSet.member?(generations, e.generation) end)

    Enum.each(retired, fn {_, e} -> Process.demonitor(e.monitor, [:flush]) end)

    %{
      s
      | slots: Map.new(retained),
        operations:
          MapSet.reject(s.operations, fn {generation, _, _} ->
            MapSet.member?(generations, generation)
          end)
    }
  end

  @impl true
  def format_status(status), do: Map.new(status, fn {k, _} -> {k, :redacted} end)

  defp registered_kind(%{authority: %{kind: kind}}), do: kind
  defp registered_kind(_), do: nil

  defp registration?(
         s,
         owner,
         generation,
         id,
         %{request: request, authority: authority} = context,
         deadline
       ) do
    map_size(context) == 2 and is_pid(owner) and is_binary(id) and id != "" and
      request.actor == authority.actor and request.role == authority.role and
      request.authority == authority.authority and is_binary(authority.kind) and
      (authority.kind != "recurse.r5e.io/v1alpha1/ManagedRequest" or
         get_in(request, [:managed, "operationId"]) == id) and
      before?(deadline) and
      match?({:ok, _}, bind_key(s, owner, generation, request.actor, deadline))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp registration?(_, _, _, _, _, _), do: false

  defp prepare_and_sign(s, entry, wire, deadline) do
    signer = self()

    with true <- before?(deadline),
         {:ok, prepared} when is_map(prepared) <-
           bounded(fn -> preflight(s, entry, wire, signer, deadline) end, deadline),
         true <- before?(deadline),
         {:ok, signature} <-
           SessionKeys.sign_before(
             s.keys,
             entry.generation,
             entry.owner,
             signer,
             prepared.message,
             deadline,
             prepared.validity
           ),
         true <-
           before?(deadline) and DSSE.verify_ed25519(prepared.message, signature, prepared.public),
         :ok <-
           SessionKeys.release_before(
             s.keys,
             entry.generation,
             entry.owner,
             signer,
             prepared.public,
             deadline,
             prepared.validity
           ),
         true <- before?(deadline) do
      {:ok,
       %{
         "payloadType" => @type_name,
         "payload" => Base.encode64(prepared.bytes),
         "signatures" => [%{"keyid" => prepared.actor, "sig" => Base.encode64(signature)}],
         "publicKeys" => [
           %{
             "keyid" => prepared.actor,
             "algorithm" => "ed25519",
             "bytes" => Base.encode64(prepared.public)
           }
         ]
       }}
    else
      _ -> {:error, :signer_refused}
    end
  rescue
    _ -> {:error, :signer_refused}
  catch
    _, _ -> {:error, :signer_refused}
  end

  defp preflight(s, entry, wire, signer, deadline) do
    r = entry.context.request
    a = entry.context.authority

    with {:ok, public} <- live_key(s, entry.owner, entry.generation, r.actor, signer, deadline),
         true <- wire["kind"] == a.kind,
         {:ok, candidate} <- Request.prepare(wire, r),
         {:ok, snapshot} <- s.snapshot.(s.clock.()),
         {:ok, credential} <- Authority.validate(snapshot, Map.put(a, :now, s.clock.())) do
      validity = %{
        clock: s.clock,
        expires: credential.expires,
        observed_at: snapshot.observed_at,
        max_age_seconds: a.max_snapshot_age_seconds
      }

      if still_valid?(validity, deadline) do
        request = %{
          "origin" => a.origin,
          "actor" => r.actor,
          "target" => candidate.target,
          "specAddress" => candidate.spec_address,
          "derivedFrom" => nil,
          "authority" => credential.authority,
          "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
          "expires" => credential.expires
        }

        bytes = Canonical.encode(request)

        %{
          public: public,
          actor: r.actor,
          bytes: bytes,
          message: DSSE.pae(@type_name, bytes),
          validity: validity
        }
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp still_valid?(v, deadline) do
    now = v.clock.()
    age = DateTime.diff(now, v.observed_at, :microsecond)

    before?(deadline) and age >= 0 and age <= v.max_age_seconds * 1_000_000 and
      RecurseVerify.Instant.compare(DateTime.to_iso8601(now), v.expires) == {:ok, :lt}
  end

  defp bounded(fun, deadline), do: R5eRecurse.Bounded.run(fun, deadline)

  defp bind_key(s, owner, generation, actor, deadline) do
    with {:ok, public} <- SessionKeys.public_key_before(s.keys, generation, deadline),
         true <- DSSE.key_id!("ed25519", public) == actor,
         {:ok, ^public} <-
           SessionKeys.binding_before(s.keys, generation, owner, self(), deadline, true) do
      {:ok, public}
    else
      _ -> {:error, :stale_binding}
    end
  end

  defp live_key(s, owner, generation, actor, signer, deadline) do
    with {:ok, public} <- SessionKeys.binding_before(s.keys, generation, owner, signer, deadline),
         true <- DSSE.key_id!("ed25519", public) == actor do
      {:ok, public}
    else
      _ -> {:error, :stale_binding}
    end
  end

  defp before?(deadline), do: System.monotonic_time(:millisecond) < deadline
end
