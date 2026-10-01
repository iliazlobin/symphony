defmodule SymphonyElixir.Chat.OpenRouter do
  @moduledoc "Bounded stateless management turns; declared functions execute through the trusted host."

  alias SymphonyElixir.Chat.ViewContext

  @endpoint "https://openrouter.ai/api/v1/chat/completions"
  @max_response 1_048_576
  @max_request 524_288
  @max_text 65_536

  @spec run(map() | keyword(), (tuple() -> any()), (String.t(), map() -> map())) :: {:ok, map()} | {:error, atom()}
  def run(opts, emit, tool) when is_function(emit, 1) and is_function(tool, 2) do
    opts = Map.new(opts)

    with :ok <- validate(opts) do
      state = %{
        opts: opts,
        emit: emit,
        tool: tool,
        messages: messages(opts),
        calls: 0,
        text_bytes: 0,
        tokens: %{"inputTokens" => 0, "outputTokens" => 0, "totalTokens" => 0},
        deadline: now() + Map.get(opts, :timeout_ms, 300_000)
      }

      try do
        turn(state)
      catch
        {:openrouter_error, :interrupted} -> {:ok, %{status: :interrupted}}
        {:openrouter_error, reason} -> {:error, reason}
      end
    end
  end

  defp validate(opts) do
    cond do
      not valid_key?(opts[:api_key]) -> {:error, :authentication_required}
      not valid_model?(opts[:model]) -> {:error, :invalid_model}
      not valid_options?(opts) -> {:error, :invalid_runtime_options}
      not valid_tools?(Map.get(opts, :tools, [])) -> {:error, :invalid_tools}
      not valid_history?(Map.get(opts, :history, [])) -> {:error, :invalid_history}
      not is_function(Map.get(opts, :request, &Req.request/1), 1) -> {:error, :invalid_runtime_options}
      true -> :ok
    end
  end

  defp valid_key?(key), do: bounded?(key, 4_096) and Regex.match?(~r/\A[\x21-\x7E]+\z/, key)

  defp valid_model?(model) do
    bounded?(model, 200) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:>-]*(?:\/[a-zA-Z0-9._:>-]+)+\z/, model)
  end

  defp valid_options?(opts) do
    bounded?(opts[:text], @max_text) and bounded?(opts[:instructions], @max_text) and
      valid_timeout?(Map.get(opts, :timeout_ms, 300_000)) and valid_limit?(Map.get(opts, :max_tool_calls, 8))
  end

  defp bounded?(text, maximum), do: is_binary(text) and String.valid?(text) and String.trim(text) != "" and byte_size(text) <= maximum
  defp valid_timeout?(value), do: is_integer(value) and value in 1..900_000
  defp valid_limit?(value), do: is_integer(value) and value in 1..24

  defp valid_tools?(tools) when is_list(tools) and length(tools) <= 32 do
    names = Enum.map(tools, fn item -> if is_map(item), do: item["name"] end)

    names == Enum.uniq(names) and
      Enum.all?(tools, fn
        %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"} = schema} = item ->
          bounded?(name, 100) and Regex.match?(~r/\Asymphony_[a-z0-9_]+\z/, name) and bounded?(description, 16_384) and Map.get(item, "type", "function") == "function" and valid_schema?(schema)

        _ ->
          false
      end)
  end

  defp valid_tools?(_), do: false

  defp valid_history?(history) when is_list(history) and length(history) <= 80 do
    valid =
      Enum.all?(history, fn
        %{"role" => role, "content" => content} when role in ["user", "assistant"] ->
          is_binary(content) and String.valid?(content) and byte_size(content) <= @max_text

        _ ->
          false
      end)

    valid and Enum.reduce(history, 0, &(&2 + byte_size(&1["content"]))) <= 262_144
  end

  defp valid_history?(_), do: false

  defp messages(opts) do
    text = if Map.has_key?(opts, :view_context), do: opts.text <> "\n\n" <> ViewContext.prompt(opts.view_context), else: opts.text
    history = Enum.map(Map.get(opts, :history, []), &Map.take(&1, ["role", "content"]))
    [%{"role" => "system", "content" => opts.instructions}] ++ history ++ [%{"role" => "user", "content" => text}]
  end

  defp turn(state) do
    checkpoint(state)

    payload = %{
      "model" => state.opts.model,
      "messages" => state.messages,
      "stream" => false,
      "max_tokens" => 8_192,
      "parallel_tool_calls" => false,
      "tools" => Enum.map(Map.get(state.opts, :tools, []), &%{"type" => "function", "function" => %{"name" => &1["name"], "description" => &1["description"], "parameters" => &1["inputSchema"]}})
    }

    body = encode(payload, @max_request)
    request = Map.get(state.opts, :request, &Req.request/1)

    options = [
      method: :post,
      url: @endpoint,
      body: body,
      headers: [{"authorization", "Bearer " <> state.opts.api_key}, {"content-type", "application/json"}],
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: remaining(state),
      finch: [pool_timeout: remaining(state)],
      connect_options: [timeout: remaining(state)],
      into: &receive_body/2
    ]

    response = operation(state, fn -> request.(options) end)
    checkpoint(state)
    consume(response_body(response), state)
  end

  defp receive_body({:data, data}, {request, response}) do
    body = (response.body || "") <> data
    if byte_size(body) > @max_response, do: fail(:protocol_limit)
    {:cont, {request, %{response | body: body}}}
  end

  defp response_body({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body) do
    if byte_size(body) > @max_response, do: fail(:protocol_limit)

    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> result
      _ -> fail(:protocol_error)
    end
  end

  defp response_body({:ok, %Req.Response{status: status}}) when status in [401, 403], do: fail(:authentication_required)
  defp response_body({:ok, %Req.Response{status: 402}}), do: fail(:provider_budget_exhausted)
  defp response_body({:ok, %Req.Response{status: 429}}), do: fail(:provider_rate_limited)
  defp response_body({:ok, %Req.Response{status: status}}) when status >= 500, do: fail(:provider_unavailable)
  defp response_body({:ok, %Req.Response{}}), do: fail(:request_rejected)
  defp response_body({:error, reason}) when reason in [:protocol_limit, :runtime_timeout], do: fail(reason)
  defp response_body(_), do: fail(:provider_unavailable)

  defp consume(%{"error" => _}, _state), do: fail(:model_error)

  defp consume(%{"choices" => [%{"message" => %{"role" => "assistant"} = message, "finish_reason" => reason}]} = response, state) do
    state = usage(response["usage"], state)
    calls = Map.get(message, "tool_calls", [])
    content = message["content"]
    unless is_list(calls) and (is_nil(content) or is_binary(content)), do: fail(:protocol_error)

    case {reason, calls} do
      {"stop", []} ->
        unless bounded?(content, @max_text), do: fail(:empty_response)
        emit_text(content, state)
        {:ok, %{status: :completed}}

      {"tool_calls", [_ | _]} ->
        continue_calls(message, calls, state)

      _ ->
        fail(:turn_failed)
    end
  end

  defp consume(_, _state), do: fail(:protocol_error)

  defp continue_calls(message, calls, state) do
    validated = validate_calls(calls, state)
    state = if is_nil(message["content"]) or message["content"] == "", do: state, else: emit_text(message["content"], state)
    state = %{state | messages: state.messages ++ [Map.take(message, ["role", "content", "tool_calls", "reasoning_details"])]}
    turn(Enum.reduce(validated, state, &execute_tool/2))
  end

  defp validate_calls(calls, state) do
    if state.calls + length(calls) > Map.get(state.opts, :max_tool_calls, 8), do: fail(:tool_limit)
    validated = Enum.map(calls, &validate_call(&1, state))
    ids = Enum.map(validated, & &1.id)
    if ids != Enum.uniq(ids), do: fail(:protocol_error)
    validated
  end

  defp validate_call(%{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => arguments}}, state) do
    spec = Enum.find(Map.get(state.opts, :tools, []), &(&1["name"] == name))

    unless bounded?(id, 200) and is_map(spec) and is_binary(arguments) and byte_size(arguments) <= 16_384 do
      fail(:forbidden_tool)
    end

    case Jason.decode(arguments) do
      {:ok, args} when is_map(args) ->
        unless valid_value?(args, spec["inputSchema"]), do: fail(:invalid_tool_arguments)
        %{id: id, name: name, args: args}

      _ ->
        fail(:invalid_tool_arguments)
    end
  end

  defp validate_call(_, _state), do: fail(:forbidden_tool)

  defp valid_schema?(%{"type" => types} = schema) when is_list(types), do: types != [] and Enum.all?(types, &valid_schema?(Map.put(schema, "type", &1)))

  defp valid_schema?(%{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    is_map(properties) and is_list(required) and Enum.all?(required, &is_binary/1) and
      Enum.all?(properties, fn {name, field} -> is_binary(name) and valid_schema?(field) end)
  end

  defp valid_schema?(%{"type" => "array", "items" => items} = schema), do: nonnegative?(Map.get(schema, "maxItems", 100)) and valid_schema?(items)

  defp valid_schema?(%{"type" => type} = schema) when type in ["string", "integer", "number", "boolean", "null"] do
    (is_nil(schema["enum"]) or is_list(schema["enum"])) and nonnegative?(Map.get(schema, "maxLength", @max_text)) and
      (is_nil(schema["minimum"]) or is_number(schema["minimum"])) and (is_nil(schema["maximum"]) or is_number(schema["maximum"]))
  end

  defp valid_schema?(_), do: false
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp valid_value?(value, %{"type" => types} = schema) when is_list(types), do: Enum.any?(types, &valid_value?(value, Map.put(schema, "type", &1)))

  defp valid_value?(value, %{"type" => "object"} = schema) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    Enum.all?(Map.get(schema, "required", []), &Map.has_key?(value, &1)) and
      Enum.all?(value, fn {key, item} -> if Map.has_key?(properties, key), do: valid_value?(item, properties[key]), else: schema["additionalProperties"] != false end)
  end

  defp valid_value?(value, %{"type" => "string"} = schema) when is_binary(value), do: String.valid?(value) and byte_size(value) <= Map.get(schema, "maxLength", @max_text) and enum?(value, schema)
  defp valid_value?(value, %{"type" => "integer"} = schema) when is_integer(value), do: number?(value, schema)
  defp valid_value?(value, %{"type" => "number"} = schema) when is_number(value), do: number?(value, schema)
  defp valid_value?(value, %{"type" => "boolean"} = schema) when is_boolean(value), do: enum?(value, schema)
  defp valid_value?(nil, %{"type" => "null"}), do: true
  defp valid_value?(value, %{"type" => "array", "items" => items} = schema) when is_list(value), do: length(value) <= Map.get(schema, "maxItems", 100) and Enum.all?(value, &valid_value?(&1, items))
  defp valid_value?(_, _), do: false
  defp number?(value, schema), do: value >= Map.get(schema, "minimum", value) and value <= Map.get(schema, "maximum", value) and enum?(value, schema)
  defp enum?(value, schema), do: is_nil(schema["enum"]) or value in schema["enum"]

  defp execute_tool(call, state) do
    checkpoint(state)
    state.emit.({:status, "Using #{call.name}"})

    result =
      operation(
        state,
        fn ->
          case state.tool.(call.name, call.args) do
            result when is_map(result) -> result
            _ -> %{"error" => "tool_failed"}
          end
        end,
        30_000
      )

    checkpoint(state)
    result = if match?({:error, _}, result), do: %{"error" => "tool_failed"}, else: result
    output = encode(result, @max_text)
    %{state | calls: state.calls + 1, messages: state.messages ++ [%{"role" => "tool", "tool_call_id" => call.id, "content" => output}]}
  end

  defp usage(nil, state), do: state

  defp usage(usage, state) when is_map(usage) do
    last = %{"inputTokens" => usage["prompt_tokens"], "outputTokens" => usage["completion_tokens"], "totalTokens" => usage["total_tokens"]}
    unless Enum.all?(last, fn {_, value} -> is_integer(value) and value >= 0 end), do: fail(:protocol_error)
    total = Map.new(last, fn {key, value} -> {key, state.tokens[key] + value} end)
    state.emit.({:usage, %{"last" => last, "total" => total}})
    %{state | tokens: total}
  end

  defp usage(_, _state), do: fail(:protocol_error)

  defp emit_text(text, state) do
    size = state.text_bytes + byte_size(text)
    unless String.valid?(text) and size <= @max_text, do: fail(:protocol_limit)
    checkpoint(state)
    state.emit.({:delta, text})
    %{state | text_bytes: size}
  end

  defp operation(state, fun, cap \\ 900_000) do
    checkpoint(state)

    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :provider_unavailable}
        catch
          {:openrouter_error, reason} -> {:error, reason}
          _, _ -> {:error, :provider_unavailable}
        end
      end)

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        result

      :interrupt ->
        Task.shutdown(task, :brutal_kill)
        fail(:interrupted)
    after
      min(remaining(state), cap) ->
        Task.shutdown(task, :brutal_kill)
        fail(:runtime_timeout)
    end
  end

  defp checkpoint(state) do
    receive do
      :interrupt -> fail(:interrupted)
    after
      0 -> if remaining(state) == 0, do: fail(:runtime_timeout)
    end
  end

  defp encode(value, limit) do
    case Jason.encode(value) do
      {:ok, bytes} when byte_size(bytes) <= limit -> bytes
      _ -> fail(:protocol_limit)
    end
  end

  defp remaining(state), do: max(state.deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
  defp fail(reason), do: throw({:openrouter_error, reason})
end
