defmodule SymphonyElixir.Design.Store do
  @moduledoc "Owns one project Design journal; reviewed designs never authorize task execution."
  use GenServer

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
  def save(project, expected_version, scene, auth, server \\ __MODULE__), do: call(server, {:save, project, expected_version, scene, auth})

  @spec review(String.t(), non_neg_integer(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def review(project, expected_version, auth, server \\ __MODULE__), do: call(server, {:review, project, expected_version, auth})

  @spec reviewed(String.t(), String.t(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def reviewed(project, ref, auth, server \\ __MODULE__), do: call(server, {:reviewed, project, ref, auth})

  @doc "Captures the current draft and one immutable review in the same owner operation."
  @spec source(String.t(), String.t(), term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def source(project, ref, auth, server \\ __MODULE__), do: call(server, {:source, project, ref, auth})

  defp call(server, message) do
    GenServer.call(server, message, 15_000)
  catch
    :exit, _ -> {:error, :design_storage_unavailable}
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

    {:ok, %{project: project, root: root, scope: scope, binding: binding, owner: owner, journal: journal, fault: fault, authorize: Keyword.get(opts, :authorize, &BrowserAuth.authorized?/1)}}
  end

  @impl true
  def handle_call({:read, project, auth}, _from, state), do: operate(state, project, auth, &{:ok, summary(&1), &1})

  def handle_call({:save, project, expected, scene, auth}, _from, state) do
    operate(state, project, auth, &save_scene(&1, project, expected, scene))
  end

  def handle_call({:review, project, expected, auth}, _from, state) do
    operate(state, project, auth, &review_scene(&1, expected))
  end

  def handle_call({:reviewed, project, ref, auth}, _from, state) do
    operate(state, project, auth, fn current ->
      case current.journal["reviews"][ref] do
        nil -> {:error, :design_review_not_found, current}
        record -> {:ok, record, current}
      end
    end)
  end

  def handle_call({:source, project, ref, auth}, _from, state) do
    operate(state, project, auth, fn current ->
      case current.journal["reviews"][ref] do
        nil ->
          {:error, :design_review_not_found, current}

        record ->
          source = %{"draft" => current.journal["draft"], "reviewed" => record, "storage_revision" => current.journal["storage_revision"]}
          {:ok, source, current}
      end
    end)
  end

  @impl true
  def handle_info({port, _message}, %{owner: %{lock: port}} = state), do: {:noreply, %{state | fault: :design_storage_unavailable}}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Persistence.close(state.owner)

  defp save_scene(current, project, expected, scene) do
    with :ok <- expected(current, expected),
         true <- Persistence.valid_scene?(scene, project) or {:error, :invalid_design_scene},
         true <- same_document?(current, scene) or {:error, :design_document_mismatch} do
      if current.journal["draft"] == scene do
        {:ok, summary(current), current}
      else
        journal = current.journal |> Map.put("draft", scene) |> advance()
        persist(current, journal)
      end
    else
      {:error, reason} -> {:error, reason, current}
    end
  end

  defp same_document?(state, scene) do
    is_nil(state.journal["draft"]) or state.journal["draft"]["document_id"] == scene["document_id"]
  end

  defp review_scene(current, expected) do
    with :ok <- expected(current, expected),
         %{} = scene <- current.journal["draft"] do
      ref = Persistence.content_ref(scene)

      if current.journal["reviewed_ref"] == ref do
        {:ok, summary(current), current}
      else
        reviews = Map.put_new(current.journal["reviews"], ref, review_record(scene, ref))
        journal = current.journal |> Map.put("reviews", reviews) |> Map.put("reviewed_ref", ref) |> advance()
        persist(current, journal)
      end
    else
      nil -> {:error, :design_not_saved, current}
      {:error, reason} -> {:error, reason, current}
    end
  end

  defp review_record(scene, ref) do
    %{
      "ref" => ref,
      "document_id" => scene["document_id"],
      "scene_revision" => scene["revision"],
      "reviewed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "scene" => scene
    }
  end

  defp initialize(true, root, project, binding) when is_binary(project) and is_binary(binding) do
    case safe(fn -> Persistence.open(root, project, binding) end, {:error, :design_storage_unavailable}) do
      {:ok, owner, journal} -> {owner, journal, nil}
      {:error, reason} -> {nil, nil, reason}
    end
  end

  defp initialize(_, _, _, _), do: {nil, nil, :design_storage_unavailable}

  defp operate(state, project, auth, action) do
    cond do
      not authorize?(state.authorize, auth) ->
        {:reply, {:error, :unauthorized}, state}

      project != state.project ->
        {:reply, {:error, :design_project_mismatch}, state}

      capture(state.scope, state.project, state.root) != state.binding ->
        {:reply, {:error, :design_scope_changed}, %{state | fault: :design_scope_changed}}

      not is_nil(state.fault) ->
        {:reply, {:error, state.fault}, state}

      true ->
        checked_action(state, action)
    end
  end

  defp checked_action(state, action) do
    case Persistence.check(state.owner) do
      :ok ->
        case action.(state) do
          {:ok, value, updated} -> {:reply, {:ok, value}, updated}
          {:error, reason, updated} -> {:reply, {:error, reason}, updated}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | fault: reason}}
    end
  end

  defp persist(state, journal) do
    case Persistence.put(state.owner, journal) do
      {:ok, owner} ->
        updated = %{state | owner: owner, journal: journal}
        {:ok, summary(updated), updated}

      {:error, :design_storage_full} ->
        {:error, :design_storage_full, state}

      {:error, reason} ->
        {:error, reason, %{state | fault: reason}}
    end
  end

  defp expected(state, version) do
    if is_integer(version) and version >= 0 and version == state.journal["storage_revision"] do
      :ok
    else
      {:error, :stale_design_revision}
    end
  end

  defp advance(journal), do: Map.update!(journal, "storage_revision", &(&1 + 1))

  defp summary(state) do
    reviewed = state.journal["reviews"][state.journal["reviewed_ref"]]

    %{
      "storage_revision" => state.journal["storage_revision"],
      "draft" => state.journal["draft"],
      "reviewed" => if(reviewed, do: Map.delete(reviewed, "scene")),
      "review_count" => map_size(state.journal["reviews"])
    }
  end

  defp authorize?(fun, auth) do
    safe(fn -> fun.(auth) == true end, false)
  end

  defp capture(fun, project, root) do
    safe(
      fn ->
        value = fun.()
        if not is_nil(value), do: Persistence.scope_ref(%{"project" => project, "root" => root, "source" => value})
      end,
      nil
    )
  end

  defp configuration do
    chat = Config.chat_settings()

    %{
      project: TaskIdentity.project_id(Config.settings!().tracker),
      root: if(is_binary(chat.state_path), do: Path.join(chat.state_path, "design")),
      enabled: chat.enabled == true,
      tracker: Orchestrator.tracker_fingerprint(),
      state_path: chat.state_path
    }
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
