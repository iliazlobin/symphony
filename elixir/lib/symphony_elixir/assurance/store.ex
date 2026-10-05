defmodule SymphonyElixir.Assurance.Store do
  @moduledoc "One private project ledger for requirements, immutable baselines and bound evidence."
  use GenServer

  alias SymphonyElixir.Assurance.{Contract, GraphSnapshot, Projection}
  alias SymphonyElixir.{Config, Orchestrator, TaskIdentity}
  alias SymphonyElixir.Design.Persistence
  alias SymphonyElixirWeb.BrowserAuth

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec read(String.t(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def read(project, auth, server \\ __MODULE__), do: call(server, {:read, project, auth})

  @spec save(String.t(), non_neg_integer(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def save(project, revision, document, auth, server \\ __MODULE__), do: call(server, {:save, project, revision, document, auth})

  @spec baseline(String.t(), non_neg_integer(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def baseline(project, revision, auth, server \\ __MODULE__), do: call(server, {:baseline, project, revision, nil, auth})

  @spec baseline_graph(String.t(), non_neg_integer(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def baseline_graph(project, revision, graph, auth, server \\ __MODULE__), do: call(server, {:baseline, project, revision, graph, auth})

  @spec reviewed(String.t(), String.t(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def reviewed(project, ref, auth, server \\ __MODULE__), do: call(server, {:reviewed, project, ref, auth})

  @spec diff(String.t(), String.t(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def diff(project, ref, auth, server \\ __MODULE__), do: call(server, {:diff, project, ref, auth})

  @spec projection(String.t(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def projection(project, observations, auth, server \\ __MODULE__), do: call(server, {:projection, project, observations, auth})

  @doc "Records an operator declaration. Its claimed origin never becomes native evidence."
  @spec evidence(String.t(), non_neg_integer(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def evidence(project, revision, record, auth, server \\ __MODULE__), do: call(server, {:evidence, project, revision, record, :manual, auth})

  @doc "Trusted host import; verifies each exact observation through the owner callback."
  @spec observe(String.t(), non_neg_integer(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def observe(project, revision, record, auth, server \\ __MODULE__), do: call(server, {:evidence, project, revision, record, :observed, auth})

  @spec release(String.t(), non_neg_integer(), map(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def release(project, revision, record, auth, server \\ __MODULE__), do: call(server, {:release, project, revision, record, auth})

  defp call(server, message) do
    GenServer.call(server, message, 15_000)
  catch
    :exit, _ -> {:error, :assurance_storage_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    configured = safe(&configuration/0, %{project: nil, root: nil, enabled: false})
    project = Keyword.get(opts, :project, configured.project)
    root = Keyword.get(opts, :state_dir, configured.root)
    enabled = Keyword.get(opts, :enabled, Keyword.has_key?(opts, :state_dir) or configured.enabled)
    scope = Keyword.get(opts, :scope, &configuration/0)
    binding = capture(scope, project, root)
    {owner, journal, fault} = initialize(enabled, root, project, binding)

    {:ok,
     %{
       project: project,
       root: root,
       scope: scope,
       binding: binding,
       owner: owner,
       journal: journal,
       fault: fault,
       authorize: Keyword.get(opts, :authorize, &BrowserAuth.authorized?/1),
       verify_evidence: Keyword.get(opts, :verify_evidence, &SymphonyElixirWeb.AssuranceObservations.verify/2)
     }}
  end

  @impl true
  def handle_call({:read, project, auth}, _from, state), do: operate(state, project, auth, &{:ok, summary(&1), &1})

  def handle_call({:save, project, expected, document, auth}, _from, state) do
    operate(state, project, auth, fn current ->
      with :ok <- expected(current, expected), :ok <- valid_document(document, project) do
        update(current, "draft", document)
      else
        {:error, reason} -> {:error, reason, current}
      end
    end)
  end

  def handle_call({:baseline, project, expected, graph, auth}, _from, state), do: operate(state, project, auth, &baseline_document(&1, expected, graph))

  def handle_call({:reviewed, project, ref, auth}, _from, state) do
    operate(state, project, auth, fn current ->
      case current.journal["baselines"][ref] do
        nil -> {:error, :assurance_baseline_not_found, current}
        record -> {:ok, record, current}
      end
    end)
  end

  def handle_call({:diff, project, ref, auth}, _from, state) do
    operate(state, project, auth, &document_diff(&1, ref))
  end

  def handle_call({:projection, project, observations, auth}, _from, state) do
    operate(state, project, auth, &{:ok, Projection.build(&1.journal, observations), &1})
  end

  def handle_call({:evidence, project, expected, record, mode, auth}, _from, state), do: operate(state, project, auth, &record_evidence(&1, expected, record, mode))
  def handle_call({:release, project, expected, record, auth}, _from, state), do: operate(state, project, auth, &record_release(&1, expected, record))

  @impl true
  def handle_info({port, _}, %{owner: %{lock: port}} = state), do: {:noreply, %{state | fault: :assurance_storage_unavailable}}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: Persistence.close(state.owner)

  defp baseline_document(state, expected, graph) do
    with :ok <- expected(state, expected),
         %{} = document <- state.journal["draft"],
         true <- Contract.reviewable?(document) or {:error, :assurance_plan_incomplete},
         {:ok, snapshot} <- snapshot(graph, state.project) do
      ref = Contract.baseline_ref(document, snapshot)

      if state.journal["reviewed_ref"] == ref do
        {:ok, summary(state), state}
      else
        record = %{"ref" => ref, "reviewed_at" => now(), "document" => document, "graph_snapshot" => snapshot}
        journal = state.journal |> Map.update!("baselines", &Map.put_new(&1, ref, record)) |> Map.put("reviewed_ref", ref)
        persist(state, journal)
      end
    else
      nil -> {:error, :assurance_not_saved, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp record_evidence(state, expected, record, mode) do
    record = if is_map(record) and mode == :manual, do: Map.put(record, "origin", "manual"), else: record

    with :ok <- expected(state, expected),
         true <- Contract.valid_evidence?(record) or {:error, :invalid_assurance_evidence},
         true <- evidence_scope?(state, record) or {:error, :assurance_evidence_scope_mismatch},
         true <- verified?(state, record, mode) or {:error, :assurance_evidence_not_observable} do
      append(state, "evidence", record["id"], record)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp record_release(state, expected, record) do
    with :ok <- expected(state, expected),
         true <- Contract.valid_release?(record) or {:error, :invalid_assurance_release},
         true <- Map.has_key?(state.journal["baselines"], record["baseline_ref"]) or {:error, :assurance_baseline_not_found},
         true <- Enum.all?(record["evidence_ids"], &Map.has_key?(state.journal["evidence"], &1)) or {:error, :assurance_evidence_not_found} do
      existing = state.journal["releases"][record["id"]]
      wrapper = if existing && existing["record"] == record, do: existing, else: %{"id" => record["id"], "ref" => Contract.ref(record), "created_at" => now(), "record" => record}
      append(state, "releases", record["id"], wrapper)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp evidence_scope?(state, record) do
    criterion_ids = (state.journal["draft"] || Contract.document(state.project)) |> Contract.criteria() |> Enum.map(& &1["id"])

    (is_nil(record["criterion_id"]) or record["criterion_id"] in criterion_ids) and
      (not String.starts_with?(state.project, "github:") or record["subject"]["repository"] == String.replace_prefix(state.project, "github:", ""))
  end

  defp verified?(_state, _record, :manual), do: true
  defp verified?(state, record, :observed), do: record["origin"] in ~w(native github) and safe(fn -> state.verify_evidence.(state.project, record) == true end, false)

  defp append(state, field, key, value) do
    case state.journal[field][key] do
      nil -> update(state, field, Map.put(state.journal[field], key, value))
      ^value -> {:ok, summary(state), state}
      _ -> {:error, :assurance_record_conflict, state}
    end
  end

  defp update(state, field, value) do
    if state.journal[field] == value, do: {:ok, summary(state), state}, else: persist(state, Map.put(state.journal, field, value))
  end

  defp persist(state, journal) do
    journal = Map.update!(journal, "storage_revision", &(&1 + 1))

    if Contract.valid?(journal, state.project, state.binding) do
      case Persistence.put(state.owner, journal) do
        {:ok, owner} ->
          updated = %{state | owner: owner, journal: journal}
          {:ok, summary(updated), updated}

        {:error, :design_storage_full} ->
          {:error, :assurance_storage_full, state}

        _ ->
          {:error, :assurance_storage_unavailable, %{state | fault: :assurance_storage_unavailable}}
      end
    else
      {:error, :assurance_storage_full, state}
    end
  end

  defp operate(state, project, auth, action) do
    cond do
      not safe(fn -> state.authorize.(auth) == true end, false) ->
        {:reply, {:error, :unauthorized}, state}

      project != state.project ->
        {:reply, {:error, :assurance_project_mismatch}, state}

      capture(state.scope, state.project, state.root) != state.binding ->
        {:reply, {:error, :assurance_scope_changed}, %{state | fault: :assurance_scope_changed}}

      state.fault != nil ->
        {:reply, {:error, state.fault}, state}

      true ->
        checked_action(state, action)
    end
  end

  defp checked_action(state, action) do
    case Persistence.check(state.owner) do
      :ok -> reply(action.(state))
      _ -> {:reply, {:error, :assurance_storage_unavailable}, %{state | fault: :assurance_storage_unavailable}}
    end
  end

  defp reply({:ok, value, state}), do: {:reply, {:ok, value}, state}
  defp reply({:error, reason, state}), do: {:reply, {:error, reason}, state}
  defp valid_document(document, project), do: if(Contract.valid_document?(document, project), do: :ok, else: {:error, :invalid_assurance_document})

  defp document_diff(current, ref) do
    case current.journal["baselines"][ref] do
      nil ->
        {:error, :assurance_baseline_not_found, current}

      record ->
        diff = Contract.diff(record["document"], current.journal["draft"] || Contract.document(current.project))
        latest = current.journal["baselines"][current.journal["reviewed_ref"]]
        graph_diff = GraphSnapshot.diff(record["graph_snapshot"], if(latest, do: latest["graph_snapshot"]))
        {:ok, Map.put(diff, "graph", graph_diff), current}
    end
  end

  defp expected(state, value), do: if(is_integer(value) and value == state.journal["storage_revision"], do: :ok, else: {:error, :stale_assurance_revision})
  defp snapshot(nil, _project), do: {:ok, nil}
  defp snapshot(graph, project), do: GraphSnapshot.capture(graph, project)

  defp initialize(true, root, project, binding) when is_binary(project) and is_binary(binding) do
    case safe(fn -> Persistence.open(root, project, binding, Contract) end, {:error, :assurance_storage_unavailable}) do
      {:ok, owner, journal} -> {owner, journal, nil}
      _ -> {nil, nil, :assurance_storage_unavailable}
    end
  end

  defp initialize(_, _, _, _), do: {nil, nil, :assurance_storage_unavailable}

  defp summary(state) do
    journal = state.journal

    %{
      "storage_revision" => journal["storage_revision"],
      "draft" => journal["draft"],
      "reviewed" => journal["baselines"][journal["reviewed_ref"]],
      "baselines" => journal["baselines"] |> Map.values() |> Enum.sort_by(& &1["reviewed_at"], :desc),
      "evidence" => journal["evidence"] |> Map.values() |> Enum.sort_by(& &1["observed_at"], :desc),
      "releases" => journal["releases"] |> Map.values() |> Enum.sort_by(& &1["created_at"], :desc)
    }
  end

  defp capture(fun, project, root),
    do:
      safe(
        fn ->
          value = fun.()
          if value != nil, do: Persistence.scope_ref(%{"project" => project, "root" => root, "source" => value})
        end,
        nil
      )

  defp configuration do
    chat = Config.chat_settings()

    %{
      project: TaskIdentity.project_id(Config.settings!().tracker),
      root: if(is_binary(chat.state_path), do: Path.join(chat.state_path, "assurance")),
      enabled: chat.enabled == true,
      tracker: Orchestrator.tracker_fingerprint(),
      state_path: chat.state_path
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
