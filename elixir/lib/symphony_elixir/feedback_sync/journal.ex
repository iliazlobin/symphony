defmodule SymphonyElixir.FeedbackSync.Journal do
  @moduledoc "Private, locked delivery intents. An uncertain POST intent is never discarded or retried."

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

  @spec open(Path.t()) :: {:ok, map()} | {:error, atom()}
  def open(root) do
    with true <- is_binary(root) and Path.type(root) == :absolute,
         {:ok, ^root} <- PathSafety.canonicalize(root),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         {:ok, lock} <- lock(root) do
      case load(Path.join(root, "deliveries.json")) do
        {:ok, records} ->
          {:ok, %{root: root, lock: lock, records: records}}

        error ->
          close(%{lock: lock})
          error
      end
    else
      _ -> {:error, :feedback_journal_unavailable}
    end
  end

  @spec close(map()) :: :ok
  def close(%{lock: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  @spec put(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def put(journal, key, record) do
    records = Map.put(journal.records, key, record)

    with true <- owned?(journal),
         true <- valid_records?(records),
         {:ok, bytes} <- Jason.encode(%{"version" => 1, "records" => records}),
         true <- byte_size(bytes) <= 2_000_000,
         :ok <- persist(journal.root, bytes) do
      {:ok, %{journal | records: records}}
    else
      _ -> {:error, :feedback_journal_unavailable}
    end
  end

  @spec owned?(map()) :: boolean()
  def owned?(%{lock: port}) when is_port(port), do: Port.info(port, :connected) == {:connected, self()}
  def owned?(_journal), do: false

  defp load(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %{type: :regular, size: size}} when size <= 2_000_000 ->
        with {:ok, bytes} <- File.read(path),
             {:ok, %{"version" => 1, "records" => records}} <- Jason.decode(bytes),
             true <- valid_records?(records),
             :ok <- File.chmod(path, 0o600) do
          {:ok, records}
        else
          _ -> {:error, :feedback_journal_unavailable}
        end

      _ ->
        {:error, :feedback_journal_unavailable}
    end
  end

  defp valid_records?(records) when is_map(records) and map_size(records) <= 2_000 do
    Enum.all?(records, fn {key, record} ->
      hash?(key) and valid_record?(record)
    end)
  end

  defp valid_records?(_), do: false
  defp valid_record?(%{"state" => "pending", "comment_id" => nil, "hash" => nil}), do: true
  defp valid_record?(%{"state" => "confirmed", "comment_id" => id, "hash" => digest}), do: is_integer(id) and id > 0 and hash?(digest)
  defp valid_record?(_), do: false
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

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
          {:error, :feedback_journal_locked}
      after
        5_000 ->
          close(%{lock: port})
          {:error, :feedback_journal_unavailable}
      end
    else
      {:error, :feedback_journal_unavailable}
    end
  end

  defp persist(root, bytes) do
    path = Path.join(root, "deliveries.json")
    tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".tmp"

    result =
      with {:ok, ^root} <- PathSafety.canonicalize(root),
           false <- match?({:ok, %{type: :symlink}}, File.lstat(path)),
           {:ok, file} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]) do
        result = with :ok <- File.chmod(tmp, 0o600), :ok <- :file.write(file, bytes), do: :file.sync(file)
        :file.close(file)
        with :ok <- result, :ok <- File.rename(tmp, path), do: sync_directory(root)
      end

    File.rm(tmp)
    if result == :ok, do: :ok, else: {:error, :feedback_journal_unavailable}
  end

  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      result = :file.sync(file)
      :file.close(file)
      result
    end
  end
end
