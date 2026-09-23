# SPDX-License-Identifier: AGPL-3.0-only
defmodule R5eRecurse.Execution.Spool do
  @moduledoc """
  Local byte evidence, never canonical admission. Every raw chunk is immutable,
  synced before acknowledgment, and at most 8 MiB. Known input/request bytes and
  captured bytes share a 64 MiB ceiling; future bridge requests must reserve their
  bytes through `account/2` before dispatch. No claim is made about unreported
  provider request bytes. Parsed framing is derived from retained byte coverage.
  """
  @max 64 * 1024 * 1024
  @chunk 8 * 1024 * 1024
  defstruct [:root, :limit, :used, entries: [], count: 0, revision: 0, incomplete: nil]

  def create(base, input, limit, reserved \\ 0)

  def create(base, input, limit, reserved)
      when is_binary(input) and is_integer(limit) and limit > 0 and limit <= @max and
             is_integer(reserved) and reserved >= 0 do
    root =
      Path.join(base, "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))

    with true <- byte_size(input) + reserved <= limit,
         :ok <- File.mkdir(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- write_new(Path.join(root, "input"), input) do
      persist(
        %__MODULE__{root: root, limit: limit, used: byte_size(input) + reserved},
        %{type: "prepared", limit: limit, accounted: byte_size(input) + reserved}
      )
    else
      _ -> {:error, :spool_preparation_failed}
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_spool_budget}

  def account(%__MODULE__{} = s, bytes) when is_integer(bytes) and bytes >= 0 do
    if s.used + bytes <= s.limit do
      persist(%{s | used: s.used + bytes}, %{type: "reserve", bytes: bytes})
    else
      {:error, %{s | incomplete: :trace_budget}}
    end
  end

  def append(%__MODULE__{} = s, stream, sequence, bytes)
      when stream in [:stdout, :stderr, :result_file] and is_binary(bytes) and
             byte_size(bytes) <= @chunk and is_integer(sequence) and sequence >= 0 do
    entry = %{
      stream: stream,
      sequence: sequence,
      path: "#{stream}-#{sequence}.raw",
      bytes: byte_size(bytes),
      sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }

    if s.count < 16_384 and s.incomplete == nil and s.used + byte_size(bytes) <= s.limit do
      with {:ok, pending} <-
             persist(%{s | used: s.used + byte_size(bytes)}, %{type: "chunk_intent", chunk: entry}) do
        with :ok <- write_new(Path.join(s.root, entry.path), bytes),
             {:ok, next} <- persist(pending, %{type: "chunk_complete", sequence: sequence}) do
          {:ok, %{next | entries: [entry | s.entries], count: s.count + 1}, entry}
        else
          _ -> {:error, %{pending | incomplete: :spool_write_failed}}
        end
      end
    else
      {:error, %{s | incomplete: :trace_budget}}
    end
  end

  def finish(s, outcome), do: persist(s, %{type: "terminal", outcome: outcome})

  @doc "Read-only diagnostic recovery. Missing/partial terminal records never imply complete capture."
  def recover(root) do
    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, names} <- File.ls(root),
         records = names |> Enum.filter(&String.starts_with?(&1, "record-")) |> Enum.sort(),
         true <- length(records) in 1..65_536 do
      Enum.reduce_while(
        Enum.with_index(records, 1),
        {:ok, %{accounted: 0, limit: nil, pending: %{}, chunks: [], terminal: nil}},
        fn {name, index}, {:ok, state} ->
          with true <- name == record_name(index),
               {:ok, %{type: :regular, size: size}} when size <= 65_536 <-
                 File.lstat(Path.join(root, name)),
               {:ok, bytes} <- File.read(Path.join(root, name)),
               {:ok, record} <- Jason.decode(bytes),
               {:ok, next} <- replay(record, state) do
            {:cont, {:ok, next}}
          else
            _ -> {:halt, {:error, :incomplete_local_spool}}
          end
        end
      )
      |> case do
        {:ok, state} ->
          {:ok,
           Map.put(
             state,
             :complete,
             state.terminal != nil and state.pending == %{} and
               state.terminal["capture_incomplete"] == false and valid_chunks?(root, state.chunks)
           )}

        error ->
          error
      end
    else
      _ -> {:error, :incomplete_local_spool}
    end
  end

  defp valid_chunks?(root, chunks) do
    Enum.all?(chunks, fn chunk ->
      stream = chunk["stream"]
      seq = chunk["sequence"]
      expected = "#{stream}-#{seq}.raw"

      with true <-
             stream in ["stdout", "stderr", "result_file"] and is_integer(seq) and seq >= 0 and
               chunk["path"] == expected,
           {:ok, %{type: :regular, size: size}} when size <= @chunk <-
             File.lstat(Path.join(root, expected)),
           {:ok, bytes} <- File.read(Path.join(root, expected)) do
        byte_size(bytes) == chunk["bytes"] and
          Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == chunk["sha256"]
      else
        _ -> false
      end
    end)
  end

  defp replay(_, %{terminal: terminal}) when terminal != nil,
    do: {:error, :incomplete_local_spool}

  defp replay(%{"type" => "prepared", "accounted" => n, "limit" => limit}, %{limit: nil} = s)
       when is_integer(n) and n >= 0 and is_integer(limit) and limit in 1..@max and n <= limit,
       do: {:ok, %{s | accounted: n, limit: limit}}

  defp replay(_, %{limit: nil}), do: {:error, :incomplete_local_spool}

  defp replay(%{"type" => "reserve", "bytes" => n}, s)
       when is_integer(n) and n >= 0 and s.accounted + n <= s.limit,
       do: {:ok, %{s | accounted: s.accounted + n}}

  defp replay(
         %{"type" => "chunk_intent", "chunk" => %{"sequence" => seq, "bytes" => n} = chunk},
         s
       )
       when is_integer(n) and n >= 0 and n <= @chunk and is_integer(seq) and seq >= 0 and
              s.accounted + n <= s.limit,
       do: {:ok, %{s | accounted: s.accounted + n, pending: Map.put(s.pending, seq, chunk)}}

  defp replay(%{"type" => "chunk_complete", "sequence" => seq}, s) do
    case Map.pop(s.pending, seq) do
      {nil, _} -> {:error, :incomplete_local_spool}
      {chunk, pending} -> {:ok, %{s | pending: pending, chunks: s.chunks ++ [chunk]}}
    end
  end

  defp replay(%{"type" => "terminal", "outcome" => outcome}, s) when is_map(outcome),
    do: {:ok, %{s | terminal: outcome}}

  defp replay(_, _), do: {:error, :incomplete_local_spool}

  defp persist(s, record) do
    next = %{s | revision: s.revision + 1}

    if next.revision <= 65_536 and
         write_new(Path.join(s.root, record_name(next.revision)), Jason.encode!(record)) == :ok,
       do: {:ok, next},
       else: {:error, %{next | incomplete: :spool_write_failed}}
  end

  defp record_name(n),
    do: "record-" <> String.pad_leading(Integer.to_string(n), 6, "0") <> ".json"

  def manifest(s),
    do: %{
      root: s.root,
      bytes_accounted: s.used,
      limit: s.limit,
      incomplete: s.incomplete,
      chunks: Enum.reverse(s.entries)
    }

  def read(s, entry) do
    with {:ok, bytes} <- File.read(Path.join(s.root, entry.path)),
         true <-
           byte_size(bytes) == entry.bytes and
             Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == entry.sha256,
         do: {:ok, bytes},
         else: (_ -> {:error, :spool_corrupt})
  end

  defp write_new(path, bytes) do
    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        try do
          with :ok <- :file.write(io, bytes), do: :file.sync(io)
        after
          :file.close(io)
        end

      error ->
        error
    end
  end
end
