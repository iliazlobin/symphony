defmodule SymphonyElixir.Chat.OpenRouterTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Chat.{OpenRouter, Provider, Runtime}
  alias SymphonyElixir.Config.Schema.Chat

  defp opts(extra) do
    Map.merge(%{api_key: "test-key", model: "test/model", text: "Current question", instructions: "Trusted policy", timeout_ms: 2_000}, extra)
  end

  defp response(message \\ %{"role" => "assistant", "content" => "Answer"}, reason \\ "stop", usage \\ nil) do
    %{"choices" => [%{"message" => message, "finish_reason" => reason}], "usage" => usage}
  end

  defp http(body), do: {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}

  defp run(body, extra \\ %{}, tool \\ fn _, _ -> %{"ok" => true} end) do
    owner = self()
    OpenRouter.run(opts(Map.put(extra, :request, fn _ -> http(body) end)), &send(owner, {:event, &1}), tool)
  end

  defp spec(schema \\ %{"type" => "object", "properties" => %{"id" => %{"type" => "integer", "minimum" => 1}}, "required" => ["id"], "additionalProperties" => false}) do
    %{"name" => "symphony_status", "description" => "Read scoped status", "inputSchema" => schema}
  end

  defp call(args \\ %{"id" => 1}, extra \\ %{}), do: Map.merge(%{"id" => "call-1", "type" => "function", "function" => %{"name" => "symphony_status", "arguments" => Jason.encode!(args)}}, extra)
  defp calls(entries, content \\ nil), do: response(%{"role" => "assistant", "content" => content, "tool_calls" => entries}, "tool_calls")

  test "dispatch keeps Codex default and rejects unknown providers" do
    assert {:error, :invalid_provider} = Provider.run(%{provider: "other"}, fn _ -> :ok end, fn _, _ -> %{} end)
    assert {:error, :invalid_runtime_options} = Provider.run(%{}, fn _ -> :ok end, fn _, _ -> %{} end)
    assert {:ok, %{status: :completed}} = run(response(), %{provider: "openrouter"})
    assert {:ok, %{status: :completed}} = Provider.run(opts(%{provider: "openrouter", request: fn _ -> http(response()) end}), fn _ -> :ok end, fn _, _ -> %{} end)
  end

  test "provider maps only OpenRouter diagnostics to provider-specific UI errors" do
    failures = [{401, :openrouter_auth_required}, {429, :openrouter_rate_limited}, {503, :openrouter_unavailable}]

    for {status, expected} <- failures do
      request = fn _ -> {:ok, %Req.Response{status: status}} end
      assert {:error, ^expected} = Provider.run(opts(%{provider: "openrouter", request: request}), fn _ -> :ok end, fn _, _ -> %{} end)
    end

    request = fn _ -> http(calls([call(), call(%{"id" => 2}, %{"id" => "call-2"})])) end
    config = opts(%{provider: "openrouter", tools: [spec()], max_tool_calls: 1, request: request})
    assert {:error, :openrouter_tool_limit} = Provider.run(config, fn _ -> :ok end, fn _, _ -> %{} end)
  end

  test "fixed HTTPS endpoint has no retry or redirect and portable history ignores native IDs" do
    owner = self()

    request = fn options ->
      send(owner, {:request, options, Jason.decode!(options[:body])})
      http(response())
    end

    history = [%{"role" => "user", "content" => "Old question"}, %{"role" => "assistant", "content" => "Old answer", "tool_calls" => [%{"untrusted" => true}]}]
    assert {:ok, %{status: :completed}} = OpenRouter.run(opts(%{request: request, history: history, thread_id: "old-codex-thread", view_context: nil}), &send(owner, {:event, &1}), fn _, _ -> %{} end)
    assert_receive {:request, options, payload}
    assert options[:url] == "https://openrouter.ai/api/v1/chat/completions"
    assert options[:retry] == false
    assert options[:redirect] == false
    assert options[:decode_body] == false
    assert options[:receive_timeout] > 0
    assert options[:finch][:pool_timeout] > 0
    assert options[:finch][:conn_opts][:transport_opts][:timeout] == 30_000
    refute Keyword.has_key?(options, :connect_options)
    assert options[:headers] == [{"authorization", "Bearer test-key"}, {"content-type", "application/json"}]
    assert payload["model"] == "test/model"
    assert payload["parallel_tool_calls"] == false
    assert [system, question, answer, current] = payload["messages"]
    assert system["content"] == "Trusted policy"
    assert question["content"] == "Old question"
    assert answer == %{"role" => "assistant", "content" => "Old answer"}
    assert current["content"] =~ "Current question"
    assert current["content"] =~ ~s("context_status":"unavailable")
    assert_received {:event, {:delta, "Answer"}}
    refute_received {:event, {:thread, _}}
  end

  test "real Req and Finch options accept a bounded local HTTP response" do
    body = Jason.encode!(response())
    owner = self()

    plug = fn conn, _ ->
      send(owner, {:http_request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, body)
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    request = fn options -> Req.request(Keyword.put(options, :url, "http://127.0.0.1:#{port}/fixture")) end

    assert {:ok, %{status: :completed}} = OpenRouter.run(opts(%{request: request}), &send(owner, {:event, &1}), fn _, _ -> %{} end)
    assert_received {:http_request, "POST", "/fixture"}
    assert_received {:event, {:delta, "Answer"}}
  end

  test "sequential declared calls replay exact frames and accumulate usage" do
    owner = self()
    first = calls([call(), call(%{"id" => 2}, %{"id" => "call-2"})], "Checking") |> Map.put("usage", %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5})

    request = fn options ->
      payload = Jason.decode!(options[:body])
      send(owner, {:payload, payload})

      if length(payload["messages"]) == 2,
        do: http(first),
        else: http(response(%{"role" => "assistant", "content" => "Finished"}, "stop", %{"prompt_tokens" => 7, "completion_tokens" => 1, "total_tokens" => 8}))
    end

    tool = fn name, args ->
      send(owner, {:tool, name, args})
      %{"observed" => args["id"]}
    end

    assert {:ok, %{status: :completed}} = OpenRouter.run(opts(%{tools: [spec()], request: request}), &send(owner, {:event, &1}), tool)
    assert_received {:tool, "symphony_status", %{"id" => 1}}
    assert_received {:tool, "symphony_status", %{"id" => 2}}
    assert_received {:payload, %{"messages" => [_, _], "tools" => [%{"type" => "function", "function" => %{"name" => "symphony_status"}}]}}
    assert_received {:payload, %{"messages" => [_, _, assistant, result1, result2]}}
    assert assistant["tool_calls"] == first["choices"] |> hd() |> get_in(["message", "tool_calls"])
    assert assistant["content"] == "Checking"
    assert result1 == %{"role" => "tool", "tool_call_id" => "call-1", "content" => ~s({"observed":1})}
    assert result2["tool_call_id"] == "call-2"
    assert_received {:event, {:usage, %{"total" => %{"totalTokens" => 13}}}}
    assert_received {:event, {:status, "Using symphony_status"}}
    refute_received {:event, {:delta, "Checking"}}
    assert_received {:event, {:delta, "Finished"}}
  end

  test "multiple tool rounds replay preambles and reasoning without appending them to the answer" do
    owner = self()
    reasoning = [%{"type" => "reasoning.encrypted", "data" => "opaque-provider-context"}]
    first = calls([call()], "I will inspect the task.") |> put_in(["choices", Access.at(0), "message", "reasoning_details"], reasoning)
    second = calls([call(%{"id" => 2}, %{"id" => "call-2"})], "I will verify that observation.")

    request = fn options ->
      messages = Jason.decode!(options[:body])["messages"]
      send(owner, {:round, messages})

      case length(messages) do
        2 -> http(first)
        4 -> http(second)
        6 -> http(response(%{"role" => "assistant", "content" => "The task is paused."}))
      end
    end

    assert {:ok, %{status: :completed}} = OpenRouter.run(opts(%{tools: [spec()], request: request}), &send(owner, {:event, &1}), fn _, args -> %{"observed" => args["id"]} end)
    assert_received {:round, [_, _, assistant, result]}
    assert assistant["content"] == "I will inspect the task."
    assert assistant["reasoning_details"] == reasoning
    assert result["tool_call_id"] == "call-1"
    assert_received {:round, [_, _, _, _, assistant2, result2]}
    assert assistant2["content"] == "I will verify that observation."
    assert result2["tool_call_id"] == "call-2"
    assert_received {:event, {:delta, "The task is paused."}}
    refute_received {:event, {:delta, _}}
  end

  test "validates every call before effects, quotas, schemas and malformed arguments" do
    owner = self()

    callback = fn _, _ ->
      send(owner, :executed)
      %{}
    end

    for {entries, extra, reason} <- [
          {[call(), call(%{}, %{"id" => "bad"})], %{}, :invalid_tool_arguments},
          {[call(), call()], %{}, :protocol_error},
          {[call(), call(%{"id" => 2}, %{"id" => "call-2"})], %{max_tool_calls: 1}, :tool_limit},
          {[%{"arbitrary" => "shell"}], %{}, :forbidden_tool},
          {[call(%{"id" => 0})], %{}, :invalid_tool_arguments},
          {[call(%{"id" => 1, "unknown" => true})], %{}, :invalid_tool_arguments},
          {[call(%{}, %{"function" => %{"name" => "undeclared", "arguments" => "{}"}})], %{}, :forbidden_tool},
          {[call(%{}, %{"function" => %{"name" => "symphony_status", "arguments" => "bad-json"}})], %{}, :invalid_tool_arguments},
          {[call(%{}, %{"function" => %{"name" => "symphony_status", "arguments" => "[]"}})], %{}, :invalid_tool_arguments},
          {[call(%{}, %{"function" => %{"name" => "symphony_status", "arguments" => String.duplicate(" ", 16_385)}})], %{}, :forbidden_tool}
        ] do
      assert {:error, ^reason} = run(calls(entries), Map.merge(%{tools: [spec()]}, extra), callback)
    end

    refute_received :executed
  end

  test "schema supports current bounded object, union, array, string, numeric and boolean contracts" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "maxLength" => 5, "enum" => ["valid"]},
        "number" => %{"type" => "number", "minimum" => 0, "maximum" => 2},
        "flag" => %{"type" => "boolean", "enum" => [true]},
        "nullable" => %{"type" => ["integer", "null"]},
        "list" => %{"type" => "array", "items" => %{"type" => "integer"}, "maxItems" => 2}
      },
      "additionalProperties" => true
    }

    valid = %{"text" => "valid", "number" => 1.5, "flag" => true, "nullable" => nil, "list" => [1, 2], "extra" => true}
    owner = self()
    request = fn options -> if length(Jason.decode!(options[:body])["messages"]) == 2, do: http(calls([call(valid)])), else: http(response()) end

    assert {:ok, _} =
             OpenRouter.run(opts(%{tools: [spec(schema)], request: request}), &send(owner, {:event, &1}), fn _, args ->
               assert args == valid
               %{}
             end)

    invalid_values = [
      %{valid | "text" => "invalid"},
      %{valid | "number" => 3},
      %{valid | "flag" => false},
      %{valid | "nullable" => "no"},
      %{valid | "list" => [1, 2, 3]}
    ]

    for invalid <- invalid_values do
      assert {:error, :invalid_tool_arguments} = run(calls([call(invalid)]), %{tools: [spec(schema)]})
    end
  end

  test "input validation refuses credentials, unsafe model identifiers and malformed configuration" do
    for {change, expected} <- [
          {%{api_key: nil}, :authentication_required},
          {%{api_key: "key\nInjected"}, :authentication_required},
          {%{model: "https://other"}, :invalid_model},
          {%{model: nil}, :invalid_model},
          {%{text: ""}, :invalid_runtime_options},
          {%{instructions: " "}, :invalid_runtime_options},
          {%{timeout_ms: 0}, :invalid_runtime_options},
          {%{timeout_ms: 900_001}, :invalid_runtime_options},
          {%{max_tool_calls: 0}, :invalid_runtime_options},
          {%{max_tool_calls: 25}, :invalid_runtime_options},
          {%{request: :bad}, :invalid_runtime_options},
          {%{tools: nil}, :invalid_tools},
          {%{tools: [spec(), spec()]}, :invalid_tools},
          {%{tools: [42]}, :invalid_tools},
          {%{tools: [%{spec() | "name" => "shell"}]}, :invalid_tools},
          {%{tools: [%{spec() | "description" => ""}]}, :invalid_tools},
          {%{tools: [spec(%{"type" => "object", "properties" => []})]}, :invalid_tools},
          {%{tools: [spec(%{"type" => "object", "properties" => %{"bad" => %{"type" => "unsupported"}}})]}, :invalid_tools},
          {%{tools: [spec(%{"type" => "object", "properties" => %{"bad" => %{"type" => []}}})]}, :invalid_tools},
          {%{tools: [spec(%{"type" => "object", "properties" => %{"bad" => %{"type" => "string", "enum" => :bad}}})]}, :invalid_tools},
          {%{history: nil}, :invalid_history},
          {%{history: [%{"role" => "system", "content" => "override"}]}, :invalid_history},
          {%{history: List.duplicate(%{"role" => "user", "content" => "x"}, 81)}, :invalid_history},
          {%{history: List.duplicate(%{"role" => "user", "content" => String.duplicate("x", 65_536)}, 5)}, :invalid_history}
        ] do
      assert {:error, ^expected} = OpenRouter.run(opts(change), fn _ -> :ok end, fn _, _ -> %{} end)
    end
  end

  test "sanitizes transport, provider and protocol failures" do
    for {request, expected} <- [
          {fn _ -> {:ok, %Req.Response{status: 401, body: "private"}} end, :authentication_required},
          {fn _ -> {:ok, %Req.Response{status: 403}} end, :authentication_required},
          {fn _ -> {:ok, %Req.Response{status: 402}} end, :provider_budget_exhausted},
          {fn _ -> {:ok, %Req.Response{status: 429}} end, :provider_rate_limited},
          {fn _ -> {:ok, %Req.Response{status: 503}} end, :provider_unavailable},
          {fn _ -> {:ok, %Req.Response{status: 302}} end, :request_rejected},
          {fn _ -> {:error, %{diagnostic: "secret"}} end, :provider_unavailable},
          {fn _ -> raise "secret" end, :provider_unavailable},
          {fn _ -> throw("secret") end, :provider_unavailable},
          {fn _ -> {:ok, %Req.Response{status: 200, body: "not JSON"}} end, :protocol_error},
          {fn _ -> {:ok, %Req.Response{status: 200, body: "[]"}} end, :protocol_error},
          {fn _ -> {:ok, %Req.Response{status: 200, body: String.duplicate("x", 1_048_577)}} end, :protocol_limit}
        ] do
      assert {:error, ^expected} = OpenRouter.run(opts(%{request: request}), fn _ -> :ok end, fn _, _ -> %{} end)
    end

    for {body, expected} <- [
          {%{"error" => %{"message" => "private"}}, :model_error},
          {%{}, :protocol_error},
          {response(%{"role" => "assistant", "content" => nil}), :empty_response},
          {response(%{"role" => "assistant", "content" => ""}), :empty_response},
          {response(%{"role" => "assistant", "content" => %{}}), :protocol_error},
          {response(%{"role" => "assistant", "content" => "x", "tool_calls" => nil}), :protocol_error},
          {response(%{"role" => "assistant", "content" => "partial"}, "length"), :turn_failed},
          {response(%{"role" => "assistant", "content" => "x"}, "stop", "bad"), :protocol_error},
          {response(%{"role" => "assistant", "content" => "x"}, "stop", %{"prompt_tokens" => -1}), :protocol_error}
        ] do
      assert {:error, ^expected} = run(body)
    end
  end

  test "body collection, request and output stay bounded" do
    request = fn options ->
      {:cont, {_, response}} = options[:into].({:data, Jason.encode!(response())}, {%{}, %Req.Response{body: nil}})
      {:ok, response}
    end

    assert {:ok, _} = OpenRouter.run(opts(%{request: request}), fn _ -> :ok end, fn _, _ -> %{} end)
    large = fn options -> options[:into].({:data, String.duplicate("x", 1_048_577)}, {%{}, %Req.Response{body: nil}}) end
    assert {:error, :protocol_limit} = OpenRouter.run(opts(%{request: large}), fn _ -> :ok end, fn _, _ -> %{} end)
    big_schema = spec(%{"type" => "object", "description" => String.duplicate("x", 524_288)})
    assert {:error, :protocol_limit} = run(response(), %{tools: [big_schema]})
    request = fn options -> if length(Jason.decode!(options[:body])["messages"]) == 2, do: http(calls([call()], String.duplicate("x", 65_536))), else: http(response()) end
    assert {:error, :protocol_limit} = OpenRouter.run(opts(%{tools: [spec()], request: request}), fn _ -> :ok end, fn _, _ -> %{} end)
  end

  test "tool errors are sanitized, and unencodable or huge results fail closed" do
    for callback <- [fn _, _ -> nil end, fn _, _ -> raise "secret" end, fn _, _ -> throw(:private) end] do
      request = fn options ->
        messages = Jason.decode!(options[:body])["messages"]

        if length(messages) == 2 do
          http(calls([call()]))
        else
          assert List.last(messages)["content"] == ~s({"error":"tool_failed"})
          http(response())
        end
      end

      assert {:ok, _} = OpenRouter.run(opts(%{tools: [spec()], request: request}), fn _ -> :ok end, callback)
    end

    for result <- [%{"bad" => self()}, %{"huge" => String.duplicate("x", 65_536)}] do
      assert {:error, :protocol_limit} = run(calls([call()]), %{tools: [spec()]}, fn _, _ -> result end)
    end
  end

  test "interrupt and deadline await request termination before completion" do
    for action <- [:interrupt, :timeout] do
      owner = self()

      request = fn _ ->
        send(owner, {:request_child, self()})

        receive do
          :never -> nil
        end
      end

      task = Task.async(fn -> OpenRouter.run(opts(%{request: request, timeout_ms: 100}), fn _ -> :ok end, fn _, _ -> flunk("tool after cancellation") end) end)
      assert_receive {:request_child, child}
      if action == :interrupt, do: send(task.pid, :interrupt)
      expected = if action == :interrupt, do: {:ok, %{status: :interrupted}}, else: {:error, :runtime_timeout}
      assert Task.await(task) == expected
      refute Process.alive?(child)
    end

    send(self(), :interrupt)
    assert {:ok, %{status: :interrupted}} = run(response())
  end

  test "interrupt stops an active host callback and never starts another" do
    owner = self()

    callback = fn _, _ ->
      send(owner, {:tool_child, self()})

      receive do
        :never -> %{}
      end
    end

    task = Task.async(fn -> OpenRouter.run(opts(%{tools: [spec()], request: fn _ -> http(calls([call(), call(%{"id" => 2}, %{"id" => "call-2"})])) end}), fn _ -> :ok end, callback) end)
    assert_receive {:tool_child, child}
    send(task.pid, :interrupt)
    assert {:ok, %{status: :interrupted}} = Task.await(task)
    refute Process.alive?(child)
    refute_received {:tool_child, _}
  end

  test "queued stop after provider response prevents any tool effect" do
    runtime = self()

    request = fn _ ->
      send(runtime, :interrupt)
      http(calls([call()]))
    end

    assert {:ok, %{status: :interrupted}} = OpenRouter.run(opts(%{tools: [spec()], request: request}), fn _ -> :ok end, fn _, _ -> flunk("stopped tool") end)
  end

  test "owner termination cannot orphan an HTTP operation" do
    owner = self()

    request = fn _ ->
      send(owner, {:request_child, self()})

      receive do
        :never -> nil
      end
    end

    runtime = spawn(fn -> OpenRouter.run(opts(%{request: request}), fn _ -> :ok end, fn _, _ -> %{} end) end)
    assert_receive {:request_child, child}
    monitor = Process.monitor(child)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}
  end

  test "configuration defaults to Codex, requires explicit OpenRouter model and env-only key" do
    assert Chat.changeset(%Chat{}, %{}).valid?
    defaults = Ecto.Changeset.apply_changes(Chat.changeset(%Chat{}, %{}))
    assert %Chat{provider: "codex", model: nil, max_tool_calls: 8} = defaults
    model_options = %{"provider" => "openrouter", "model" => "deepseek/deepseek-v4-flash"}
    assert Chat.changeset(%Chat{}, model_options).valid?
    assert Chat.changeset(%Chat{}, %{"model" => Runtime.model()}).valid?
    refute Chat.changeset(%Chat{}, %{"model" => "different/model"}).valid?
    env_options = %{"provider" => "openrouter", "model" => "$SYMPHONY_TEST_MODEL", "api_key" => "$SYMPHONY_TEST_KEY"}
    assert Chat.changeset(%Chat{}, env_options).valid?

    for invalid <- [
          %{"provider" => "unknown"},
          %{"provider" => "openrouter"},
          %{"api_key" => "literal-secret"},
          %{"model" => "invalid model"},
          %{"model" => String.duplicate("x", 201)},
          %{"max_tool_calls" => 0},
          %{"max_tool_calls" => 25},
          %{"timeout_ms" => 999},
          %{"max_concurrent" => 0}
        ] do
      refute Chat.changeset(%Chat{}, invalid).valid?
    end
  end
end
