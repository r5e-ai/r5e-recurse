# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Spool.JsonLines do
  @moduledoc """
  Optional bounded JSON-line framing, without provider-specific interpretation.
  Raw spool bytes remain authoritative; each decoded value cites exact sequence
  byte ranges. Partial UTF-8/JSON is buffered only up to the configured frame cap.
  """
  defstruct buffer: <<>>, coverage: [], limit: 65_536

  def new(limit \\ 65_536) when is_integer(limit) and limit in 1..8_388_608,
    do: %__MODULE__{limit: limit}

  def push(state, sequence, bytes) when is_binary(bytes) and is_integer(sequence) do
    pieces = :binary.split(bytes, "\n", [:global])
    consume(pieces, state, sequence, 0, [])
  end

  def finish(%{buffer: <<>>}), do: :ok
  def finish(_), do: {:error, :incomplete_frame}

  defp consume([last], s, seq, offset, events) do
    with {:ok, next} <- append(s, seq, offset, last), do: {:ok, Enum.reverse(events), next}
  end

  defp consume([part | rest], s, seq, offset, events) do
    with {:ok, next} <- append(s, seq, offset, part <> "\n"),
         {:ok, value} <- Jason.decode(next.buffer) do
      event = %{value: value, coverage: next.coverage}

      consume(rest, %{next | buffer: <<>>, coverage: []}, seq, offset + byte_size(part) + 1, [
        event | events
      ])
    else
      {:error, :frame_limit} = error -> error
      _ -> {:error, :invalid_json_frame}
    end
  end

  defp append(s, _seq, _offset, <<>>), do: {:ok, s}

  defp append(s, seq, offset, bytes) do
    if byte_size(s.buffer) + byte_size(bytes) <= s.limit and length(s.coverage) < 1024 do
      {:ok,
       %{
         s
         | buffer: s.buffer <> bytes,
           coverage: s.coverage ++ [%{sequence: seq, offset: offset, bytes: byte_size(bytes)}]
       }}
    else
      {:error, :frame_limit}
    end
  end
end
