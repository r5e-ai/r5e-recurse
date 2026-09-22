defmodule R5eRecurse.BootstrapTest do
  use ExUnit.Case, async: true
  alias R5eRecurse.Bootstrap

  defp driver do
    {:ok, state} = Agent.start_link(fn -> %{records: %{}, writes: [], bytes: %{}} end)

    driver = fn
      :measure_engine, _ ->
        bytes = "deployment descriptor fixture"
        address = "bytes:sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        {:ok,
         %{
           address: address,
           bytes: bytes,
           spec: %{
             "address" => address,
             "class" => "raw",
             "size" => byte_size(bytes),
             "mediaType" => "application/vnd.r5e.engine-build+json"
           }
         }}

      :authority_plan, %{kinds: paths} ->
        candidate = fn kind ->
          %{
            group: "core.r5e.io",
            version: "v1",
            kind: kind,
            name: nil,
            spec: %{"subject" => "operator", "kinds" => paths}
          }
        end

        {:ok, %{node_endorsement: candidate.("Endorsement"), operator_badge: candidate.("Badge")}}

      :current_resource, c ->
        Agent.get(state, &Map.get(&1.records, c, :missing))

      :get_bytes, %{address: address} ->
        Agent.get(state, fn s -> Map.fetch(s.bytes, address) end)

      op, payload when op in [:admit, :put_bytes] ->
        Agent.get_and_update(state, fn s ->
          receipt = %{
            "spec" => payload.candidate.spec,
            "eventRef" => "admission-#{length(s.writes)}"
          }

          {{:ok, receipt},
           %{
             bytes:
               if(op == :put_bytes,
                 do: Map.put(s.bytes, payload.candidate.spec["address"], payload.bytes),
                 else: s.bytes
               ),
             records: Map.put(s.records, payload.candidate, {:ok, receipt}),
             writes: s.writes ++ [{op, payload}]
           }}
        end)
    end

    {driver, state}
  end

  test "explicit authority sequence and rerun writes nothing" do
    {driver, state} = driver()
    assert {:ok, rows} = Bootstrap.run(driver)
    assert length(rows) == 21
    assert Enum.all?(rows, &(&1.status == :admitted))
    writes = Agent.get(state, & &1.writes)

    [{_, e}, {_, b}, {:put_bytes, source}, {:put_bytes, engine}, {_, bundle}] =
      Enum.drop(writes, 16)

    assert e.candidate.kind == "Endorsement"
    assert b.candidate.kind == "Badge"
    assert Enum.all?([e, b, source, engine], &(&1.role == :node and &1.authority == []))
    assert bundle.role == :operator
    assert bundle.authority == ["admission-16", "admission-17"]
    refute "recurse.r5e.io/v1alpha1/PolicyBundle" in bundle.candidate.spec["governs"]
    assert {:ok, rerun} = Bootstrap.run(driver)
    assert Enum.all?(rerun, &(&1.status == :existing))
    assert Agent.get(state, & &1.writes) == writes
  end

  test "divergent resource conflicts and uncertain write stops without retry" do
    {driver, state} = driver()

    conflict = fn
      :current_resource, _ -> {:ok, %{"spec" => %{"different" => true}}}
      op, payload -> driver.(op, payload)
    end

    assert {:error, {:conflict, _, _, _}} = Bootstrap.run(conflict)

    uncertain = fn
      :admit, _ -> {:outcome_unknown, :connection_lost}
      op, payload -> driver.(op, payload)
    end

    assert {:outcome_unknown, :connection_lost} = Bootstrap.run(uncertain)
    assert Agent.get(state, & &1.writes) == []
  end

  test "partial CAS admission with absent bytes refuses rerun without duplicate admission" do
    {driver, state} = driver()

    partial = fn
      :put_bytes, payload ->
        {:ok, _receipt} = driver.(:put_bytes, payload)
        Agent.update(state, &%{&1 | bytes: %{}})
        {:error, :storage_failed}

      op, payload ->
        driver.(op, payload)
    end

    assert {:error, :storage_failed} = Bootstrap.run(partial)
    writes = Agent.get(state, & &1.writes)
    assert length(writes) == 19
    assert {:error, :cas_bytes_unavailable} = Bootstrap.run(driver)
    assert Agent.get(state, & &1.writes) == writes
    {:put_bytes, source} = List.last(writes)

    Agent.update(
      state,
      &%{&1 | bytes: Map.put(&1.bytes, source.candidate.spec["address"], "corrupt")}
    )

    assert {:error, :cas_bytes_mismatch} = Bootstrap.run(driver)
    assert Agent.get(state, & &1.writes) == writes

    Agent.update(
      state,
      &%{&1 | bytes: Map.put(&1.bytes, source.candidate.spec["address"], source.bytes)}
    )

    assert {:ok, rows} = Bootstrap.run(driver)
    assert Enum.at(rows, 18).status == :existing
    assert length(Agent.get(state, & &1.writes)) == 21
  end

  test "manifest digest and filename checked before any driver call" do
    dir = Path.join(System.tmp_dir!(), "recurse-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    driver = fn _, _ -> flunk("driver called before manifest verification") end

    for file <- ["base.cedar", "../base.cedar"] do
      File.write!(Path.join(dir, "base.cedar"), "tampered")

      File.write!(
        Path.join(dir, "bundle.json"),
        Jason.encode!(%{"engine" => "cedar", "sources" => [%{"file" => file, "sha256" => "bad"}]})
      )

      assert {:error, :invalid_policy_manifest} = Bootstrap.run(driver, policy_dir: dir)
    end
  end
end
