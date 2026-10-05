defmodule SymphonyElixirWeb.SpecificationActionsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Specification.{Document, Store}
  alias SymphonyElixirWeb.{Endpoint, SpecificationActions}
  @project "github:example/system"
  @item "search"

  defmodule Source do
    def source(project, ref, auth), do: Store.source(project, ref, auth, Endpoint.config(:specification_fixture))
  end

  defmodule Intake do
    def list(_project, _auth) do
      case Process.get(:records, {:ok, []}) do
        :raise -> raise "unavailable"
        :exit -> exit(:unavailable)
        value -> value
      end
    end

    def get(_project, id, _auth), do: {:ok, %{"id" => id}}

    def prepare(project, id, args, auth) do
      send(self(), {:preview, project, id, args, auth})
      {:ok, %{"id" => id, "project_id" => project, "proposals" => [%{"status" => "pending", "args" => Map.delete(args, "action")}]}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "spec-task-#{System.unique_integer([:positive])}")
    options = [name: nil, project: @project, state_dir: root, scope: fn -> "fixture" end]
    options = Keyword.put(options, :authorize, fn auth -> auth == :operator end)
    store = start_supervised!({Store, options})
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous, specification_store: Source, specification_fixture: store, task_intake: Intake))
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous)
      File.rm_rf(root)
    end)

    document =
      put_in(Document.new(@project), ["sections", "requirements", "items"], [
        %{"id" => @item, "kind" => "functional", "title" => "Discover events", "body" => "Relevant search", "criteria" => [%{"id" => "relevance", "statement" => "Filter results", "method" => "test"}]}
      ])

    {:ok, _} = Store.save(@project, 0, document, :operator, store)
    {:ok, state} = Store.review(@project, 1, :operator, store)
    %{store: store, root: root, document: document, params: %{"ref" => state["reviewed"]["ref"], "item" => @item, "storage_revision" => "2"}}
  end

  test "a reviewed requirement opens one durable preview and replay preserves uncertain/completed outcomes", c do
    {:ok, first} = SpecificationActions.prepare(@project, c.params, :operator)
    assert_receive {:preview, @project, id, args, :operator}
    assert first["id"] == id

    for status <- ~w(pending executing unknown completed) do
      record = put_in(first, ["proposals", Access.at(0), "status"], status)
      Process.put(:records, {:ok, [record]})
      assert {:ok, %{"id" => ^id}} = SpecificationActions.prepare(@project, c.params, :operator)
      assert_receive {:preview, @project, ^id, ^args, :operator}
    end

    for status <- ~w(cancelled failed) do
      Process.put(:records, {:ok, [put_in(first, ["proposals", Access.at(0), "status"], status)]})
      assert {:ok, %{"id" => next}} = SpecificationActions.prepare(@project, c.params, :operator)
      refute next == id
    end

    Process.put(:records, {:ok, [%{"id" => "other", "proposals" => [%{"status" => "unknown"}]}]})
    assert {:error, :specification_task_pending} = SpecificationActions.prepare(@project, c.params, :operator)
  end

  test "fresh scope and revision checks reject changed, removed and oversized criteria without consuming work", c do
    assert {:error, :unauthorized} = SpecificationActions.prepare(@project, c.params, :outsider)
    assert {:error, _} = SpecificationActions.prepare("github:foreign/project", c.params, :operator)

    invalid = [%{}, %{c.params | "ref" => "bad"}, %{c.params | "item" => "../bad"}]
    invalid = invalid ++ [%{c.params | "storage_revision" => "1"}, %{c.params | "item" => "missing"}]

    for params <- invalid do
      assert {:error, _} = SpecificationActions.prepare(@project, params, :operator)
    end

    changed = put_in(c.document, ["sections", "requirements", "items", Access.at(0), "criteria", Access.at(0), "statement"], "Changed scope")
    {:ok, _} = Store.save(@project, 2, changed, :operator, c.store)
    result = SpecificationActions.prepare(@project, %{c.params | "storage_revision" => "3"}, :operator)
    assert result == {:error, :specification_item_not_reviewed}
    refute_receive {:preview, _, _, _, _}
    Process.put(:records, {:error, :storage_down})
    assert SpecificationActions.records(@project, :operator) == {:error, :storage_down}
  end

  test "source links stay project bound and coverage failure stays readable", c do
    {:ok, _} = SpecificationActions.prepare(@project, c.params, :operator)
    assert_receive {:preview, _, _, args, _}
    url = SpecificationActions.source_url(@project, args["body"])
    assert url =~ "view=design"
    assert url =~ "spec_item=#{@item}"
    assert url =~ "project=github%3Aexample%2Fsystem"
    assert SpecificationActions.source_url(@project, "ordinary") == nil
    assert SpecificationActions.task_url(@project, @project <> ":1") =~ "view=kanban"
    Process.put(:records, nil)
    assert SpecificationActions.records(@project, :operator) == {:error, :task_links_unavailable}

    for error <- [:raise, :exit] do
      Process.put(:records, error)
      assert SpecificationActions.records(@project, :operator) == {:error, :task_links_unavailable}
    end

    assert SpecificationActions.get(@project, "record", :operator) == {:ok, %{"id" => "record"}}
  end
end
