defmodule SymphonyElixir.Chat.Graph do
  @moduledoc """
  A deterministic, read-only graph of retained project, task and feature agents.

  Conversation records own identity; this projection never creates threads, adopts
  workers or grants execution authority. The `supervises` edges form a three-level
  hierarchy. Their reverse `reports_to` edges describe the allowed reporting route,
  not another ownership relationship. Missing parents remain missing.
  """

  alias SymphonyElixir.Chat.{Persistence, Sessions}

  @roles %{"main" => "project", "task" => "task", "pr" => "feature"}

  @type direction :: :supervises | :reports_to

  @spec node_id(String.t()) :: String.t()
  def node_id(conversation_id), do: "agent:" <> conversation_id

  @doc "Export retained conversations; callers must first filter by their authorized project and tracker scope."
  @spec export(map() | [map()]) :: map()
  def export(chats) do
    records = records(chats)
    agents = records |> Enum.filter(&is_nil(&1["alias_of"])) |> Map.new(&{&1["id"], &1})
    parents = Map.new(agents, fn {id, chat} -> {id, parent(chat, agents)} end)

    nodes =
      agents
      |> Enum.map(fn {id, chat} -> node(chat, parents[id], aliases(chat, records)) end)
      |> Enum.sort_by(& &1["id"])

    edges =
      parents
      |> Enum.flat_map(fn
        {_id, nil} -> []
        {id, parent} -> [edge("supervises", parent, id), edge("reports_to", id, parent)]
      end)
      |> Enum.sort_by(& &1["id"])

    %{"version" => 1, "nodes" => nodes, "edges" => edges}
  end

  @doc "Resolve an adjacent graph relationship using canonical conversation IDs, never historical aliases."
  @spec relationship(map() | [map()], String.t(), String.t()) :: {:ok, direction()} | {:error, :not_related}
  def relationship(chats, source_id, target_id) do
    edge = Enum.find(export(chats)["edges"], &(&1["source"] == node_id(source_id) and &1["target"] == node_id(target_id)))

    case edge do
      %{"type" => "supervises"} -> {:ok, :supervises}
      %{"type" => "reports_to"} -> {:ok, :reports_to}
      _ -> {:error, :not_related}
    end
  end

  defp records(chats) when is_map(chats), do: records(Map.values(chats))

  defp records(chats) do
    chats
    |> Enum.filter(&valid_agent?/1)
    |> Enum.group_by(& &1["id"])
    |> Enum.flat_map(fn {_id, duplicates} -> if length(Enum.uniq(duplicates)) == 1, do: [hd(duplicates)], else: [] end)
  end

  defp valid_agent?(chat) when is_map(chat) do
    Persistence.valid_id?(chat["id"]) and nonempty?(chat["project_id"]) and nonempty?(chat["tracker_fingerprint"]) and
      is_nil(chat["kind"]) and valid_binding?(chat)
  end

  defp valid_agent?(_), do: false

  defp valid_binding?(%{"conversation_role" => "main"} = chat), do: is_nil(chat["task_id"]) and is_nil(chat["session_id"])

  defp valid_binding?(%{"conversation_role" => "task"} = chat), do: valid_task?(chat) and is_nil(chat["session_id"])
  defp valid_binding?(%{"conversation_role" => "pr"} = chat), do: valid_task?(chat) and Sessions.valid_id?(chat["session_id"])
  defp valid_binding?(_), do: false

  defp valid_task?(chat), do: is_binary(chat["task_id"]) and Persistence.valid_task_scope?(chat["project_id"], chat["task_id"])

  defp parent(%{"conversation_role" => "main"}, _agents), do: nil

  defp parent(chat, agents) do
    expected = if chat["conversation_role"] == "task", do: "main", else: "task"
    task_id = if expected == "task", do: chat["task_id"]

    candidates =
      agents
      |> Map.values()
      |> Enum.filter(&(&1["conversation_role"] == expected and same_scope?(&1, chat) and &1["task_id"] == task_id))

    case candidates do
      [candidate] -> if is_nil(chat["parent_id"]) or chat["parent_id"] == candidate["id"], do: candidate["id"]
      _ -> nil
    end
  end

  defp same_scope?(left, right), do: left["project_id"] == right["project_id"] and left["tracker_fingerprint"] == right["tracker_fingerprint"]

  defp aliases(chat, records) do
    records
    |> Enum.filter(&(&1["alias_of"] == chat["id"] and same_scope?(&1, chat) and &1["conversation_role"] == chat["conversation_role"] and &1["task_id"] == chat["task_id"]))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp node(chat, parent, aliases) do
    role = @roles[chat["conversation_role"]]

    %{
      "id" => node_id(chat["id"]),
      "type" => "agent",
      "role" => role,
      "name" => name(chat, role),
      "conversation_id" => chat["id"],
      "project_id" => chat["project_id"],
      "task_id" => chat["task_id"],
      "session_id" => chat["session_id"],
      "agent_session_id" => agent_session_id(chat),
      "work_id" => work_id(chat),
      "pr_number" => pr_number(chat),
      "parent_id" => if(parent, do: node_id(parent)),
      "status" => chat["status"],
      "goal" => chat["agent_goal"],
      "archived" => chat["archived"] == true,
      "aliases" => aliases
    }
  end

  defp name(chat, role) do
    base = if nonempty?(chat["agent_name"]), do: chat["agent_name"], else: fallback_name(chat, role)
    base <> " " <> role <> " agent"
  end

  defp fallback_name(chat, "project"), do: chat["project_id"]
  defp fallback_name(chat, _role), do: chat["title"] || chat["task_id"]

  defp agent_session_id(%{"conversation_role" => "pr"} = chat) do
    if Sessions.valid_id?(chat["agent_session_id"]), do: chat["agent_session_id"], else: chat["session_id"]
  end

  defp agent_session_id(_chat), do: nil

  defp work_id(chat) do
    case agent_session_id(chat) do
      "work:" <> id -> id
      _ -> nil
    end
  end

  defp pr_number(%{"conversation_role" => "pr", "session_id" => "pr:" <> number}), do: String.to_integer(number)
  defp pr_number(%{"conversation_role" => "pr", "pr_number" => number}) when is_integer(number) and number > 0, do: number
  defp pr_number(_chat), do: nil

  defp edge(type, source, target) do
    %{"id" => type <> ":" <> source <> ":" <> target, "type" => type, "source" => node_id(source), "target" => node_id(target)}
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
