defmodule SymphonyElixir.Chat.Persistence do
  @moduledoc "Private conversation records with an OS ownership lock and atomic, synced writes."

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
    with true <- valid_id?(id),
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
    metadata_valid?(chat) and
      collection?(chat["client_ids"], &is_binary/1) and collection?(chat["context"], &is_map/1) and
      collection?(chat["messages"], &message_valid?/1) and collection?(chat["proposals"], &proposal_valid?/1)
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
      message["role"] in ["user", "assistant"] and collection?(message["widgets"], &is_map/1)
  end

  defp message_valid?(_), do: false

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
