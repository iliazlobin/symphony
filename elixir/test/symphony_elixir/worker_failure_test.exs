defmodule SymphonyElixir.WorkerFailureTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkerFailure

  test "authentication uses structured protocol codes and survives typed exits" do
    for code <- ~w(unauthorized refresh_token_expired refresh_token_reused refresh_token_invalidated refresh_token_revoked) do
      reason = {:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => code, "message" => "PRIVATE_UPSTREAM"}}}}
      failure = WorkerFailure.exception(reason: reason)
      assert WorkerFailure.authentication_required?(reason)
      assert WorkerFailure.authentication_required?(failure)
      assert WorkerFailure.authentication_required?({failure, [:private_stack]})
      assert WorkerFailure.summary(failure) == "Worker sign-in required"
      assert WorkerFailure.summary({failure, [:private_stack]}) == "Worker sign-in required"
      assert Exception.message(failure) == "Worker sign-in required"
      startup_error = {:startup_failed, :worker_auth, {:response_error, %{"data" => %{"code" => code}}}}
      assert WorkerFailure.authentication_required?(startup_error)
      assert WorkerFailure.authentication_required?({:turn_failed, %{"error" => %{"code" => code}}})
    end

    assert WorkerFailure.authentication_required?(:worker_auth_required)
    assert WorkerFailure.authentication_required?("Worker sign-in required")
  end

  test "ordinary prose and unrelated errors never require authentication" do
    for reason <- [
          nil,
          :boom,
          "unauthorized",
          "Fix an unauthorized login error",
          {:turn_failed, %{"turn" => %{"error" => %{"message" => "unauthorized refresh_token_revoked"}}}},
          {:response_error, %{"code" => -32_000, "message" => "unauthorized", "data" => "refresh_token_reused"}},
          {:turn_failed, nil}
        ] do
      refute WorkerFailure.authentication_required?(reason)
      refute WorkerFailure.summary(reason) =~ "PRIVATE"
    end
  end

  test "malformed turn and error payloads cannot crash failure handling" do
    for turn <- ["invalid", [], 1, nil, %{"error" => "invalid"}] do
      reason = {:turn_failed, %{"turn" => turn}}
      refute WorkerFailure.authentication_required?(reason)
      assert WorkerFailure.summary(reason) == "Worker response failed; retry scheduled"
    end
  end

  test "bounded compatibility recognizes only the previous inspected runner dump" do
    reason = {:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => "unauthorized", "message" => "PRIVATE_UPSTREAM"}}}}
    exception = %RuntimeError{message: "Agent run failed for issue_id=19 issue_identifier=GH-19: #{inspect(reason)}"}
    legacy = "agent exited: #{inspect({exception, [:private_stack]})}"
    assert WorkerFailure.authentication_required?(legacy)
    assert WorkerFailure.summary(legacy) == "Worker sign-in required"
    refute WorkerFailure.authentication_required?(String.replace(legacy, "agent exited:", "Task text:"))
    refute WorkerFailure.authentication_required?(legacy <> String.duplicate("x", 16_384))
    refute WorkerFailure.authentication_required?(String.replace(legacy, ":turn_failed", ":other_error"))
    refute WorkerFailure.summary(String.replace(legacy, "unauthorized", "other_error")) =~ "PRIVATE"
  end

  test "summaries exclude payloads, stack traces and arbitrary provider prose" do
    expected = [
      {:normal, "Worker completed"},
      {:turn_timeout, "Worker response timed out; retry scheduled"},
      {:response_timeout, "Worker startup timed out; retry scheduled"},
      {{:startup_failed, :thread_start, :response_timeout}, "Worker startup timed out; retry scheduled"},
      {{:turn_failed, %{"private" => "PRIVATE"}}, "Worker response failed; retry scheduled"},
      {{:turn_cancelled, %{"private" => "PRIVATE"}}, "Worker response was interrupted"},
      {{:port_exit, 9}, "Worker process exited; retry scheduled"},
      {"no available orchestrator slots", "no available orchestrator slots"},
      {"codex turn requires operator input", "codex turn requires operator input"},
      {"codex turn requires approval", "codex turn requires approval"},
      {"codex MCP elicitation requires operator input", "codex MCP elicitation requires operator input"},
      {{%RuntimeError{message: "PRIVATE"}, [:private_stack]}, "Worker failed; inspect service logs"}
    ]

    for {reason, message} <- expected do
      assert WorkerFailure.summary(reason) == message
      assert WorkerFailure.summary(message) == message
      assert byte_size(message) <= 160
    end
  end
end
