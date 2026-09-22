defmodule R5eRecurse.Authority do
  @moduledoc """
  Credential candidate construction, without admission or hidden signing custody.

  Core enforces subject, Kind intersection, term and revocation. Its free-form
  `scope` is descriptive until deployment admission policy enforces it. These
  plans explicitly report that outstanding obligation; they are not launch grants.
  The Recurse adapter resolves immutable Task/Node lineage via tracked kernel
  facts for Task and SessionBinding admissions. Gateway and CAS scope remain a
  managed signer/route integration obligation (R5E-215 and gateway integration),
  not a core guarantee. Client-only preflight is insufficient. This module does
  not submit credentials or enable routes.
  """
  alias R5eRecurse.Authority.Kinds
  alias RecurseVerify.{Canonical, DSSE, Instant}
  @payload_type "application/vnd.r5e.admission-request+json;v=1"

  def task_creation(opts) do
    build(
      "Endorsement",
      opts,
      Kinds.task_creation(),
      %{
        "taskId" => Keyword.fetch!(opts, :task_id),
        "node" => Keyword.fetch!(opts, :node_ref)
      },
      "task_creation"
    )
  rescue
    _ -> {:error, :invalid_credential_options}
  end

  def session_endorsement(opts) do
    with {:ok, kinds} <- Kinds.for_role(Keyword.get(opts, :role)) do
      build(
        "Endorsement",
        opts,
        kinds,
        %{"task" => Keyword.fetch!(opts, :task_ref)},
        to_string(opts[:role])
      )
    end
  rescue
    _ -> {:error, :invalid_credential_options}
  end

  def deployment_badge(opts) do
    with {:ok, kinds} <- Kinds.for_role(Keyword.get(opts, :role)),
         {:ok, plan} <-
           build(
             "Badge",
             opts,
             kinds,
             %{"task" => Keyword.fetch!(opts, :task_ref)},
             to_string(opts[:role])
           ) do
      subject_kind = if opts[:role] == :runtime_action, do: "service", else: "agent"
      {:ok, put_in(plan, [:candidate, :spec, "subjectKind"], subject_kind)}
    end
  rescue
    _ -> {:error, :invalid_credential_options}
  end

  defp build(kind, opts, kinds, scope, role) do
    public = Keyword.fetch!(opts, :subject_public_key)
    first = Keyword.fetch!(opts, :not_before)
    last = Keyword.fetch!(opts, :not_after)
    parent = Keyword.get(opts, :operator_badge)

    with true <- is_binary(public) and byte_size(public) == 32,
         {:ok, :lt} <- Instant.compare(first, last),
         true <- Enum.all?(Map.values(scope), &(is_binary(&1) and byte_size(&1) > 0)),
         true <- is_nil(parent) or (is_binary(parent) and String.starts_with?(parent, "event:")) do
      spec = %{
        "subject" => DSSE.key_id!("ed25519", public),
        "subjectKey" => %{"algorithm" => "ed25519", "bytes" => Base.encode64(public)},
        "kinds" => kinds,
        "mayIssue" => false,
        "notBefore" => first,
        "notAfter" => last,
        "scope" => scope,
        "role" => role
      }

      spec = if parent, do: Map.put(spec, "parent", %{"$ref" => parent}), else: spec

      {:ok,
       %{
         candidate: %{group: "core.r5e.io", version: "v1", kind: kind, name: nil, spec: spec},
         authority: if(parent, do: [parent], else: []),
         required_signers: if(kind == "Badge", do: [:issuer, :subject], else: [:issuer]),
         scope_enforcement: :requires_deployment_policy
       }}
    else
      _ -> {:error, :invalid_credential_options}
    end
  end

  @doc "Strict equality against facts resolved by admission policy, never caller assertions."
  def scope_allows?(%{"taskId" => id, "node" => node} = scope, facts) when map_size(scope) == 2,
    do:
      facts[:kind] == "recurse.r5e.io/v1alpha1/Task" and facts[:task_id] == id and
        facts[:node_ref] == node

  def scope_allows?(%{"task" => task} = scope, facts) when map_size(scope) == 1,
    do: is_binary(task) and facts[:task_ref] == task

  def scope_allows?(_, _), do: false

  @doc "Sign one canonical credential request; callbacks sign PAE and return {:ok, raw_signature}."
  def envelope(plan, request, issuer, subject \\ nil) do
    candidate = plan.candidate
    spec_address = Canonical.hash(candidate.spec)

    with true <-
           Enum.sort(Map.keys(request)) ==
             Enum.sort(~w(origin actor target specAddress derivedFrom authority nonce expires)),
         true <-
           request["target"] ==
             Map.take(candidate, [:group, :version, :kind, :name])
             |> Map.new(fn {k, v} -> {to_string(k), v} end),
         true <- request["specAddress"] == spec_address and request["authority"] == plan.authority,
         true <- request["actor"] == DSSE.key_id!("ed25519", issuer.public_key),
         true <-
           candidate.kind != "Badge" or
             (is_map(subject) and
                candidate.spec["subject"] == DSSE.key_id!("ed25519", subject.public_key)) do
      payload = Canonical.encode(request)
      signers = if candidate.kind == "Badge", do: [issuer, subject], else: [issuer]

      Enum.reduce_while(signers, {:ok, []}, fn signer, {:ok, signatures} ->
        pae = DSSE.pae(@payload_type, payload)

        case signer.sign.(pae) do
          {:ok, sig} when is_binary(sig) ->
            if DSSE.verify_ed25519(pae, sig, signer.public_key),
              do:
                {:cont,
                 {:ok,
                  signatures ++
                    [
                      %{
                        "keyid" => DSSE.key_id!("ed25519", signer.public_key),
                        "sig" => Base.encode64(sig)
                      }
                    ]}},
              else: {:halt, {:error, :invalid_signature}}

          _ ->
            {:halt, {:error, :signer_refused}}
        end
      end)
      |> case do
        {:ok, signatures} ->
          {:ok,
           %{
             "payloadType" => @payload_type,
             "payload" => Base.encode64(payload),
             "signatures" => signatures,
             "publicKeys" =>
               Enum.map(Enum.uniq_by(signers, & &1.public_key), fn s ->
                 %{
                   "keyid" => DSSE.key_id!("ed25519", s.public_key),
                   "algorithm" => "ed25519",
                   "bytes" => Base.encode64(s.public_key)
                 }
               end)
           }}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_credential_request}
    end
  rescue
    _ -> {:error, :invalid_credential_request}
  end
end
