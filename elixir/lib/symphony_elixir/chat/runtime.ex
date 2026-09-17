defmodule SymphonyElixir.Chat.Runtime do
  @moduledoc """
  One management conversation turn over a private Codex App Server stdio child.

  The caller owns durable chat identity and runs this blocking function in a
  supervised task. A browser disconnect must not stop that task. Send the task
  `:interrupt` to stop a turn. Only declared dynamic tools are delegated to the
  host; no process, file, MCP, App or coding capabilities are exposed.

  This boundary is pinned to Codex 0.154.0: `environments: []` removes environment
  tools (including apply_patch, which shell_tool=false alone does not remove).
  Codex owns its native history and automatic compaction in a dedicated home.
  """

  alias SymphonyElixir.Chat.ViewContext

  @version "0.154.0"
  @model "gpt-6-astra"
  @max_line 4_194_304
  @disabled ~w(shell_tool unified_exec apply_patch_freeform apps plugins connectors
    remote_plugin remote_control enable_mcp_apps hooks codex_hooks plugin_hooks
    multi_agent multi_agent_v2 collab enable_fanout memories memory_tool chronicle
    external_agent_memory_import external_migration browser_use computer_use
    in_app_browser image_generation imagegenext view_image js_repl
    code_mode_host code_mode_only deferred_executor workspace_dependencies
    request_permissions request_permissions_tool tool_suggest recommended_plugins
    standalone_web_search web_search web_search_cached web_search_request
    shell_snapshot shell_snapshot_v2 goals token_budget sleep_tool)

  @type result :: {:ok, %{thread_id: String.t(), status: :completed | :interrupted}} | {:error, atom()}

  @spec supported_version() :: String.t()
  def supported_version, do: @version

  @spec model() :: String.t()
  def model, do: @model

  @spec run(map() | keyword(), (tuple() -> any()), (String.t(), map() -> map())) :: result()
  def run(opts, emit, tool) when is_function(emit, 1) and is_function(tool, 2) do
    opts = Map.new(opts)

    with :ok <- validate_options(opts) do
      run_child(opts, emit, tool)
    end
  end

  @spec configuration() :: map()
  def configuration do
    Map.new(@disabled, &{"features.#{&1}", false})
    |> Map.merge(%{
      # Astra's model metadata can select CodeModeOnly even when the feature is
      # disabled. Keep our dynamic functions directly callable without starting
      # a JavaScript host or exposing any additional execution capabilities.
      "features.code_mode.enabled" => false,
      "features.code_mode.direct_only_tool_namespaces" => ["functions"],
      "agents.enabled" => false,
      "skills.bundled.enabled" => false,
      "skills.include_instructions" => false,
      "features.skip_host_skill_discovery" => true,
      "tools.update_plan.enabled" => false,
      "tools.experimental_request_user_input.enabled" => false,
      "mcp_servers" => %{},
      "plugins" => %{},
      "apps._default.enabled" => false,
      "web_search" => "disabled",
      "project_doc_max_bytes" => 0,
      "include_environment_context" => false,
      "cli_auth_credentials_store" => "file",
      "approval_policy" => "never",
      "sandbox_mode" => "read-only"
    })
  end

  defp validate_options(opts) do
    with :ok <- validate_values(opts),
         :ok <- validate_paths(opts),
         true <- valid_tools?(Map.get(opts, :tools, [])) do
      :ok
    else
      false -> {:error, :invalid_tools}
      error -> error
    end
  end

  defp validate_values(opts) do
    required = [:executable, :codex_home, :workspace, :text, :instructions]
    timeout = Map.get(opts, :timeout_ms, 300_000)
    if Enum.all?(required, &(is_binary(opts[&1]) and opts[&1] != "")) and is_integer(timeout) and timeout > 0, do: :ok, else: {:error, :invalid_runtime_options}
  end

  defp validate_paths(opts) do
    cond do
      not Enum.all?([:executable, :codex_home, :workspace], &(Path.type(opts[&1]) == :absolute)) -> {:error, :invalid_runtime_options}
      not File.regular?(opts.executable) or not File.dir?(opts.codex_home) or not File.dir?(opts.workspace) -> {:error, :runtime_path_unavailable}
      not dedicated_home?(opts.codex_home) -> {:error, :dedicated_home_required}
      File.ls(opts.workspace) != {:ok, []} -> {:error, :empty_workspace_required}
      true -> :ok
    end
  end

  defp dedicated_home?(home) do
    forbidden = ~w(config.toml AGENTS.md AGENTS.override.md hooks.json plugins .agents)
    skills = File.ls(Path.join(home, "skills"))

    not Enum.any?(forbidden, &File.exists?(Path.join(home, &1))) and
      skills in [{:error, :enoent}, {:ok, []}, {:ok, [".system"]}]
  end

  defp valid_tools?(tools) when is_list(tools) do
    names = Enum.map(tools, &Map.get(&1, "name"))

    length(names) == length(Enum.uniq(names)) and
      Enum.all?(tools, fn tool ->
        is_binary(tool["name"]) and Regex.match?(~r/^symphony_[a-z0-9_]+$/, tool["name"]) and
          is_binary(tool["description"]) and is_map(tool["inputSchema"]) and
          Map.get(tool, "type", "function") == "function"
      end)
  rescue
    _ -> false
  end

  defp valid_tools?(_), do: false

  defp run_child(opts, emit, tool) do
    port = SymphonyElixir.Chat.Process.open(opts.executable, arguments(), opts.workspace, environment(opts.codex_home))

    state = %{
      port: port,
      buffer: "",
      next_id: 1,
      thread_id: nil,
      turn_id: nil,
      emit: emit,
      tool: tool,
      tools: Map.get(opts, :tools, []),
      deadline: now() + Map.get(opts, :timeout_ms, 300_000),
      interrupted: false
    }

    try do
      execute(state, opts)
    catch
      {:runtime_error, reason} -> {:error, reason}
    after
      close(port)
    end
  rescue
    _ -> {:error, :runtime_unavailable}
  end

  defp arguments do
    ["app-server", "--listen", "stdio://"] ++
      Enum.flat_map(configuration(), fn {key, value} -> ["-c", "#{key}=#{toml(value)}"] end)
  end

  defp toml(value) when is_map(value) and map_size(value) == 0, do: "{}"
  defp toml(value), do: Jason.encode!(value)

  defp environment(home) do
    cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
    values = %{"HOME" => home, "CODEX_HOME" => home, "PATH" => "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG" => "en_US.UTF-8"}
    cleared ++ Enum.map(values, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp execute(state, opts) do
    {hello, state} =
      rpc(state, "initialize", %{
        "clientInfo" => %{"name" => "symphony-management", "version" => "0.1.0"},
        "capabilities" => %{"experimentalApi" => true}
      })

    unless is_binary(hello["userAgent"]) and String.contains?(hello["userAgent"], "/#{@version} "),
      do: fail(:unsupported_runtime_version)

    send_message(state, %{"method" => "initialized", "params" => %{}})
    {config, state} = rpc(state, "config/read", %{})
    verify_configuration(config["config"])
    {account, state} = rpc(state, "account/read", %{"refreshToken" => false})
    if account["requiresOpenaiAuth"] != false and is_nil(account["account"]), do: fail(:authentication_required)
    state = require_model(state, nil, 0)

    {method, params} = thread_parameters(state, opts)
    {thread, state} = rpc(state, method, params)

    id = validate_thread(thread, opts)
    state.emit.({:thread, id})
    state = %{state | thread_id: id}

    {turn, state} =
      rpc(state, "turn/start", %{"threadId" => id, "model" => @model, "environments" => [], "approvalPolicy" => "never", "effort" => "medium", "input" => turn_input(opts)})

    turn_id = get_in(turn, ["turn", "id"])
    unless is_binary(turn_id) and turn_id != "", do: fail(:protocol_error)
    await_completion(%{state | turn_id: turn_id})
  end

  defp turn_input(opts) do
    input = [%{"type" => "text", "text" => opts.text}]

    if Map.has_key?(opts, :view_context),
      do: input ++ [%{"type" => "text", "text" => ViewContext.prompt(opts.view_context)}],
      else: input
  end

  defp thread_parameters(state, opts) do
    params = %{
      "model" => @model,
      "cwd" => opts.workspace,
      "approvalPolicy" => "never",
      "sandbox" => "read-only",
      "baseInstructions" => opts.instructions,
      "developerInstructions" =>
        "Call the supplied Symphony management functions directly. The Code Mode host is disabled: do not use exec or wait to call tools. Never execute code, read local files, or infer successful actions without tool evidence.",
      "config" => configuration()
    }

    {method, params} =
      case opts[:thread_id] do
        nil ->
          {"thread/start",
           Map.merge(params, %{"environments" => [], "ephemeral" => false, "allowProviderModelFallback" => false, "dynamicTools" => Enum.map(state.tools, &Map.put(&1, "type", "function"))})}

        id when is_binary(id) ->
          {"thread/resume", Map.put(params, "threadId", id)}

        _ ->
          fail(:invalid_runtime_options)
      end

    {method, params}
  end

  defp validate_thread(thread, opts) do
    unless thread["model"] == @model and thread["approvalPolicy"] == "never" and
             get_in(thread, ["sandbox", "type"]) == "readOnly" and
             Map.get(thread, "instructionSources", []) == [],
           do: fail(:unsafe_thread_configuration)

    id = get_in(thread, ["thread", "id"])
    unless is_binary(id) and id != "", do: fail(:protocol_error)
    if opts[:thread_id] && opts.thread_id != id, do: fail(:thread_mismatch)
    id
  end

  defp verify_configuration(config) when is_map(config) do
    expected = configuration()

    valid =
      Enum.all?(expected, fn {key, value} ->
        # The App Server config projection omits these two native tool flags.
        # They are passed explicitly; unsupported server requests still deny.
        key in ["tools.update_plan.enabled", "tools.experimental_request_user_input.enabled"] or
          get_in(config, String.split(key, ".")) == value
      end)

    unless valid, do: fail(:unsafe_runtime_configuration)
  end

  defp verify_configuration(_), do: fail(:unsafe_runtime_configuration)

  defp require_model(state, cursor, pages) when pages < 20 do
    {result, state} = rpc(state, "model/list", %{"includeHidden" => true, "cursor" => cursor, "limit" => 100})

    cond do
      Enum.any?(Map.get(result, "data", []), &(&1["model"] == @model)) -> state
      is_binary(result["nextCursor"]) -> require_model(state, result["nextCursor"], pages + 1)
      true -> fail(:model_unavailable)
    end
  end

  defp require_model(_, _, _), do: fail(:model_unavailable)

  defp rpc(state, method, params) do
    id = state.next_id
    send_message(state, %{"id" => id, "method" => method, "params" => params})
    await_response(%{state | next_id: id + 1}, id)
  end

  defp await_response(state, id) do
    {message, state} = read_message(state)

    case message do
      %{"id" => ^id, "result" => result} when is_map(result) -> {result, state}
      %{"id" => ^id, "error" => _} -> fail(:request_rejected)
      %{"id" => _, "method" => _} -> await_response(server_request(message, state), id)
      %{"method" => _} -> await_response(notification(message, state), id)
      _ -> fail(:protocol_error)
    end
  end

  defp await_completion(state) do
    {message, state} = read_message(state)

    case message do
      %{"method" => "turn/completed", "params" => params} -> complete(params, state)
      %{"id" => _, "method" => _} -> await_completion(server_request(message, state))
      %{"id" => _, "result" => _} -> await_completion(state)
      %{"method" => _} -> await_completion(notification(message, state))
      _ -> fail(:protocol_error)
    end
  end

  defp complete(params, state) do
    unless params["threadId"] == state.thread_id and get_in(params, ["turn", "id"]) == state.turn_id,
      do: fail(:thread_mismatch)

    case get_in(params, ["turn", "status"]) do
      "completed" -> {:ok, %{thread_id: state.thread_id, status: :completed}}
      "interrupted" -> {:ok, %{thread_id: state.thread_id, status: :interrupted}}
      _ -> fail(:turn_failed)
    end
  end

  defp server_request(%{"id" => id, "method" => "item/tool/call", "params" => params}, state) do
    name = params["tool"]

    unless is_binary(state.thread_id) and is_binary(state.turn_id) and
             params["threadId"] == state.thread_id and params["turnId"] == state.turn_id and
             Enum.any?(state.tools, &(&1["name"] == name)) and is_map(params["arguments"]),
           do: fail(:forbidden_tool)

    state.emit.({:status, "Using #{name}"})

    case invoke_tool(state, name, params["arguments"]) do
      :interrupted ->
        tool_response(state, id, %{"error" => "interrupted"})
        interrupt(state)

      output ->
        tool_response(state, id, output)
        state
    end
  end

  defp server_request(%{"id" => id}, state) do
    send_message(state, %{"id" => id, "error" => %{"code" => -32_601, "message" => "Request is not supported by management chat"}})
    fail(:unsupported_server_request)
  end

  defp tool_response(state, id, output) do
    send_message(state, %{"id" => id, "result" => %{"success" => not Map.has_key?(output, "error"), "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(output)}]}})
  end

  defp invoke_tool(state, name, args) do
    task =
      Task.async(fn ->
        try do
          case state.tool.(name, args) do
            result when is_map(result) -> result
            _ -> %{"error" => "tool_failed"}
          end
        rescue
          _ -> %{"error" => "tool_failed"}
        catch
          _, _ -> %{"error" => "tool_failed"}
        end
      end)

    %Task{ref: task_ref} = task

    receive do
      {^task_ref, result} ->
        Task.ignore(task)
        result

      :interrupt ->
        Task.shutdown(task, :brutal_kill)
        :interrupted
    after
      min(30_000, remaining(state)) ->
        Task.shutdown(task, :brutal_kill)
        fail(:tool_timeout)
    end
  end

  defp notification(%{"method" => "turn/started", "params" => params}, state) do
    id = get_in(params, ["turn", "id"])

    unless params["threadId"] == state.thread_id and is_binary(id) and id != "" and state.turn_id in [nil, id],
      do: fail(:thread_mismatch)

    %{state | turn_id: id}
  end

  defp notification(%{"method" => "item/agentMessage/delta", "params" => params}, state) do
    verify_scope(params, state)
    if is_binary(params["delta"]), do: state.emit.({:delta, params["delta"]})
    state
  end

  defp notification(%{"method" => "thread/tokenUsage/updated", "params" => params}, state) do
    verify_scope(params, state)
    if is_map(params["tokenUsage"]), do: state.emit.({:usage, params["tokenUsage"]})
    state
  end

  defp notification(%{"method" => "item/started", "params" => params}, state) do
    verify_scope(params, state)
    type = get_in(params, ["item", "type"])

    cond do
      type == "contextCompaction" -> state.emit.({:status, "Updating conversation context"})
      type in ["commandExecution", "fileChange", "mcpToolCall", "collabAgentToolCall", "webSearch", "imageGeneration", "hook"] -> fail(:forbidden_tool)
      true -> :ok
    end

    state
  end

  defp notification(%{"method" => "error", "params" => params}, state) do
    if params["willRetry"] == true, do: state.emit.({:status, "Reconnecting to the model"}), else: fail(:model_error)
    state
  end

  defp notification(_, state), do: state

  defp verify_scope(params, state) do
    unless params["threadId"] == state.thread_id and
             (is_nil(state.turn_id) or params["turnId"] == state.turn_id),
           do: fail(:thread_mismatch)
  end

  defp read_message(state) do
    if remaining(state) == 0, do: fail(if(state.interrupted, do: :interrupt_timeout, else: :runtime_timeout))
    if byte_size(state.buffer) > @max_line, do: fail(:protocol_limit)

    case :binary.split(state.buffer, "\n") do
      [line, rest] ->
        case Jason.decode(line) do
          {:ok, message} when is_map(message) -> {message, %{state | buffer: rest}}
          _ -> fail(:protocol_error)
        end

      [_] ->
        receive_data(state)
    end
  end

  defp receive_data(%{port: port} = state) do
    receive do
      {^port, {:data, bytes}} -> read_message(%{state | buffer: state.buffer <> bytes})
      {^port, {:exit_status, _}} -> fail(:runtime_exited)
      :interrupt -> read_message(interrupt(state))
    after
      remaining(state) -> fail(if(state.interrupted, do: :interrupt_timeout, else: :runtime_timeout))
    end
  end

  defp interrupt(%{turn_id: nil}), do: fail(:interrupted_before_turn)
  defp interrupt(%{interrupted: true} = state), do: state

  defp interrupt(state) do
    send_message(state, %{"id" => state.next_id, "method" => "turn/interrupt", "params" => %{"threadId" => state.thread_id, "turnId" => state.turn_id}})
    %{state | next_id: state.next_id + 1, interrupted: true, deadline: min(state.deadline, now() + 2_000)}
  end

  defp send_message(state, message), do: Port.command(state.port, Jason.encode!(message) <> "\n")
  defp remaining(state), do: max(state.deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
  defp fail(reason), do: throw({:runtime_error, reason})

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
