defmodule SymphonyElixir.Specification.Object do
  @moduledoc "Closed, typed Design objects. One schema owns defaults, forms and validation."
  alias SymphonyElixir.Specification.Document

  @states ~w(draft designed target implemented verified deferred)
  @priorities ~w(unspecified must should could)
  @link_roles ~w(uses realizes validates informs depends_on)
  @types ~w(string bool int64 uint32 uint64 double timestamp json uuid bytes enum reference)

  @spec states() :: [String.t()]
  def states, do: @states
  @spec priorities() :: [String.t()]
  def priorities, do: @priorities

  @spec fields(String.t()) :: [map()]
  def fields("goal"), do: [text("audience", "People"), text("outcome", "Outcome")]
  def fields("scope"), do: [text("boundary", "Boundary")]
  def fields("assumption"), do: [number("value", "Value"), text("unit", "Unit", 128), text("basis", "Basis")]
  def fields("functional"), do: [text("actor", "Actor"), text("behavior", "Required behavior")]
  def fields("nonfunctional"), do: [choice("category", "Quality", ~w(capacity latency availability consistency security freshness completeness efficiency quality)), text("scope", "Measurement scope")]
  def fields("entity"), do: [reference("owner", "Owned by", ~w(component)), text("invariant", "Invariant")]

  def fields("relationship"),
    do: [
      reference("from", "From", ~w(entity component)),
      reference("to", "To", ~w(entity component)),
      choice("cardinality", "Cardinality", ~w(one_to_one one_to_many many_to_one many_to_many)),
      text("rule", "Relationship rule")
    ]

  def fields("component"), do: [choice("layer", "Role", ~w(client service worker store external)), text("technology", "Technology", 256), text("boundary", "Boundary")]

  def fields("interface"),
    do: [reference("owner", "Component", ~w(component)), choice("protocol", "Protocol", ~w(http sse rpc queue internal)), text("operation", "Operation / path", 512), text("access", "Access", 512)]

  def fields("flow"), do: [text("trigger", "Trigger"), text("failure", "Failure / recovery")]
  def fields("decision"), do: [text("choice", "Choice"), text("rationale", "Reason")]
  def fields("question"), do: [text("answer", "Current answer"), text("resolve", "How to resolve")]
  def fields("validation"), do: [choice("method", "Method", ~w(test measurement review probe)), text("scope", "Scope"), text("expected", "Expected result")]
  def fields(_), do: []

  @spec row_fields(String.t(), String.t()) :: [map()]
  def row_fields(_kind, "links"), do: [choice("role", "Relation", @link_roles), reference("target", "Design object", :all)]
  def row_fields(_kind, "sources"), do: [text("label", "Resource", 256), %{key: "url", label: "URL", type: :url, limit: 4096}]

  def row_fields("scope", "rows"), do: [text("topic", "Capability / area", 512), choice("coverage", "Scope", ~w(included excluded))]
  def row_fields("functional", "rows"), do: [text("text", "Acceptance criterion")]

  def row_fields("nonfunctional", "rows"),
    do: [
      text("metric", "Metric", 256),
      choice("operator", "Comparison", ~w(<= >= =)),
      number("target", "Target"),
      text("unit", "Unit", 64),
      choice("percentile", "Percentile", ~w(none p50 p95 p99)),
      text("window", "Window / workload", 512)
    ]

  def row_fields("entity", "rows"),
    do: [
      text("name", "Field", 128),
      choice("type", "Type", @types),
      choice("cardinality", "Presence", ~w(one optional many)),
      choice("role", "Key", ~w(value primary foreign)),
      reference("target", "References", ~w(entity)),
      text("description", "Meaning / constraint", 1024)
    ]

  def row_fields("component", "rows"), do: [text("text", "Responsibility")]
  def row_fields("interface", "rows"), do: [text("name", "Parameter / result", 128), choice("type", "Type", @types), text("description", "Contract", 1024)]
  def row_fields("flow", "rows"), do: [text("title", "Step", 256), reference("component", "Component", ~w(component)), text("input", "Input", 1024), text("output", "Output", 1024)]
  def row_fields("decision", "rows"), do: [text("option", "Alternative", 512), text("tradeoff", "Trade-off")]
  def row_fields("validation", "rows"), do: [text("text", "Check")]
  def row_fields(_, "rows"), do: []

  def row_fields(_, _), do: []

  @spec row_label(String.t()) :: String.t()
  def row_label(kind),
    do:
      Map.get(
        %{
          "scope" => "Scope items",
          "functional" => "Acceptance criteria",
          "nonfunctional" => "Targets",
          "entity" => "Fields",
          "component" => "Responsibilities",
          "interface" => "Contract",
          "flow" => "Steps",
          "decision" => "Alternatives",
          "validation" => "Checks"
        },
        kind,
        "Items"
      )

  @spec new(String.t(), String.t()) :: map()
  def new(id, kind) do
    %{
      "id" => id,
      "kind" => kind,
      "title" => "",
      "body" => "",
      "state" => "draft",
      "priority" => "unspecified",
      "attributes" => defaults(fields(kind)),
      "rows" => [],
      "links" => [],
      "sources" => [],
      "notes" => ""
    }
  end

  @spec row(String.t(), String.t(), String.t()) :: map()
  def row(id, kind, group), do: Map.put(defaults(row_fields(kind, group)), "id", id)

  @spec content?(map()) :: boolean()
  def content?(item) do
    Enum.any?(~w(title body notes), &(String.trim(item[&1]) != "")) or
      values_content?(item["attributes"], fields(item["kind"])) or
      Enum.any?(~w(rows links sources), &member_content?(item, &1))
  end

  defp member_content?(item, group), do: Enum.any?(item[group], &values_content?(&1, row_fields(item["kind"], group)))
  defp values_content?(values, schema), do: Enum.any?(schema, &value_content?(values[&1.key], &1.type))
  defp value_content?(_, :choice), do: false
  defp value_content?(value, :number), do: not is_nil(value)
  defp value_content?(value, _), do: String.trim(value) != ""

  @spec valid?(term(), map()) :: boolean()
  def valid?(item, targets) do
    exact?(item, ~w(id kind title body state priority attributes rows links sources notes)) and
      identifier?(item["id"]) and text?(item["title"], 256) and text?(item["body"], 24_000) and text?(item["notes"], 24_000) and
      item["state"] in @states and item["priority"] in @priorities and
      valid_values?(item["attributes"], fields(item["kind"]), targets) and
      Enum.all?(~w(rows links sources), &valid_rows?(item[&1], row_fields(item["kind"], &1), targets))
  end

  @doc "Form rows may edit values, never type or identity. Nested member identities are exact."
  @spec edit(map(), term()) :: {:ok, map()} | :error
  def edit(item, params) do
    keys = ~w(kind title body state priority attributes rows links sources notes)

    with true <- exact?(params, keys) and params["kind"] == item["kind"],
         {:ok, attributes} <- parse_values(params["attributes"], fields(item["kind"])),
         {:ok, rows} <- edit_rows(item["rows"], params["rows"], row_fields(item["kind"], "rows")),
         {:ok, links} <- edit_rows(item["links"], params["links"], row_fields(item["kind"], "links")),
         {:ok, sources} <- edit_rows(item["sources"], params["sources"], row_fields(item["kind"], "sources")) do
      {:ok, Map.merge(item, Map.merge(params, %{"attributes" => attributes, "rows" => rows, "links" => links, "sources" => sources}))}
    else
      _ -> :error
    end
  end

  @doc "Normalize only empty LiveView markers for fields present in this closed schema."
  @spec normalize(map(), term()) :: term()
  def normalize(item, params) when is_map(params) do
    params = strip(params, ~w(kind title body state priority notes))
    params = Map.update(params, "attributes", nil, &strip(&1, Enum.map(fields(item["kind"]), fn f -> f.key end)))

    Enum.reduce(~w(rows links sources), params, fn group, acc ->
      Map.update(acc, group, %{}, fn
        nil -> %{}
        rows when is_map(rows) -> normalize_members(rows, item["kind"], group)
        other -> other
      end)
    end)
  end

  def normalize(_, params), do: params

  @spec form(map()) :: map()
  def form(item) do
    item = Map.delete(item, "id")
    Enum.reduce(~w(rows links sources), item, fn group, acc -> Map.update!(acc, group, &Map.new(&1, fn r -> {r["id"], Map.delete(r, "id")} end)) end)
  end

  @spec safe_url?(term()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    if text?(url, 4096) and not String.contains?(url, ["\\", " ", "\t", "\n", "\r", <<0>>]) do
      parsed = URI.parse(url)
      parsed.scheme in ~w(http https) and is_binary(parsed.host) and parsed.host != "" and is_nil(parsed.userinfo)
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  def safe_url?(_), do: false

  defp valid_rows?(rows, schema, targets) do
    is_list(rows) and length(rows) <= 100 and (schema != [] or rows == []) and
      Enum.all?(rows, &(is_map(&1) and identifier?(&1["id"]) and valid_values?(Map.delete(&1, "id"), schema, targets)))
  end

  defp valid_values?(values, schema, targets), do: exact?(values, Enum.map(schema, & &1.key)) and Enum.all?(schema, &valid_value?(values[&1.key], &1, targets))
  defp valid_value?(value, %{type: :text, limit: limit}, _), do: text?(value, limit)
  defp valid_value?(value, %{type: :url}, _), do: value == "" or safe_url?(value)
  defp valid_value?(value, %{type: :choice, options: options}, _), do: value in options
  defp valid_value?(value, %{type: :number}, _), do: is_nil(value) or (is_number(value) and abs(value) <= 1_000_000_000_000)
  defp valid_value?("", %{type: :reference}, _), do: true
  defp valid_value?(value, %{type: :reference, kinds: kinds}, targets), do: Map.has_key?(targets, value) and (kinds == :all or targets[value] in kinds)

  defp parse_values(values, schema) do
    if exact?(values, Enum.map(schema, & &1.key)) do
      Enum.reduce_while(schema, {:ok, %{}}, fn field, {:ok, acc} ->
        parse_field(field, values, acc)
      end)
    else
      :error
    end
  end

  defp parse("", :number), do: {:ok, nil}

  defp parse(value, :number) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, compact_number(number)}
      _ -> :error
    end
  end

  defp parse(value, _), do: {:ok, value}

  defp edit_rows(rows, params, schema) do
    if exact?(params, Enum.map(rows, & &1["id"])) do
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        edit_member(row, params, schema, acc)
      end)
    else
      :error
    end
  end

  defp parse_field(field, values, acc) do
    case parse(values[field.key], field.type) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, field.key, value)}}
      :error -> {:halt, :error}
    end
  end

  defp edit_member(row, params, schema, acc) do
    case parse_values(params[row["id"]], schema) do
      {:ok, values} -> {:cont, {:ok, acc ++ [Map.put(values, "id", row["id"])]}}
      :error -> {:halt, :error}
    end
  end

  defp compact_number(number), do: if(abs(number) <= 1_000_000_000_000 and trunc(number) == number, do: trunc(number), else: number)

  defp normalize_members(rows, kind, group) do
    keys = Enum.map(row_fields(kind, group), & &1.key)
    Map.new(rows, fn {id, values} -> {id, strip(values, keys)} end)
  end

  defp strip(values, fields) when is_map(values) do
    Enum.reduce(fields, values, fn key, acc -> if Map.has_key?(acc, key) and acc["_unused_" <> key] == "", do: Map.delete(acc, "_unused_" <> key), else: acc end)
  end

  defp strip(values, _), do: values

  defp defaults(fields), do: Map.new(fields, &{&1.key, default(&1)})
  defp default(%{type: :choice, options: [first | _]}), do: first
  defp default(%{type: :number}), do: nil
  defp default(_), do: ""
  defp text(key, label, limit \\ 4000), do: %{key: key, label: label, type: :text, limit: limit}
  defp number(key, label), do: %{key: key, label: label, type: :number}
  defp choice(key, label, options), do: %{key: key, label: label, type: :choice, options: options}
  defp reference(key, label, kinds), do: %{key: key, label: label, type: :reference, kinds: kinds}
  defp identifier?(value), do: Document.identifier?(value)
  defp text?(value, limit), do: is_binary(value) and String.valid?(value) and byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)) <= limit * 2
  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
