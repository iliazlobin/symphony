defmodule SymphonyElixir.Chat.Persistence do
  @moduledoc "Private conversation records with an OS ownership lock and atomic, synced writes."

  alias SymphonyElixir.PathSafety

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

  @spec close(map()) :: :ok
  def close(%{lock: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and String.match?(id, ~r/^[a-f0-9]{32}$/)

  defp load(root) do
    paths = Path.wildcard(Path.join(root, "*.json"))

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
      is_boolean(chat["archived"]) and chat["status"] in ["idle", "running", "error", "interrupted"]
  end

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
      port = Port.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, args: ["-u", "-c", @lock_script, path], line: 128])

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
