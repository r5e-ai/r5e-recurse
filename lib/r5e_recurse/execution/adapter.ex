# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Adapter do
  @moduledoc """
  Invocation and observation contract for managed execution (Spec 001 T051).

  Preparation does not launch. The coordinator must admit the SessionBinding
  and launch intent before calling `start/1`; these structs are not evidence of
  either admission. Adapters receive an opaque local route credential, never a
  session signing key. Provider authentication remains a separately provisioned
  client mechanism. No adapter callback may grant authority or retry a task.

  `observe/1` returns an ordered batch and the updated handle. Raw stdout/stderr
  bytes and parsed events remain distinct; derived events must cite their raw
  chunk coverage. An empty batch means no new observation, not successful exit.
  OS exit and model completion are separate event types. Artifact admission and
  workflow success belong to the coordinator, not this interface.

  Cancellation reports observed stop or uncertainty. Reconciliation is read-only
  and must not start work or restore a route. A bare recovered PID is insufficient
  ownership evidence. Each adapter declares its actual limitations, including
  detached descendants. Callback deadlines and owner monitoring belong to the
  execution supervisor; a timeout is not evidence that external work stopped.
  """

  defmodule Capabilities do
    @moduledoc "Declared adapter guarantees, measured against the pinned harness."
    @enforce_keys [
      :harness,
      :version,
      :auth_modes,
      :transports,
      :context_inputs,
      :control_inputs,
      :output_events,
      :cancellation,
      :descendants,
      :tool_restrictions,
      :evidence_limits
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            harness: String.t(),
            version: String.t(),
            auth_modes: [atom()],
            transports: [atom()],
            context_inputs: [atom()],
            control_inputs: [atom()],
            output_events: [atom()],
            cancellation: :unsupported | :observed_process | :observed_group,
            descendants: :unobserved | :cooperative_group,
            tool_restrictions: [String.t()],
            evidence_limits: [String.t()]
          }
  end

  defmodule Session do
    @moduledoc "Trusted prepared inputs; secret routing/auth state is never evidence."
    @enforce_keys [
      :id,
      :generation,
      :owner,
      :binding_ref,
      :context_ref,
      :rendered_input,
      :workspace,
      :model,
      :auth_mode,
      :route,
      :budgets
    ]
    @derive {Inspect, only: [:id, :generation, :binding_ref, :context_ref]}
    # Trusted adapter-specific configuration (e.g. executable/isolation options).
    # Kept separate from budgets and never copied from model output.
    defstruct @enforce_keys ++ [adapter_options: %{}]

    @type t :: %__MODULE__{
            adapter_options: map(),
            id: String.t(),
            generation: map(),
            owner: pid(),
            binding_ref: String.t(),
            context_ref: String.t(),
            rendered_input: binary(),
            workspace: Path.t(),
            model: String.t(),
            auth_mode: atom(),
            route: term(),
            budgets: map()
          }
  end

  defmodule Prepared do
    @moduledoc "Adapter-specific validated invocation; constructing it grants nothing."
    @enforce_keys [:adapter, :session, :invocation]
    @derive {Inspect, only: [:adapter]}
    defstruct @enforce_keys ++ [launch_ref: nil]

    @type t :: %__MODULE__{
            adapter: module(),
            session: Session.t(),
            invocation: term(),
            launch_ref: String.t() | nil
          }
  end

  defmodule Handle do
    @moduledoc "Captured execution identity and adapter state, never a name-based lookup."
    @enforce_keys [:adapter, :session_id, :generation, :owner, :identity, :state]
    @derive {Inspect, only: [:adapter, :session_id, :generation]}
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            adapter: module(),
            session_id: String.t(),
            generation: map(),
            owner: pid(),
            identity: term(),
            state: term()
          }
  end

  defmodule Observation do
    @moduledoc "Raw chunks preserve bytes; parsed/model events cite source coverage."
    @enforce_keys [:sequence, :source, :kind, :value, :coverage]
    @derive {Inspect, only: [:sequence, :source, :kind, :coverage]}
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            sequence: non_neg_integer(),
            source: :stdout | :stderr | :process | :result_file,
            kind: :raw_chunk | :parsed_event | :model_completion | :os_exit | :capture_incomplete,
            value: term(),
            coverage: [map()]
          }
  end

  defmodule Ownership do
    @moduledoc "An ownership observation, not permission to resume the recorded execution."
    @enforce_keys [:state, :identity, :evidence, :spool]
    @derive {Inspect, only: [:state]}
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            state: :live | :stopped | :unknown,
            identity: term(),
            evidence: [map()],
            spool: term()
          }
  end

  @type refusal :: {:error, atom()}
  @callback capabilities() :: Capabilities.t()
  @callback prepare(Session.t()) :: {:ok, Prepared.t()} | refusal()
  @callback start(Prepared.t()) :: {:ok, Handle.t()} | refusal()
  @callback observe(Handle.t()) :: {:ok, [Observation.t()], Handle.t()} | refusal()
  @callback cancel(Handle.t(), atom()) :: {:ok, Ownership.t()} | refusal()
  @callback reconcile(map()) :: {:ok, Ownership.t()} | refusal()
end
