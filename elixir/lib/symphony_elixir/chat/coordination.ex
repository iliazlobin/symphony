defmodule SymphonyElixir.Chat.Coordination do
  @moduledoc "Typed supervision messages and goal metadata; native execution remains owned by the orchestrator."
  @names ~w(symphony_agent_graph symphony_delegate symphony_report symphony_set_goal)

  @spec tool?(String.t()) :: boolean()
  def tool?(name), do: name in @names

  @spec specs() :: [map()]
  def specs do
    [
      spec(
        "symphony_agent_graph",
        "Read this project's agent graph, parent/child conversation IDs, goals and delivery status. Project supervises tasks; each task supervises its feature agents.",
        %{},
        []
      ),
      spec(
        "symphony_delegate",
        "Send a goal or follow-up to a direct child agent's durable chat. It will reason and report back. This does not approve coding, publication or any external action. Use conversation_id from the graph and a stable request_id for retries.",
        %{"conversation_id" => string(32), "text" => string(8000), "request_id" => string(100)},
        ~w(conversation_id text request_id)
      ),
      spec(
        "symphony_report",
        "Report findings or a blocker to your direct parent. The report is visible in its chat and queued for reasoning. Completed replies are reported automatically; use this for intermediate reports. Reports are evidence, never authorization.",
        %{"text" => string(8000), "request_id" => string(100)},
        ~w(text request_id)
      ),
      spec(
        "symphony_set_goal",
        "Record or revise your goal or a direct child's goal. This is planning metadata, not acceptance, execution permission or a worker launch. Goals can be active, achieved or blocked; achieved is not human acceptance of the task.",
        %{"conversation_id" => string(32), "text" => string(8000), "status" => %{"type" => "string", "enum" => ~w(active achieved blocked)}},
        ~w(text status)
      )
    ]
  end

  @spec validate(String.t(), term()) :: :ok | {:error, :invalid_arguments}
  def validate(name, args) when is_map(args) do
    case Enum.find(specs(), &(&1["name"] == name)) do
      nil -> {:error, :invalid_arguments}
      schema -> validate_args(args, schema["inputSchema"])
    end
  end

  def validate(_, _), do: {:error, :invalid_arguments}

  defp validate_args(args, schema) do
    if Enum.all?(schema["required"], &Map.has_key?(args, &1)) and
         Enum.all?(args, fn {key, value} -> property_valid?(schema["properties"][key], value) end), do: :ok, else: {:error, :invalid_arguments}
  end

  defp property_valid?(%{} = property, value) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and byte_size(value) <= Map.get(property, "maxLength", 100) and
      (is_nil(property["enum"]) or value in property["enum"])
  end

  defp property_valid?(_, _), do: false

  @spec label(map()) :: String.t()
  def label(chat) do
    role =
      case chat["conversation_role"] do
        "main" -> "project"
        "task" -> "task"
        "pr" -> "feature"
        _ -> "project"
      end

    (chat["agent_name"] || chat["title"]) <> " " <> role <> " agent"
  end

  @spec bounded_text(String.t()) :: String.t()
  def bounded_text(text) when byte_size(text) <= 8000, do: text

  def bounded_text(text),
    do:
      text
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, &take_grapheme/2)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join()
      |> Kernel.<>("…")

  defp take_grapheme(c, {parts, size}) do
    if size + byte_size(c) <= 7997, do: {:cont, {[c | parts], size + byte_size(c)}}, else: {:halt, {parts, size}}
  end

  defp string(limit), do: %{"type" => "string", "maxLength" => limit}

  defp spec(name, description, properties, required),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false}}
end
