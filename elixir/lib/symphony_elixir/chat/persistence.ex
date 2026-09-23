defmodule SymphonyElixir.Chat.Persistence do
  @moduledoc "Private conversation records with an OS ownership lock and atomic, synced writes."

  alias SymphonyElixir.Chat.{Sessions, ViewContext}
  alias SymphonyElixir.PathSafety

  @preferences_file "presentation.json"

  @lock_script """
  import fcntl, os, sys
  fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
  try:
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
  except BlockingIOError:
      print('LOCKED', flush=True)
      sys.exit(1)
  print('READY', flush=True)
  sys.stdin.buffer.read(1)
  """

  @spec open(Path.t()) :: {:ok, map(), map()} | {:error, atom()}
  def open(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == path,
         :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700),
         {:ok, lock} <- lock(path) do
      case load(path) do
        {:ok, chats} ->
          {:ok, %{path: path, lock: lock}, chats}

        error ->
          close(%{lock: lock})
          error
      end
    else
      {:error, :chat_storage_locked} = error -> error
      _ -> {:error, :chat_storage_unavailable}
    end
  end

  def open(_), do: {:error, :chat_storage_unavailable}

  @spec put(map(), map()) :: :ok | {:error, atom()}
  def put(%{path: root}, %{"id" => id} = chat) do
    with true <- valid_id?(id) and valid_chat?(chat),
         {:ok, bytes} <- Jason.encode(chat),
         true <- byte_size(bytes) <= 8_000_000 do
      persist(Path.join(root, id <> ".json"), bytes)
    else
      _ -> {:error, :chat_storage_unavailable}
    end
  end

  @spec preferences(map()) :: {:ok, map()} | {:error, :chat_preferences_unavailable}
  def preferences(%{path: root}) do
    path = Path.join(root, @preferences_file)

    case File.lstat(path) do
      {:error, :enoent} -> {:ok, %{"version" => 1, "scopes" => %{}}}
      {:ok, %{type: :regular, size: size}} when size <= 8_000_000 -> read_preferences(path)
      _ -> {:error, :chat_preferences_unavailable}
    end
  end

  @spec put_preferences(map(), map()) :: :ok | {:error, :chat_preferences_unavailable}
  def put_preferences(%{path: root}, preferences) do
    with true <- valid_preferences?(preferences),
         {:ok, bytes} <- Jason.encode(preferences),
         true <- byte_size(bytes) <= 8_000_000,
         :ok <- persist(Path.join(root, @preferences_file), bytes) do
      :ok
    else
      _ -> {:error, :chat_preferences_unavailable}
    end
  end

  defp read_preferences(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, preferences} <- Jason.decode(bytes),
         true <- valid_preferences?(preferences) do
      {:ok, preferences}
    else
      _ -> {:error, :chat_preferences_unavailable}
    end
  end

  defp valid_preferences?(%{"version" => 1, "scopes" => scopes} = preferences) when is_map(scopes) and map_size(scopes) <= 500 do
    map_size(preferences) == 2 and Enum.all?(scopes, &valid_preference_scope?/1)
  end

  defp valid_preferences?(_), do: false

  defp valid_preference_scope?({scope, %{"pinned" => pinned, "order" => order} = preferences}) do
    is_binary(scope) and String.match?(scope, ~r/^[a-f0-9]{64}$/) and map_size(preferences) == 2 and
      valid_preference_ids?(pinned) and valid_preference_ids?(order) and Enum.all?(pinned, &(&1 in order))
  end

  defp valid_preference_scope?(_), do: false
  defp valid_preference_ids?(ids), do: is_list(ids) and length(ids) <= 500 and Enum.all?(ids, &valid_id?/1) and Enum.uniq(ids) == ids

  @spec close(map()) :: :ok
  def close(%{lock: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and String.match?(id, ~r/^[a-f0-9]{32}$/)

  @spec conversation_id(String.t(), String.t() | nil, String.t()) :: String.t()
  def conversation_id(project, task_id, fingerprint) do
    :crypto.hash(:sha256, Jason.encode!(["conversation-v1", project, fingerprint, task_id])) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  @spec session_conversation_id(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def session_conversation_id(project, task_id, session_id, fingerprint) do
    :crypto.hash(:sha256, Jason.encode!(["pr-conversation-v1", project, fingerprint, task_id, session_id])) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  @spec valid_task_scope?(String.t(), term()) :: boolean()
  def valid_task_scope?(_project, nil), do: true

  def valid_task_scope?(project, task_id) when is_binary(project) and is_binary(task_id) do
    prefix = project <> ":"
    suffix = String.replace_prefix(task_id, prefix, "")
    pattern = if String.starts_with?(project, "github:"), do: ~r/\A[1-9][0-9]*\z/, else: ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
    String.valid?(task_id) and byte_size(task_id) <= 240 and String.starts_with?(task_id, prefix) and String.match?(suffix, pattern)
  end

  def valid_task_scope?(_, _), do: false

  defp load(root) do
    paths = Path.wildcard(Path.join(root, "*.json")) |> Enum.reject(&(Path.basename(&1) == @preferences_file))

    if length(paths) > 500 do
      {:error, :chat_storage_unavailable}
    else
      Enum.reduce_while(paths, {:ok, %{}}, &load_record/2)
    end
  end

  defp load_record(path, {:ok, acc}) do
    id = Path.basename(path, ".json")

    with true <- valid_id?(id),
         {:ok, %{type: :regular, size: size}} when size <= 8_000_000 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"id" => ^id} = chat} <- Jason.decode(bytes),
         true <- valid_chat?(chat) do
      {:cont, {:ok, Map.put(acc, id, chat)}}
    else
      _ -> {:halt, {:error, :chat_storage_unavailable}}
    end
  end

  defp valid_chat?(chat) do
    metadata_valid?(chat) and hierarchy_valid?(chat) and binding_valid?(chat) and queue_valid?(chat) and
      report_receipts_valid?(chat) and
      collection?(chat["client_ids"], &is_binary/1) and collection?(chat["context"], &is_map/1) and
      collection?(chat["messages"], &message_valid?/1) and collection?(chat["proposals"], &proposal_valid?/1)
  end

  defp hierarchy_valid?(chat) do
    optional_id?(chat["parent_id"]) and optional_id?(chat["alias_of"]) and
      valid_agent_session?(chat) and
      (is_nil(chat["agent_name"]) or bounded_string?(chat["agent_name"], 16_000)) and goal_valid?(chat["agent_goal"]) and
      valid_chains?(Map.get(chat, "agent_chains", %{})) and
      is_list(Map.get(chat, "agent_outbox", [])) and Enum.all?(Map.get(chat, "agent_outbox", []), &outbox_valid?(&1, chat))
  end

  defp valid_agent_session?(%{"agent_session_id" => id} = chat),
    do: is_nil(id) or (chat["conversation_role"] == "pr" and Sessions.valid_id?(id))

  defp valid_agent_session?(_), do: true

  defp valid_chains?(chains) when is_map(chains),
    do: Enum.all?(chains, fn {id, count} -> valid_id?(id) and is_integer(count) and count in 1..24 end)

  defp valid_chains?(_), do: false

  defp optional_id?(nil), do: true
  defp optional_id?(id), do: valid_id?(id)
  defp bounded_string?(value, limit), do: is_binary(value) and String.valid?(value) and byte_size(value) <= limit
  defp goal_valid?(nil), do: true
  defp goal_valid?(goal) when is_map(goal), do: bounded_string?(goal["text"], 8000) and goal["status"] in ~w(active achieved blocked) and valid_id?(goal["set_by"]) and is_binary(goal["updated_at"])
  defp goal_valid?(_), do: false

  defp outbox_valid?(event, chat) when is_map(event) do
    Enum.all?(~w(id source_id target_id root root_chat), &valid_id?(event[&1])) and event["source_id"] == chat["id"] and
      bounded_string?(event["text"], 8000) and bounded_string?(event["source_name"], 16_200) and event["kind"] in ~w(instruction report) and
      event["status"] in ~w(pending delivered) and is_integer(event["depth"]) and event["depth"] in 1..6 and is_binary(event["created_at"])
  end

  defp outbox_valid?(_, _), do: false

  defp binding_valid?(%{"conversation_role" => "pr"} = chat) do
    is_nil(chat["kind"]) and is_binary(chat["task_id"]) and valid_task_scope?(chat["project_id"], chat["task_id"]) and
      Sessions.valid_id?(chat["session_id"]) and
      chat["id"] == session_conversation_id(chat["project_id"], chat["task_id"], chat["session_id"], chat["tracker_fingerprint"])
  end

  defp binding_valid?(%{"conversation_role" => "main"} = chat), do: is_nil(chat["task_id"]) and canonical_binding?(chat)
  defp binding_valid?(%{"conversation_role" => "task"} = chat), do: is_binary(chat["task_id"]) and canonical_binding?(chat)
  defp binding_valid?(chat), do: chat["conversation_role"] in [nil, "legacy"] and is_nil(chat["task_id"]) and is_nil(chat["session_id"])

  defp canonical_binding?(chat) do
    is_nil(chat["session_id"]) and is_nil(chat["kind"]) and valid_task_scope?(chat["project_id"], chat["task_id"]) and
      chat["id"] == conversation_id(chat["project_id"], chat["task_id"], chat["tracker_fingerprint"])
  end

  defp report_receipts_valid?(chat) do
    receipts = Map.get(chat, "pr_report_receipts", %{})

    is_map(receipts) and map_size(receipts) <= 100 and
      Enum.all?(receipts, fn {key, value} -> is_binary(key) and byte_size(key) <= 64 and is_binary(value) and String.match?(value, ~r/\A[a-f0-9]{64}\z/) end) and
      (is_nil(chat["pr_observed_at"]) or (is_binary(chat["pr_observed_at"]) and match?({:ok, _, _}, DateTime.from_iso8601(chat["pr_observed_at"]))))
  end

  defp queue_valid?(chat) do
    queue = Map.get(chat, "queue", [])

    is_boolean(Map.get(chat, "queue_paused", false)) and is_list(queue) and length(queue) <= 20 and
      Enum.all?(queue, &queued_message_valid?(&1, chat["project_id"])) and receipts_valid?(Map.get(chat, "message_receipts", %{})) and
      Enum.uniq_by(queue, & &1["id"]) == queue and Enum.uniq_by(queue, & &1["client_id"]) == queue
  end

  defp receipts_valid?(receipts) when is_map(receipts) do
    Enum.all?(receipts, fn {key, value} -> is_binary(key) and is_binary(value) and String.match?(value, ~r/\A[a-f0-9]{64}\z/) end)
  end

  defp receipts_valid?(_), do: false

  defp queued_message_valid?(%{"role" => "user", "status" => "queued"} = entry, project) do
    message_valid?(entry) and valid_id?(entry["id"]) and queued_metadata_valid?(entry) and
      match?({:ok, _}, ViewContext.validate(entry["view_context"], project))
  end

  defp queued_message_valid?(_, _), do: false

  defp queued_metadata_valid?(entry) do
    is_binary(entry["client_id"]) and byte_size(entry["client_id"]) in 1..128 and byte_size(entry["text"]) in 1..16_000 and
      is_binary(entry["created_at"]) and match?({:ok, _, _}, DateTime.from_iso8601(entry["created_at"]))
  end

  defp metadata_valid?(chat) do
    Enum.all?(~w(project_id title tracker_fingerprint runtime_identity updated_at), &is_binary(chat[&1])) and
      is_boolean(chat["archived"]) and chat["status"] in ["idle", "running", "error", "interrupted"] and record_kind_valid?(chat)
  end

  defp record_kind_valid?(%{"kind" => "board_action", "submission" => %{"args" => %{"action" => "create_task"}}, "proposals" => [%{"action" => "create_task"}]}), do: true

  defp record_kind_valid?(%{
         "kind" => "board_action",
         "submission" => %{"args" => %{"action" => "queue_task", "task_id" => task_id} = args} = submission,
         "proposals" => [%{"action" => "queue_task", "args" => proposal_args}]
       }) do
    map_size(submission) == 1 and map_size(args) == 2 and is_binary(task_id) and String.valid?(task_id) and
      byte_size(task_id) <= 240 and String.match?(task_id, ~r/\A[1-9][0-9]*\z/) and proposal_args == %{"task_id" => task_id}
  end

  defp record_kind_valid?(chat), do: is_nil(chat["kind"])

  defp collection?(items, valid), do: is_list(items) and Enum.all?(items, valid)

  defp message_valid?(message) when is_map(message) do
    Enum.all?(~w(id text status), &is_binary(message[&1])) and
      message["role"] in ["user", "assistant"] and collection?(message["widgets"], &is_map/1) and report_message_valid?(message) and
      agent_message_valid?(message)
  end

  defp message_valid?(_), do: false

  defp agent_message_valid?(%{"origin" => "agent_message"} = message) do
    message["role"] == "user" and Enum.all?(~w(source_agent agent_root agent_root_chat), &valid_id?(message[&1])) and
      bounded_string?(message["source_name"], 16_200) and message["agent_kind"] in ~w(instruction report) and
      is_integer(message["agent_depth"]) and message["agent_depth"] in 1..6
  end

  defp agent_message_valid?(_), do: true

  defp report_message_valid?(%{"origin" => "pr_update"} = message),
    do: message["role"] == "assistant" and message["status"] == "completed" and Sessions.valid_id?(message["session_id"]) and byte_size(message["text"]) <= 8_000

  defp report_message_valid?(_), do: true

  defp proposal_valid?(proposal) when is_map(proposal) do
    valid_id?(proposal["id"]) and is_binary(proposal["action"]) and is_map(proposal["args"]) and
      proposal["status"] in ["pending", "executing", "completed", "cancelled", "unknown", "failed"]
  end

  defp proposal_valid?(_), do: false

  defp lock(root) do
    path = Path.join(root, "owner.lock")
    python = System.find_executable("python3")

    if is_binary(python) and not match?({:ok, %{type: :symlink}}, File.lstat(path)) do
      port = Port.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, args: ["-u", "-c", @lock_script, path], env: SymphonyElixir.ProcessGroup.port_environment(), line: 128])

      receive do
        {^port, {:data, {:eol, "READY"}}} ->
          {:ok, port}

        {^port, _} ->
          close(%{lock: port})
          {:error, :chat_storage_locked}
      after
        5_000 ->
          close(%{lock: port})
          {:error, :chat_storage_unavailable}
      end
    else
      {:error, :chat_storage_unavailable}
    end
  end

  defp persist(path, bytes) do
    tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".tmp"

    result =
      with false <- match?({:ok, %{type: :symlink}}, File.lstat(path)),
           {:ok, file} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]) do
        result = with :ok <- File.chmod(tmp, 0o600), :ok <- :file.write(file, bytes), do: :file.sync(file)
        :file.close(file)
        with :ok <- result, :ok <- File.rename(tmp, path), do: sync_directory(Path.dirname(path))
      end

    File.rm(tmp)
    if result == :ok, do: :ok, else: {:error, :chat_storage_unavailable}
  end

  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      result = :file.sync(file)
      :file.close(file)
      result
    end
  end
end
