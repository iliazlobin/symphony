defmodule SymphonyElixir.Design.Persistence do
  @moduledoc "Private, bounded native Design journals with exclusive ownership and atomic writes."

  import Bitwise
  alias SymphonyElixir.{PathSafety, ProcessGroup}

  @scene_bytes 4_000_000
  @journal_bytes 32_000_000
  @sections ~w(brief requirements data architecture decisions)
  @types ~w(rectangle diamond ellipse text line arrow freedraw frame)
  @fields %{
    "brief" => "brief",
    "functional" => "requirements",
    "quality" => "requirements",
    "entities" => "data",
    "components" => "architecture",
    "flows" => "architecture",
    "decisions" => "decisions"
  }
  @safe_integer 9_007_199_254_740_991
  @lock_script """
  import fcntl, os, stat, sys
  try:
      fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
  except OSError:
      print('INVALID', flush=True)
      sys.exit(1)
  info = os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o077:
      print('INVALID', flush=True)
      sys.exit(1)
  try:
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
  except BlockingIOError:
      print('LOCKED', flush=True)
      sys.exit(1)
  print('READY', flush=True)
  sys.stdin.buffer.read(1)
  """

  @spec open(Path.t(), String.t(), String.t()) :: {:ok, map(), map()} | {:error, atom()}
  def open(root, project, scope) do
    with :ok <- private_root(root),
         {:ok, port} <- lock(root) do
      owner = %{root: root, lock: port, digest: nil, lock_identity: lock_identity(root)}

      case load(owner, project, scope) do
        {:ok, journal, digest} when not is_nil(owner.lock_identity) ->
          {:ok, %{owner | digest: digest}, journal}

        {:ok, _, _} ->
          close(owner)
          {:error, :design_storage_unavailable}

        error ->
          close(owner)
          error
      end
    end
  end

  @spec check(map()) :: :ok | {:error, :design_storage_unavailable}
  def check(%{root: root, lock: port, digest: digest, lock_identity: identity}) do
    with true <- Port.info(port) != nil,
         :ok <- private_root(root, false),
         true <- lock_identity(root) == identity,
         {:ok, bytes} <- read_bytes(root),
         true <- digest(bytes) == digest do
      :ok
    else
      _ -> {:error, :design_storage_unavailable}
    end
  end

  @spec put(map(), map()) :: {:ok, map()} | {:error, atom()}
  def put(owner, journal) do
    with :ok <- check(owner),
         {:ok, bytes} <- Jason.encode(journal),
         true <- byte_size(bytes) <= @journal_bytes or {:error, :design_storage_full},
         :ok <- persist(owner.root, bytes) do
      {:ok, %{owner | digest: digest(bytes)}}
    else
      {:error, :design_storage_full} = error -> error
      _ -> {:error, :design_storage_unavailable}
    end
  end

  @spec close(map() | nil) :: :ok
  def close(%{lock: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def close(_), do: :ok

  @spec valid_scene?(term(), String.t()) :: boolean()
  def valid_scene?(scene, project) do
    with true <- exact?(scene, ~w(version project document_id revision boards)),
         true <- scene["version"] == 2 and scene["project"] == project,
         true <- bounded?(project, 512) and project != "",
         true <- identifier?(scene["document_id"]) and integer?(scene["revision"]),
         true <- exact?(scene["boards"], @sections),
         true <- json?(scene, 32),
         {:ok, bytes} <- Jason.encode(scene),
         true <- byte_size(bytes) <= @scene_bytes do
      Enum.all?(@sections, &valid_board?(scene["boards"][&1], &1))
    else
      _ -> false
    end
  end

  @doc "Stable content identity; camera position and native editing counters are excluded."
  @spec content_ref(map()) :: String.t()
  def content_ref(scene) do
    boards =
      Map.new(scene["boards"], fn {section, board} ->
        {section, Enum.map(board["elements"], &Map.drop(&1, ~w(version versionNonce updated index)))}
      end)

    digest(Jason.encode!(canonical(["design-native-content-v1", scene["project"], scene["document_id"], boards])))
  end

  @spec scope_ref(term()) :: String.t()
  def scope_ref(scope), do: digest(Jason.encode!(canonical(scope)))

  defp private_root(root, create \\ true)

  defp private_root(root, create) when is_binary(root) do
    with true <- String.valid?(root),
         true <- Path.type(root) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(root),
         true <- canonical == root do
      root_stat(root, File.lstat(root), create)
    else
      _ -> {:error, :design_storage_unavailable}
    end
  end

  defp private_root(_, _), do: {:error, :design_storage_unavailable}

  defp root_stat(root, {:error, :enoent}, true) do
    with :ok <- File.mkdir_p(root), :ok <- File.chmod(root, 0o700) do
      private_root(root, false)
    else
      _ -> {:error, :design_storage_unavailable}
    end
  end

  defp root_stat(_root, {:ok, %{type: :directory, mode: mode}}, _create) when band(mode, 0o077) == 0, do: :ok
  defp root_stat(_, _, _), do: {:error, :design_storage_unavailable}

  defp lock(root) do
    case System.find_executable("python3") do
      nil ->
        {:error, :design_storage_unavailable}

      python ->
        port =
          Port.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, args: ["-u", "-c", @lock_script, Path.join(root, ".owner.lock")], env: ProcessGroup.port_environment(), line: 128])

        receive do
          {^port, {:data, {:eol, "READY"}}} ->
            {:ok, port}

          {^port, {:data, {:eol, "LOCKED"}}} ->
            close(%{lock: port})
            {:error, :design_storage_locked}

          {^port, _} ->
            close(%{lock: port})
            {:error, :design_storage_unavailable}
        after
          5_000 ->
            close(%{lock: port})
            {:error, :design_storage_unavailable}
        end
    end
  end

  defp lock_identity(root) do
    case File.lstat(Path.join(root, ".owner.lock")) do
      {:ok, %{type: :regular, links: 1, mode: mode} = stat} when band(mode, 0o077) == 0 -> {stat.major_device, stat.minor_device, stat.inode}
      _ -> nil
    end
  end

  defp load(owner, project, scope) do
    with {:ok, bytes} <- read_bytes(owner.root), do: decode_journal(bytes, project, scope)
  end

  defp decode_journal(nil, project, scope) do
    {:ok, %{"version" => 1, "project" => project, "scope" => scope, "storage_revision" => 0, "draft" => nil, "reviewed_ref" => nil, "reviews" => %{}}, nil}
  end

  defp decode_journal(bytes, project, scope) do
    with {:ok, journal} <- Jason.decode(bytes), true <- valid_journal?(journal, project, scope) do
      {:ok, journal, digest(bytes)}
    else
      _ -> {:error, :design_storage_unavailable}
    end
  end

  defp read_bytes(root) do
    path = Path.join(root, "journal.json")

    case File.lstat(path) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, %{type: :regular, links: 1, mode: mode, size: size}} when size <= @journal_bytes and band(mode, 0o077) == 0 -> File.read(path)
      _ -> {:error, :design_storage_unavailable}
    end
  end

  defp valid_journal?(journal, project, scope) do
    exact?(journal, ~w(version project scope storage_revision draft reviewed_ref reviews)) and
      journal["version"] == 1 and journal["project"] == project and journal["scope"] == scope and
      integer?(journal["storage_revision"]) and is_map(journal["reviews"]) and
      journal_content?(journal, project)
  end

  defp journal_content?(journal, project) do
    (is_nil(journal["draft"]) or valid_scene?(journal["draft"], project)) and
      (is_nil(journal["reviewed_ref"]) or Map.has_key?(journal["reviews"], journal["reviewed_ref"])) and
      Enum.all?(journal["reviews"], &valid_review?(&1, project, journal["draft"]))
  end

  defp valid_review?({ref, record}, project, draft) do
    exact?(record, ~w(ref document_id scene_revision reviewed_at scene)) and
      is_binary(ref) and String.match?(ref, ~r/\A[a-f0-9]{64}\z/) and record["ref"] == ref and
      valid_review_scene?(record, ref, project, draft)
  end

  defp valid_review_scene?(record, ref, project, draft) do
    valid_scene?(record["scene"], project) and content_ref(record["scene"]) == ref and
      record["document_id"] == record["scene"]["document_id"] and
      record["scene_revision"] == record["scene"]["revision"] and
      is_map(draft) and record["document_id"] == draft["document_id"] and valid_time?(record["reviewed_at"])
  end

  defp valid_time?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, 0} -> true
      _ -> false
    end
  end

  defp valid_time?(_), do: false

  defp valid_board?(board, section) do
    exact?(board, ~w(elements appState)) and is_list(board["elements"]) and length(board["elements"]) <= 500 and
      valid_camera?(board["appState"]) and valid_elements?(board["elements"], section)
  end

  defp valid_camera?(camera) do
    exact?(camera, ~w(scrollX scrollY zoom)) and coordinate?(camera["scrollX"]) and coordinate?(camera["scrollY"]) and
      valid_zoom?(camera["zoom"])
  end

  defp valid_zoom?(zoom), do: exact?(zoom, ["value"]) and number?(zoom["value"]) and zoom["value"] >= 0.05 and zoom["value"] <= 30

  defp valid_elements?(elements, section) do
    ids = Enum.map(elements, fn element -> if is_map(element), do: element["id"] end)
    length(Enum.uniq(ids)) == length(ids) and Enum.all?(elements, &valid_element?(&1, ids, section)) and valid_roles?(elements)
  end

  defp valid_element?(element, ids, section) when is_map(element) do
    bounded?(element["id"], 128) and element["id"] != "" and element["type"] in @types and
      geometry?(element) and valid_tag?(element, section) and
      optional?(element, "groupIds", &strings?/1) and native_content?(element) and bindings?(element, ids)
  end

  defp valid_element?(_, _, _), do: false

  defp geometry?(element) do
    Enum.all?(~w(x y width height angle), &coordinate?(element[&1])) and element["width"] >= 0 and element["height"] >= 0
  end

  defp native_content?(element), do: restoration_types?(element) and text?(element) and points?(element)

  defp restoration_types?(element) do
    restoration_scalars?(element) and restoration_styles?(element) and restoration_shapes?(element)
  end

  defp restoration_scalars?(element) do
    Enum.all?(~w(link index frameId containerId name), fn key -> optional?(element, key, &nullable_string?/1) end) and
      Enum.all?(
        ~w(strokeColor backgroundColor fillStyle strokeStyle strokeSharpness textAlign verticalAlign startArrowhead endArrowhead),
        fn key -> optional?(element, key, &nullable_string?/1) end
      ) and
      Enum.all?(~w(strokeWidth roughness opacity updated), fn key -> optional?(element, key, &nonnegative?/1) end) and
      Enum.all?(~w(fontSize lineHeight), fn key -> optional?(element, key, &positive?/1) end) and
      Enum.all?(~w(version versionNonce), fn key -> optional?(element, key, &integer?/1) end) and
      optional?(element, "seed", fn value -> is_integer(value) and abs(value) <= @safe_integer end)
  end

  defp restoration_styles?(element) do
    Enum.all?(~w(isDeleted locked autoResize simulatePressure elbowed), fn key -> optional?(element, key, &is_boolean/1) end) and
      Enum.all?(~w(startIsSpecial endIsSpecial), &optional?(element, &1, fn value -> is_nil(value) or is_boolean(value) end)) and
      optional?(element, "fontFamily", &(&1 in [1, 2, 3, 4, 5, 6, 7, 8, 9, 100, 1000])) and
      optional?(element, "font", &legacy_font?/1)
  end

  defp restoration_shapes?(element) do
    optional?(element, "customData", fn value -> is_nil(value) or is_map(value) end) and
      optional?(element, "roundness", &roundness?/1)
  end

  defp roundness?(nil), do: true

  defp roundness?(value) do
    is_map(value) and value["type"] in [1, 2, 3] and optional?(value, "value", &(coordinate?(&1) and &1 >= 0))
  end

  defp legacy_font?(value) when is_binary(value) do
    case Float.parse(String.trim_leading(value)) do
      {size, _} -> size > 0
      _ -> false
    end
  end

  defp legacy_font?(_), do: false

  defp valid_tag?(element, section) do
    case element["customData"] do
      nil -> true
      data when is_map(data) -> not Map.has_key?(data, "symphony") or tag_metadata?(data["symphony"], section)
      _ -> false
    end
  end

  defp tag_metadata?(meta, section) do
    subset?(meta, ~w(id role kind field)) and identifier?(meta["id"]) and meta["role"] in ~w(node title body edge edge-label) and
      (meta["role"] != "node" or meta["kind"] in ~w(note component entity)) and optional?(meta, "field", &field?(&1, meta, section))
  end

  defp field?(value, meta, section) do
    meta["role"] == "node" and meta["kind"] == "note" and @fields[value] == section and meta["id"] == "note-" <> value
  end

  defp valid_roles?(elements) do
    tagged = Enum.filter(elements, &(&1["isDeleted"] != true and is_map(get_in(&1, ["customData", "symphony"]))))
    roles = Enum.map(tagged, &{get_in(&1, ["customData", "symphony", "id"]), get_in(&1, ["customData", "symphony", "role"])})
    identities = roles |> Enum.filter(fn {_id, role} -> role in ["node", "edge"] end) |> Enum.map(&elem(&1, 0))
    length(Enum.uniq(roles)) == length(roles) and length(Enum.uniq(identities)) == length(identities) and Enum.all?(tagged, &role_type?/1)
  end

  defp role_type?(element) do
    case get_in(element, ["customData", "symphony", "role"]) do
      "node" -> element["type"] in ~w(rectangle diamond ellipse)
      "edge" -> element["type"] == "arrow"
      role when role in ~w(title body edge-label) -> element["type"] == "text"
    end
  end

  defp text?(%{"type" => "text"} = element), do: bounded?(element["text"], 24_000) and optional?(element, "originalText", &bounded?(&1, 12_000))
  defp text?(_), do: true

  defp points?(element) do
    required_path?(element) and optional?(element, "points", &path_points?/1) and
      optional?(element, "pressures", &pressures?/1) and
      optional?(element, "fixedSegments", &segments?/1)
  end

  defp required_path?(element) do
    (element["type"] not in ~w(line arrow freedraw) or is_list(element["points"])) and
      (element["type"] != "freedraw" or element["simulatePressure"] == true or is_list(element["pressures"]))
  end

  defp path_points?(points), do: is_list(points) and length(points) <= 4_000 and Enum.all?(points, &point?/1)

  defp pressures?(points) do
    is_list(points) and length(points) <= 4_000 and Enum.all?(points, &(number?(&1) and &1 >= 0 and &1 <= 1))
  end

  defp segments?(nil), do: true

  defp segments?(segments) when is_list(segments) and length(segments) <= 4_000 do
    Enum.all?(segments, fn segment -> is_map(segment) and integer?(segment["index"]) and segment["index"] <= 4_000 and point?(segment["start"]) and point?(segment["end"]) end)
  end

  defp segments?(_), do: false

  defp bindings?(element, ids) do
    optional?(element, "boundElements", &bound_elements?(&1, ids)) and
      optional?(element, "boundElementIds", &bound_ids?(&1, ids)) and
      optional?(element, "containerId", fn value -> is_nil(value) or value in ids end) and
      Enum.all?(~w(startBinding endBinding), &optional?(element, &1, fn value -> binding?(value, ids) end))
  end

  defp bound_elements?(nil, _ids), do: true

  defp bound_elements?(value, ids) do
    is_list(value) and Enum.all?(value, &(is_map(&1) and &1["type"] in ["arrow", "text"] and &1["id"] in ids))
  end

  defp bound_ids?(nil, _ids), do: true
  defp bound_ids?(value, ids), do: is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 in ids))

  defp binding?(nil, _ids), do: true

  defp binding?(value, ids) do
    is_map(value) and value["elementId"] in ids and optional?(value, "focus", &coordinate?/1) and
      optional?(value, "gap", &(coordinate?(&1) and &1 >= 0)) and optional?(value, "fixedPoint", &point?/1)
  end

  defp persist(root, bytes) do
    path = Path.join(root, "journal.json")
    tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> ".tmp"

    result =
      with {:ok, file} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]) do
        outcome = with :ok <- File.chmod(tmp, 0o600), :ok <- :file.write(file, bytes), do: :file.sync(file)
        closed = :file.close(file)
        with :ok <- outcome, :ok <- closed, :ok <- File.rename(tmp, path), do: sync_directory(root)
      end

    File.rm(tmp)
    result
  end

  defp sync_directory(root) do
    with {:ok, file} <- :file.open(String.to_charlist(root), [:read, :raw, :directory]) do
      result = :file.sync(file)
      :file.close(file)
      result
    end
  end

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp subset?(value, keys), do: is_map(value) and Enum.all?(Map.keys(value), &(&1 in keys))
  defp optional?(value, key, check), do: not Map.has_key?(value, key) or check.(value[key])

  defp bounded?(value, count) do
    is_binary(value) and String.valid?(value) and byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)) <= count * 2
  end

  defp strings?(value), do: is_list(value) and Enum.all?(value, &bounded?(&1, 128))
  defp identifier?(value), do: is_binary(value) and String.match?(value, ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/)
  defp integer?(value), do: is_integer(value) and value >= 0 and value <= @safe_integer
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
  defp nonnegative?(value), do: number?(value) and value >= 0 and value <= @safe_integer
  defp positive?(value), do: nonnegative?(value) and value > 0
  defp number?(value), do: is_integer(value) or is_float(value)
  defp coordinate?(value), do: number?(value) and abs(value) <= 1_000_000
  defp point?([x, y]), do: coordinate?(x) and coordinate?(y)
  defp point?(_), do: false
  defp json?(_value, depth) when depth < 0, do: false
  defp json?(value, depth) when is_map(value), do: Enum.all?(value, fn {key, item} -> is_binary(key) and json?(item, depth - 1) end)
  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth - 1))
  defp json?(value, _), do: is_nil(value) or is_boolean(value) or is_binary(value) or number?(value)
  defp canonical(value) when is_map(value), do: ["map", value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, item} -> [key, canonical(item)] end)]
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
  defp digest(nil), do: nil
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
