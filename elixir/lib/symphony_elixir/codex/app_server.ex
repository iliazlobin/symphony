defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, ProcessGroup, SSH, WorkerFailure}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @account_read_id 4
  @auth_status_id 5
  @rate_limits_id 6
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          controlled: boolean(),
          profile: :builder | :reviewer,
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, Keyword.put(opts, :issue, issue)) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    controlled = Config.control_settings().enabled
    profile = Keyword.get(opts, :profile, :builder)

    startup_context = %{
      controlled: controlled,
      profile: profile,
      issue: opts[:issue],
      pr_work_id: opts[:pr_work_id],
      thread_id: opts[:thread_id]
    }

    original_binding = DynamicTool.bind()
    dynamic_tool_binding = if controlled, do: Map.put(original_binding, :tool_specs, []), else: original_binding

    with :ok <- validate_retained_session(controlled, profile, opts[:pr_work_id], opts[:thread_id]),
         :ok <- validate_controlled_profile(controlled, profile),
         :ok <- validate_controlled_host(controlled, worker_host),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding, startup_context) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, profile),
           {:ok, thread_id} <-
             do_start_session(port, expanded_workspace, session_policies, dynamic_tool_binding, startup_context) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: not controlled and session_policies.approval_policy == "never",
           controlled: controlled,
           profile: profile,
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          auto_approve_requests: auto_approve_requests,
          thread_id: thread_id,
          dynamic_tool_binding: dynamic_tool_binding
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    original_on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    capture_key = {__MODULE__, make_ref()}
    Process.put(capture_key, [])

    on_message = fn message ->
      capture_agent_message(capture_key, message)
      original_on_message.(message)
    end

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        if Map.get(session, :controlled, false) do
          %{"success" => false, "output" => "Dynamic tools are disabled for controlled workers."}
        else
          DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
        end
      end)

    deadline = timeout_budget(Config.settings!().codex.turn_timeout_ms)

    try do
      case startup_phase(Map.put(session, :issue, issue), :turn_start, fn -> start_turn(session, prompt, issue, opts, deadline) end) do
        {:ok, turn_id} ->
          session_id = "#{thread_id}-#{turn_id}"
          Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

          emit_message(
            on_message,
            :session_started,
            %{
              session_id: session_id,
              thread_id: thread_id,
              turn_id: turn_id
            },
            metadata
          )

          case await_turn_completion(port, on_message, tool_executor, auto_approve_requests, deadline) do
            {:ok, result} ->
              Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

              {:ok,
               %{
                 result: result,
                 final_messages: Process.get(capture_key, []) |> Enum.reverse(),
                 session_id: session_id,
                 thread_id: thread_id,
                 turn_id: turn_id
               }}

            {:error, reason} ->
              reason = if Map.get(session, :controlled, false), do: controlled_worker_failure(reason), else: reason
              Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

              emit_message(
                on_message,
                :turn_ended_with_error,
                %{
                  session_id: session_id,
                  reason: reason
                },
                metadata
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
          emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
          {:error, reason}
      end
    after
      Process.delete(capture_key)
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding, context) do
    if Config.control_settings().enabled do
      ProcessGroup.open(local_launch_command(dynamic_tool_binding),
        cd: workspace,
        env: tracker_secret_port_env(dynamic_tool_binding) ++ worker_environment(context),
        line: @port_line_bytes
      )
    else
      start_unmanaged_port(workspace, dynamic_tool_binding)
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, _profile) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp worker_environment(context) do
    [
      {~c"SYMPHONY_WORKER_ROLE", String.to_charlist(to_string(context.profile))},
      {~c"SYMPHONY_PR_WORK_ID", if(context.pr_work_id, do: String.to_charlist(context.pr_work_id), else: false)},
      {~c"SYMPHONY_PR_WORK_RESUME", if(context.thread_id, do: ~c"true", else: false)}
    ]
  end

  defp start_unmanaged_port(workspace, dynamic_tool_binding) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding))],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
    |> ProcessGroup.port_environment()
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    names = dynamic_tool_binding.secret_environment_names ++ Config.process_secret_environment_names()

    "unset " <> Enum.join(names |> valid_environment_names() |> Enum.uniq(), " ")
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp validate_retained_session(_controlled, _profile, nil, nil), do: :ok

  defp validate_retained_session(true, :builder, work_id, thread_id) when is_binary(work_id) do
    valid = String.match?(work_id, ~r/^[a-f0-9]{32}$/) and (is_nil(thread_id) or valid_thread_id?(thread_id))
    if valid, do: :ok, else: {:error, :invalid_retained_session}
  end

  defp validate_retained_session(_controlled, _profile, _work_id, _thread_id), do: {:error, :invalid_retained_session}
  defp valid_thread_id?(id), do: is_binary(id) and String.match?(id, ~r/^[A-Za-z0-9_-]{1,128}$/)

  defp validate_controlled_profile(true, profile) when profile not in [:builder, :reviewer],
    do: {:error, :invalid_controlled_worker_profile}

  defp validate_controlled_profile(_controlled, _profile), do: :ok

  defp validate_controlled_host(true, host) when not is_nil(host), do: {:error, :controlled_workers_require_local_host}
  defp validate_controlled_host(_controlled, _host), do: :ok

  defp session_policies(workspace, worker_host, profile) do
    result = Config.codex_runtime_settings(workspace, remote: not is_nil(worker_host))

    controlled_policies(result, profile, Config.control_settings().enabled)
  end

  defp controlled_policies({:ok, policies}, profile, true) do
    {:ok, policies |> Map.put(:approval_policy, "never") |> Map.put(:profile, profile)}
  end

  defp controlled_policies(result, _profile, _controlled), do: result

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, context) do
    with :ok <- startup_phase(context, :initialize, fn -> send_initialize(port) end),
         :ok <- verify_worker_auth(port, context) do
      phase = if context.thread_id, do: :thread_resume, else: :thread_start

      startup_phase(context, phase, fn ->
        start_thread(port, workspace, session_policies, dynamic_tool_binding, context)
      end)
    end
  end

  defp verify_worker_auth(port, %{controlled: true} = context) do
    if Config.codex_auth_preflight?() do
      startup_phase(context, :worker_auth, fn -> subscription_preflight(port) end)
    else
      :ok
    end
  end

  defp verify_worker_auth(_port, _context), do: :ok

  defp subscription_preflight(port) do
    # account/read may return a cached account after refresh fails. Token-free
    # auth status and a provider-backed rate-limit read are both required.
    with {:ok, account} <- auth_request(port, @account_read_id, "account/read", %{"refreshToken" => true}),
         :ok <- verify_subscription_account(account),
         {:ok, status} <- auth_request(port, @auth_status_id, "getAuthStatus", %{"includeToken" => false, "refreshToken" => false}),
         :ok <- verify_subscription_status(status),
         {:ok, limits} <- auth_request(port, @rate_limits_id, "account/rateLimits/read", nil) do
      verify_subscription_limits(limits)
    end
  end

  defp auth_request(port, id, method, params) do
    send_message(port, %{"id" => id, "method" => method, "params" => params})

    case await_response(port, id) do
      {:error, reason} ->
        if WorkerFailure.authentication_required?(reason) or provider_auth_rejected?(method, reason),
          do: {:error, :worker_auth_required},
          else: {:error, reason}

      response ->
        response
    end
  end

  # Codex 0.153.4 serializes this provider HTTP status as -32603, without data.
  # Scope compatibility to its rate-limit transport envelope, before body text.
  defp provider_auth_rejected?("account/rateLimits/read", {:response_error, %{"code" => -32_603, "message" => message}})
       when is_binary(message) and byte_size(message) <= 16_384 do
    Regex.match?(
      ~r"""
      \Afailed\x20to\x20fetch\x20codex\x20rate\x20limits:\x20GET\x20
      https:\/\/[^\s?#;]+\/(?:wham|api\/codex)\/usage\x20
      failed:\x20401\x20Unauthorized;\x20content-type=
      """x,
      message
    )
  end

  defp provider_auth_rejected?(_method, _reason), do: false

  defp verify_subscription_account(%{"account" => %{"type" => "chatgpt"}, "requiresOpenaiAuth" => true}), do: :ok
  defp verify_subscription_account(_account), do: {:error, :worker_auth_required}

  defp verify_subscription_status(%{"authMethod" => method, "requiresOpenaiAuth" => true} = status)
       when method in ["chatgpt", "chatgptAuthTokens"] do
    if is_nil(status["authToken"]), do: :ok, else: {:error, :worker_auth_required}
  end

  defp verify_subscription_status(_status), do: {:error, :worker_auth_required}

  defp verify_subscription_limits(%{"rateLimits" => limits}) when is_map(limits) and map_size(limits) > 0, do: :ok
  defp verify_subscription_limits(_limits), do: {:error, :worker_auth_required}

  defp startup_phase(%{controlled: true} = context, phase, operation) do
    started = System.monotonic_time(:millisecond)
    result = operation.()
    elapsed = System.monotonic_time(:millisecond) - started
    fields = "phase=#{phase} elapsed_ms=#{elapsed} worker_role=#{context.profile}" <> startup_context(context) <> startup_thread(context)

    case result do
      {:error, reason} ->
        reason = controlled_worker_failure(reason)
        Logger.warning("Codex startup failed #{fields} reason=#{startup_reason(reason)}")
        {:error, {:startup_failed, phase, reason}}

      success ->
        Logger.info("Codex startup completed #{fields}")
        success
    end
  end

  defp startup_phase(_context, _phase, operation), do: operation.()

  # Dedicated subscription wrappers reserve these statuses for unsafe/missing
  # credentials (78) and unavailable exclusive auth ownership (79).
  defp controlled_worker_failure({:port_exit, status} = reason) when status in [78, 79] do
    if Config.codex_auth_preflight?(), do: :worker_auth_required, else: reason
  end

  defp controlled_worker_failure(reason), do: reason

  defp startup_thread(%{thread_id: thread_id}) when is_binary(thread_id), do: " thread_id=#{thread_id}"
  defp startup_thread(_context), do: ""

  defp startup_context(%{issue: %{id: _, identifier: _} = issue}), do: " " <> issue_context(issue)
  defp startup_context(_context), do: ""

  defp startup_reason(reason) when is_atom(reason), do: reason
  defp startup_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp startup_reason(_reason), do: :unknown

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox} = policies,
         dynamic_tool_binding,
         context
       ) do
    send_message(port, %{
      "method" => if(context.thread_id, do: "thread/resume", else: "thread/start"),
      "id" => @thread_start_id,
      "params" =>
        %{
          "approvalPolicy" => approval_policy,
          "cwd" => workspace,
          "dynamicTools" => dynamic_tool_binding.tool_specs
        }
        |> legacy_sandbox_parameter(not is_nil(policies[:profile]), "sandbox", thread_sandbox)
        |> Map.merge(profile_parameters(policies[:profile], :thread))
        |> retained_thread_parameters(context)
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload} = response} ->
        with :ok <- verify_permission_profile(response, policies[:profile]),
             :ok <- verify_retained_thread(response, context, workspace) do
          parse_thread_payload(thread_payload)
        end

      other ->
        other
    end
  end

  defp retained_thread_parameters(params, %{thread_id: nil, pr_work_id: nil}), do: params
  defp retained_thread_parameters(params, %{thread_id: nil}), do: Map.put(params, "ephemeral", false)
  defp retained_thread_parameters(params, %{thread_id: id}), do: Map.put(params, "threadId", id)

  defp verify_retained_thread(_response, %{pr_work_id: nil}, _workspace), do: :ok

  defp verify_retained_thread(response, context, workspace) do
    id = get_in(response, ["thread", "id"])

    if valid_thread_id?(id) and (is_nil(context.thread_id) or id == context.thread_id) and
         response["cwd"] == workspace and response["approvalPolicy"] == "never",
       do: :ok,
       else: {:error, :retained_thread_mismatch}
  end

  defp parse_thread_payload(%{"id" => thread_id}), do: {:ok, thread_id}
  defp parse_thread_payload(payload), do: {:error, {:invalid_thread_payload, payload}}

  defp start_turn(session, prompt, issue, opts, deadline) do
    %{port: port, thread_id: thread_id, workspace: workspace} = session
    %{approval_policy: approval_policy, turn_sandbox_policy: turn_sandbox_policy} = session

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" =>
        %{
          "threadId" => thread_id,
          "input" => [
            %{
              "type" => "text",
              "text" => prompt
            }
          ],
          "cwd" => workspace,
          "title" => "#{issue.identifier}: #{issue.title}",
          "approvalPolicy" => approval_policy
        }
        |> legacy_sandbox_parameter(Map.get(session, :controlled, false), "sandboxPolicy", turn_sandbox_policy)
        |> Map.merge(profile_parameters(if(Map.get(session, :controlled), do: session.profile), :turn))
        |> maybe_output_schema(opts[:output_schema])
    })

    case await_response(port, @turn_start_id, deadline) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, deadline) do
    receive_loop(
      port,
      on_message,
      deadline,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    if expired?(timeout_ms) do
      {:error, :turn_timeout}
    else
      receive_turn(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
    end
  end

  defp receive_turn(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      remaining_ms(timeout_ms) ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)

        completed_result(payload)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp completed_result(payload) do
    case get_in(payload, ["params", "turn", "status"]) do
      status when status in ["failed", "interrupted"] -> {:error, {:turn_failed, Map.get(payload, "params")}}
      _ -> {:ok, :turn_completed}
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id, outer_deadline \\ nil) do
    budget = timeout_budget(Config.settings!().codex.read_timeout_ms)

    deadline =
      case {budget, outer_deadline} do
        {{:deadline, read_deadline}, {:deadline, turn_deadline}} -> {:deadline, min(read_deadline, turn_deadline)}
        _ -> budget
      end

    with_timeout_response(port, request_id, deadline, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    if expired?(timeout_ms) do
      {:error, :response_timeout}
    else
      receive_response(port, request_id, timeout_ms, pending_line)
    end
  end

  defp receive_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      remaining_ms(timeout_ms) ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"method" => "account/chatgptAuthTokens/refresh"}} ->
        # The host auth adapter owns this callback and its private response.
        # Match it before response IDs: server request IDs can overlap ours.
        # Never log its payload or start controlled work without its owner.
        if Config.control_settings().enabled,
          do: {:error, :worker_auth_required},
          else: with_timeout_response(port, request_id, timeout_ms, "")

      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp timeout_budget(milliseconds) do
    if Config.control_settings().enabled,
      do: {:deadline, System.monotonic_time(:millisecond) + milliseconds},
      else: milliseconds
  end

  defp remaining_ms({:deadline, deadline}), do: max(0, deadline - System.monotonic_time(:millisecond))
  defp remaining_ms(timeout_ms), do: timeout_ms
  defp expired?({:deadline, _} = deadline), do: remaining_ms(deadline) == 0
  defp expired?(_timeout), do: false

  # Legacy sandbox fields replace the selected named profile. Controlled sessions
  # select the installed policy once and retain it across every turn.
  defp legacy_sandbox_parameter(params, true, _key, _policy), do: params
  defp legacy_sandbox_parameter(params, false, key, policy), do: Map.put(params, key, policy)

  defp verify_permission_profile(_response, nil), do: :ok

  defp verify_permission_profile(response, profile) do
    expected = permission_profile(profile)

    case response["activePermissionProfile"] do
      %{"id" => ^expected} -> :ok
      _ -> {:error, {:permission_profile_mismatch, expected}}
    end
  end

  defp permission_profile(:builder), do: "symphony-builder"
  defp permission_profile(:reviewer), do: "symphony-reviewer"

  defp profile_parameters(nil, _phase), do: %{}

  defp profile_parameters(profile, :thread) do
    %{
      "model" => "gpt-6-astra",
      "config" => %{
        "model_reasoning_effort" => profile_effort(profile),
        "default_permissions" => permission_profile(profile)
      }
    }
  end

  defp profile_parameters(profile, :turn), do: %{"model" => "gpt-6-astra", "effort" => profile_effort(profile)}
  defp profile_effort(:reviewer), do: "high"
  defp profile_effort(_builder), do: "medium"
  defp maybe_output_schema(params, nil), do: params
  defp maybe_output_schema(params, schema), do: Map.put(params, "outputSchema", schema)

  defp capture_agent_message(key, %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}}) when is_binary(text) do
    Process.put(key, [text | Process.get(key, [])])
  end

  defp capture_agent_message(_key, _message), do: :ok
  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
