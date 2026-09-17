defmodule SymphonyElixirWeb.TaskIntakeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Chat.Store
  alias SymphonyElixir.GitHub.Admission
  alias SymphonyElixirWeb.{Endpoint, TaskIntake}

  defmodule TestTools do
    def call("symphony_propose_action", args, context) do
      send(context.auth.test_pid, {:prepared, args})

      case context.auth[:prepare_result] do
        :error ->
          {:error, :board_unavailable}

        :malformed ->
          {:ok, %{}}

        _ ->
          {:ok,
           %{
             "proposal" => %{
               "action" => args["action"],
               "args" => Map.delete(args, "action"),
               "project_id" => context.project_id,
               "tracker_fingerprint" => context.tracker_fingerprint,
               "expected_updated_at" => context.auth[:updated_at],
               "queue_unheld" => args["action"] == "queue_task",
               "created_at" => "2026-09-16T01:00:00Z"
             },
             "widgets" => [%{"type" => "proposal", "title" => "Review task change"}]
           }}
      end
    end

    def confirm(proposal, context) do
      send(context.auth.test_pid, {:confirmed, proposal, self()})

      case context.auth[:result] do
        :wait -> receive do: (:finish -> {:ok, %{"summary" => "Task created"}})
        :unknown -> {:error, :write_outcome_unknown}
        _ -> {:ok, %{"summary" => "Task created", "url" => "https://github.com/test/one/issues/12"}}
      end
    end

    def reconcile(proposal, context) do
      send(context.auth.test_pid, {:reconciled, proposal})
      {:ok, %{"summary" => "Existing task found", "url" => "https://github.com/test/one/issues/12"}}
    end
  end

  defmodule Adapter do
    def list_actions(project, auth), do: Store.list_actions(project, auth, __MODULE__)
    def get_action(project, id, auth), do: Store.get_action(project, id, auth, __MODULE__)
    def prepare_action(project, id, args, auth), do: Store.prepare_action(project, id, args, auth, __MODULE__)
    def decide_action_record(project, id, decision, auth), do: Store.decide_action_record(project, id, decision, auth, __MODULE__)
  end

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "task-intake-#{System.unique_integer([:positive])}"))
    settings = %{enabled: true, state_path: root, max_concurrent: 2}
    projects = fn -> [%{"id" => "github:test/one"}, %{"id" => "github:test/two"}] end
    authorize = fn auth -> auth[:allowed] == true end
    opts = [name: Adapter, settings: settings, projects: projects, authorize: authorize, tools: TestTools]
    server = start_supervised!({Store, opts})
    prior = Application.get_env(:symphony_elixir, Endpoint)
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(prior || [], server: false, secret_key_base: String.duplicate("i", 64), chat_store: Adapter, board_read_only: false))

    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, prior)
      File.rm_rf(root)
    end)

    %{
      project: "github:test/one",
      auth: %{allowed: true, tracker_fingerprint: "scope", test_pid: self()},
      root: root,
      opts: opts,
      server: server,
      id: String.duplicate("a", 32),
      args: %{"action" => "create_task", "title" => "A task", "body" => "## Outcome\nDone\n\nDepends on: none"}
    }
  end

  test "task previews are durable and excluded from model conversations", c do
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert record["kind"] == "board_action"
    assert [%{"status" => "pending"}] = record["proposals"]
    assert File.exists?(Path.join(c.root, c.id <> ".json"))
    assert {:ok, [^record]} = TaskIntake.list(c.project, c.auth)
    assert {:ok, ^record} = TaskIntake.get(c.project, c.id, c.auth)
    assert {:ok, []} = Store.list(c.project, c.auth, c.server)
    assert {:ok, %{enabled: true, healthy: true}} = Store.health(c.auth, c.server)
    assert {:ok, chat} = Store.create(c.project, "Chat", c.auth, c.server)
    assert {:ok, [%{"id" => chat_id}]} = Store.list(c.project, c.auth, c.server)
    assert chat_id == chat["id"]

    for operation <- [:get, :archive, :stop] do
      assert {:error, :chat_not_found} = apply(Store, operation, [c.project, c.id, c.auth, c.server])
    end

    assert {:error, :chat_not_found} = Store.rename(c.project, c.id, "Hide", c.auth, c.server)
    assert {:error, :chat_not_found} = Store.send_message(c.project, c.id, "Model", "client", c.auth, c.server)
    assert {:error, :chat_not_found} = Store.decide(c.project, c.id, hd(record["proposals"])["id"], "confirm", c.auth, c.server)
    refute Map.has_key?(record, "submission")
  end

  test "exact submission replay survives restart and changed content cannot reuse its identity", c do
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert_receive {:prepared, _}
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, new_id(), c.args, c.auth)
    refute_receive {:prepared, _}
    restart(c)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:error, :submission_id_conflict} = TaskIntake.prepare(c.project, c.id, Map.put(c.args, "title", "Different"), c.auth)
    assert {:error, :chat_not_found} = TaskIntake.prepare("github:test/two", c.id, c.args, c.auth)
    assert {:error, :chat_not_found} = TaskIntake.get(c.project, c.id, %{c.auth | tracker_fingerprint: "new"})
    assert {:ok, []} = TaskIntake.list(c.project, %{c.auth | tracker_fingerprint: "new"})
    assert {:error, :unauthorized} = TaskIntake.prepare(c.project, c.id, c.args, %{})
    assert {:error, :unauthorized} = TaskIntake.decide(c.project, c.id, "confirm", %{})
    assert {:error, :unauthorized} = Store.prepare_action(c.project, c.id, c.args, %{})
    assert {:error, :project_not_found} = TaskIntake.list("github:unknown/project", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "an interrupted confirmed action only reconciles after restart and never repeats the write", c do
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> c.id)
    assert {:error, :invalid_decision} = TaskIntake.decide(c.project, c.id, "reconcile", c.auth)
    assert {:error, :invalid_decision} = TaskIntake.decide(c.project, c.id, "other", c.auth)
    assert {:ok, executing} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :wait))
    assert hd(executing["proposals"])["status"] == "executing"
    assert_receive {:confirmed, proposal, _worker}
    persisted = Jason.decode!(File.read!(Path.join(c.root, c.id <> ".json")))
    assert hd(persisted["proposals"])["status"] == "executing"
    assert {:error, :chat_busy} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    restart(c)
    assert {:ok, recovered} = TaskIntake.get(c.project, c.id, c.auth)
    assert hd(recovered["proposals"])["status"] == "unknown"
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    assert_receive {:reconciled, ^proposal}
    completed = wait_for(c, "completed")
    assert hd(completed["proposals"])["receipt"]["summary"] == "Existing task found"
    assert {:ok, ^completed} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "uncertain HTTP outcomes remain saved and cancelled previews never write", c do
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :unknown))
    assert_receive {:confirmed, _, _}
    unknown = wait_for(c, "unknown")
    restart(c)
    assert {:ok, ^unknown} = TaskIntake.get(c.project, c.id, c.auth)
    assert {:ok, ^unknown} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:ok, ^unknown} = TaskIntake.prepare(c.project, new_id(), c.args, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "reconcile", c.auth)
    assert_receive {:reconciled, _}
    wait_for(c, "completed")
    other = String.duplicate("b", 32)
    assert {:ok, _} = TaskIntake.prepare(c.project, other, c.args, c.auth)
    assert {:ok, cancelled} = TaskIntake.decide(c.project, other, "cancel", c.auth)
    assert hd(cancelled["proposals"])["status"] == "cancelled"
    refute_receive {:confirmed, _, _}
  end

  test "queue previews replay durably without changing task identity or authorization", c do
    args = %{"action" => "queue_task", "task_id" => "11"}
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert_receive {:prepared, ^args}
    assert record["kind"] == "board_action"
    assert [%{"action" => "queue_task", "status" => "pending"}] = record["proposals"]
    assert hd(record["proposals"])["details"]["queue_unheld"] == true
    assert {:ok, []} = Store.list(c.project, c.auth, c.server)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, new_id(), args, c.auth)
    restart(c)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, [^record]} = TaskIntake.list(c.project, c.auth)
    assert {:error, :submission_id_conflict} = TaskIntake.prepare(c.project, c.id, Map.put(args, "task_id", "12"), c.auth)
    assert {:error, :submission_id_conflict} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:error, :chat_not_found} = TaskIntake.prepare("github:test/two", c.id, args, c.auth)
    assert {:error, :chat_not_found} = TaskIntake.prepare(c.project, c.id, args, %{c.auth | tracker_fingerprint: "new"})
    assert {:error, :unauthorized} = TaskIntake.prepare(c.project, new_id(), args, %{})
    assert {:error, :unauthorized} = TaskIntake.decide(c.project, c.id, "confirm", %{})
    refute_receive {:prepared, _}
    refute_receive {:confirmed, _, _}
  end

  test "interrupted queue confirmation recovers through reconciliation without a second write", c do
    args = %{"action" => "queue_task", "task_id" => "11"}
    assert {:ok, _} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, executing} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :wait))
    assert hd(executing["proposals"])["status"] == "executing"
    assert_receive {:confirmed, proposal, _worker}
    persisted = Jason.decode!(File.read!(Path.join(c.root, c.id <> ".json")))
    assert hd(persisted["proposals"])["status"] == "executing"
    assert {:error, :chat_busy} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    restart(c)
    assert {:ok, recovered} = TaskIntake.get(c.project, c.id, c.auth)
    assert hd(recovered["proposals"])["status"] == "unknown"
    assert {:ok, ^recovered} = TaskIntake.prepare(c.project, new_id(), args, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    assert_receive {:reconciled, ^proposal}
    completed = wait_for(c, "completed")
    assert {:ok, ^completed} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    restart(c)
    assert {:ok, ^completed} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, ^completed} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "unknown queue outcomes deduplicate across restart and cancelled queue previews do not write", c do
    args = %{"action" => "queue_task", "task_id" => "11"}
    assert {:ok, _} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :unknown))
    assert_receive {:confirmed, proposal, _}
    unknown = wait_for(c, "unknown")
    restart(c)
    assert {:ok, ^unknown} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    assert {:ok, ^unknown} = TaskIntake.prepare(c.project, new_id(), args, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "reconcile", c.auth)
    assert_receive {:reconciled, ^proposal}
    wait_for(c, "completed")
    other = new_id()
    assert {:ok, _} = TaskIntake.prepare(c.project, other, Map.put(args, "task_id", "12"), c.auth)
    assert {:ok, cancelled} = TaskIntake.decide(c.project, other, "cancel", c.auth)
    assert hd(cancelled["proposals"])["status"] == "cancelled"
    assert {:ok, ^cancelled} = TaskIntake.decide(c.project, other, "confirm", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "queue submissions reject malformed identities and injected action fields before invoking tools", c do
    args = %{"action" => "queue_task", "task_id" => "11"}

    for task_id <- [nil, 11, [], "", " \n ", <<255>>, "0", "01", "-1", "11\n", "1.1", "GH-11", "github:test/one#11", String.duplicate("1", 241)] do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, new_id(), Map.put(args, "task_id", task_id), c.auth)
    end

    for {key, value} <- [{"priority", 1}, {"labels", ["symphony:ready"]}, {"project_id", "github:test/two"}, {"expected_revision", 1}, {"resume", true}, {"title", "Changed title"}] do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, new_id(), Map.put(args, key, value), c.auth)
    end

    for action <- ~w(unqueue_task retry cancel resume) do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, new_id(), %{args | "action" => action}, c.auth)
    end

    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, "not-an-id", args, c.auth)
    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, new_id(), Map.delete(args, "task_id"), c.auth)
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :board_read_only, true)}], [])
    assert {:error, :read_only} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    refute_receive {:prepared, _}
    refute_receive {:confirmed, _, _}
  end

  test "bounded form actions validate dependency syntax and reject privileged or malformed fields", c do
    for args <- [nil, %{}, %{"action" => "resume"}, Map.put(c.args, "priority", 1), %{"action" => "create_task", "body" => nil}] do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, c.id, args, c.auth)
    end

    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, "not-an-id", c.args, c.auth)
    assert {:error, {:invalid_dependency_declaration, explanation}} = TaskIntake.prepare(c.project, c.id, Map.put(c.args, "body", "Missing dependencies"), c.auth)
    assert TaskIntake.error_message({:invalid_dependency_declaration, explanation}) =~ "Depends on"
    assert {:ok, ["12", "34"]} = Admission.validate_declaration("Intent\nDepends on: #12, #34")
    assert {:error, _} = Admission.validate_declaration(nil)

    for action <- ~w(edit_task feedback queue_task unqueue_task resume) do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, new_id(), %{c.args | "action" => action}, c.auth)
    end
  end

  test "storage and read-only guards prevent proposals or confirmed writes", c do
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :board_read_only, true)}], [])
    assert {:error, :read_only} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    assert {:error, :read_only} = TaskIntake.list(c.project, c.auth)
    assert TaskIntake.error_message(:read_only) =~ "read-only"
    assert TaskIntake.error_message(:unauthorized) =~ "Sign in"
    assert TaskIntake.error_message("Unavailable") == "Unavailable"
    refute_receive {:prepared, _}
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :board_read_only, false)}], [])
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
    path = Path.join(c.root, c.id <> ".json")
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :chat_storage_unavailable} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    assert {:error, :chat_storage_unavailable} = TaskIntake.list(c.project, c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "preparation failures and journal capacity preserve prior records", c do
    assert {:error, :board_unavailable} = TaskIntake.prepare(c.project, c.id, c.args, Map.put(c.auth, :prepare_result, :error))
    assert {:error, :invalid_proposal} = TaskIntake.prepare(c.project, c.id, c.args, Map.put(c.auth, :prepare_result, :malformed))
    assert {:ok, []} = TaskIntake.list(c.project, c.auth)
    :sys.replace_state(c.server, fn state -> %{state | chats: Map.new(1..500, fn n -> {n, %{}} end)} end)
    assert {:error, :action_history_full} = TaskIntake.prepare(c.project, c.id, c.args, c.auth)
  end

  defp restart(c) do
    stop_supervised!(Store)
    start_supervised!({Store, c.opts})
  end

  defp wait_for(c, status, attempts \\ 100)
  defp wait_for(_c, _status, 0), do: flunk("Action did not settle")

  defp wait_for(c, status, attempts) do
    {:ok, record} = TaskIntake.get(c.project, c.id, c.auth)

    if hd(record["proposals"])["status"] == status do
      record
    else
      Process.sleep(10)
      wait_for(c, status, attempts - 1)
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
