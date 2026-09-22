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
  The snapshot callback's trust/completeness contract is Authority's contract.
  No gateway route, reader authenticity, first-input check or dispatch is implied.
  """
  use GenServer
  alias R5eRecurse.{SessionKeys, Signer.Request, Signer.Authority}
  alias RecurseVerify.{Canonical, DSSE}
  @type_name "application/vnd.r5e.admission-request+json;v=1"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def register(server, owner, generation, operation_id, context),
    do: call(server, {:register, owner, generation, operation_id, context})

  def sign(server, slot, wire), do: call(server, {:sign, slot, nil, wire})

  def channel_handler(server) do
    fn binding, wire ->
      with %{slot: slot, generation: generation} <- binding do
        call(server, {:sign, slot, generation, wire})
      else
        _ -> {:error, :invalid_binding}
      end
    end
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :signer_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       keys: Keyword.fetch!(opts, :keys),
       snapshot: Keyword.fetch!(opts, :snapshot),
       clock: Keyword.get(opts, :clock, fn -> DateTime.utc_now() end),
       slots: %{},
       operations: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:register, owner, generation, operation_id, context}, _, s) do
    operation = {generation, operation_id, registered_kind(context)}

    cond do
      MapSet.member?(s.operations, operation) ->
        {:reply, {:error, :operation_registered}, s}

      not registration?(s, owner, generation, operation_id, context) ->
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

  def handle_call({:sign, slot, generation, wire}, _, s) do
    case Map.fetch(s.slots, slot) do
      {:ok, %{consumed: false} = entry}
      when is_nil(generation) or generation == entry.generation ->
        # All later calls see this consumed slot, including after a failed attempt.
        s = put_in(s.slots[slot].consumed, true)
        {:reply, prepare_and_sign(s, entry, wire), s}

      {:ok, %{consumed: true}} ->
        {:reply, {:error, :operation_consumed}, s}

      _ ->
        {:reply, {:error, :invalid_binding}, s}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, s),
    do:
      {:noreply, %{s | slots: Map.reject(s.slots, fn {_, entry} -> entry.monitor == monitor end)}}

  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def format_status(status), do: Map.new(status, fn {k, _} -> {k, :redacted} end)

  defp registered_kind(%{authority: %{kind: kind}}), do: kind
  defp registered_kind(_), do: nil

  defp registration?(
         s,
         owner,
         generation,
         id,
         %{request: request, authority: authority} = context
       ) do
    map_size(context) == 2 and is_pid(owner) and is_binary(id) and id != "" and
      request.actor == authority.actor and request.role == authority.role and
      request.authority == authority.authority and is_binary(authority.kind) and
      (authority.kind != "recurse.r5e.io/v1alpha1/ManagedRequest" or
         get_in(request, [:managed, "operationId"]) == id) and
      match?({:ok, _}, live_key(s, owner, generation, request.actor)) and
      SessionKeys.bind_signer(s.keys, generation, self()) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp registration?(_, _, _, _, _), do: false

  defp prepare_and_sign(s, entry, wire) do
    request_context = entry.context.request
    authority_context = entry.context.authority

    with {:ok, public} <- live_key(s, entry.owner, entry.generation, request_context.actor),
         true <- wire["kind"] == authority_context.kind,
         {:ok, candidate} <- Request.prepare(wire, request_context),
         {:ok, snapshot} <- s.snapshot.(s.clock.()),
         {:ok, ^public} <- live_key(s, entry.owner, entry.generation, request_context.actor),
         {:ok, credential} <-
           Authority.validate(snapshot, Map.put(authority_context, :now, s.clock.())) do
      request = %{
        "origin" => authority_context.origin,
        "actor" => request_context.actor,
        "target" => candidate.target,
        "specAddress" => candidate.spec_address,
        "derivedFrom" => nil,
        "authority" => credential.authority,
        "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
        "expires" => credential.expires
      }

      bytes = Canonical.encode(request)
      message = DSSE.pae(@type_name, bytes)

      with {:ok, signature} <- SessionKeys.sign(s.keys, entry.generation, message),
           true <- DSSE.verify_ed25519(message, signature, public) do
        {:ok,
         %{
           "payloadType" => @type_name,
           "payload" => Base.encode64(bytes),
           "signatures" => [
             %{"keyid" => request_context.actor, "sig" => Base.encode64(signature)}
           ],
           "publicKeys" => [
             %{
               "keyid" => request_context.actor,
               "algorithm" => "ed25519",
               "bytes" => Base.encode64(public)
             }
           ]
         }}
      else
        _ -> {:error, :signer_refused}
      end
    else
      _ -> {:error, :signer_refused}
    end
  rescue
    _ -> {:error, :signer_refused}
  catch
    _, _ -> {:error, :signer_refused}
  end

  defp live_key(s, owner, generation, actor) do
    with true <- Process.alive?(owner),
         {:ok, true} <- SessionKeys.owned_by?(s.keys, generation, owner),
         {:ok, public} <- SessionKeys.public_key(s.keys, generation),
         true <- DSSE.key_id!("ed25519", public) == actor do
      {:ok, public}
    else
      _ -> {:error, :stale_binding}
    end
  end
end
