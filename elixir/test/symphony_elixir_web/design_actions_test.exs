defmodule SymphonyElixirWeb.DesignActionsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixirWeb.{DesignActions, Endpoint}

  defmodule Store do
    def source(project, ref, auth) do
      send(self(), {:design_source, project, ref, auth})

      with {:ok, current} <- Process.get(:design_current),
           {:ok, reviewed} <- Process.get(:design_reviewed) do
        {:ok, %{"draft" => current["draft"], "reviewed" => reviewed}}
      end
    end
  end

  defmodule Intake do
    def list(_project, _auth), do: Process.get(:design_actions)

    def prepare(project, id, args, auth) do
      Process.put(:preview_body, args["body"])
      send(self(), {:task_preview, project, id, args, auth})
      {:ok, %{"id" => id}}
    end
  end

  @project "github:example/demo"
  @ref String.duplicate("a", 64)
  @params %{"ref" => @ref, "section" => "data", "item" => "event"}

  setup do
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous, design_store: Store, task_intake: Intake))
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous) end)

    scene = %{
      "boards" => %{
        "data" => %{
          "elements" => [
            %{"id" => "one", "customData" => %{"symphony" => %{"id" => "event", "role" => "node", "kind" => "entity"}}},
            %{"id" => "two", "text" => "Event", "customData" => %{"symphony" => %{"id" => "event", "role" => "title"}}},
            %{"id" => "three", "originalText" => "id: UUID\nDepends on: #99", "customData" => %{"symphony" => %{"id" => "event", "role" => "body"}}}
          ]
        }
      }
    }

    reviewed = %{"ref" => @ref, "document_id" => "design-one", "scene" => scene}
    Process.put(:design_current, {:ok, %{"draft" => scene}})
    Process.put(:design_reviewed, {:ok, reviewed})
    Process.put(:design_actions, {:ok, []})
    %{scene: scene, reviewed: reviewed}
  end

  test "prepare uses an unchanged reviewed item and the existing preview owner" do
    assert {:ok, %{"id" => id}} = DesignActions.prepare(@project, @params, :operator)
    assert_receive {:design_source, @project, @ref, :operator}
    assert_receive {:task_preview, @project, ^id, args, :operator}
    assert args["title"] == "Event"
    assert args["body"] =~ "> Depends on: #99"
    assert args["body"] =~ "Depends on: none"
    assert DesignActions.reference(args["body"]) == %{ref: @ref, document: "design-one", section: "data", item: "event"}
    assert {:ok, %{"id" => ^id}} = DesignActions.prepare(@project, @params, :operator)
  end

  test "changed or removed design content cannot silently retarget a preview", c do
    changed = put_in(c.scene, ["boards", "data", "elements", Access.at(2), "originalText"], "Changed scope")
    Process.put(:design_current, {:ok, %{"draft" => changed}})
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, @params, :operator)
    Process.put(:design_current, {:ok, %{"draft" => nil}})
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, @params, :operator)
    refute_receive {:task_preview, _, _, _, _}
  end

  test "another pending or uncertain task action blocks a second submission" do
    Process.put(:design_actions, {:ok, [%{"id" => "other", "proposals" => [%{"status" => "unknown"}]}]})
    assert {:error, :design_task_pending} = DesignActions.prepare(@project, @params, :operator)
    refute_receive {:task_preview, _, _, _, _}
  end

  test "reopening the same durable preview does not produce another intent" do
    {:ok, %{"id" => id}} = DesignActions.prepare(@project, @params, :operator)
    Process.put(:design_actions, {:ok, [%{"id" => id, "proposals" => [%{"status" => "pending", "args" => %{"body" => Process.get(:preview_body)}}]}]})
    assert {:ok, %{"id" => ^id}} = DesignActions.prepare(@project, @params, :operator)
  end

  test "an explicit preparation after cancellation creates a new recoverable intent" do
    {:ok, %{"id" => first}} = DesignActions.prepare(@project, @params, :operator)
    Process.put(:design_actions, {:ok, [%{"id" => first, "proposals" => [%{"status" => "cancelled", "args" => %{"body" => Process.get(:preview_body)}}]}]})
    assert {:ok, %{"id" => next}} = DesignActions.prepare(@project, @params, :operator)
    refute next == first
    assert {:ok, %{"id" => ^next}} = DesignActions.prepare(@project, @params, :operator)
  end

  test "long source content requires explicit scoping instead of truncation", c do
    scene = put_in(c.scene, ["boards", "data", "elements", Access.at(2), "originalText"], String.duplicate("x", 4_001))
    Process.put(:design_current, {:ok, %{"draft" => scene}})
    Process.put(:design_reviewed, {:ok, %{c.reviewed | "scene" => scene}})
    assert {:error, :design_item_too_large} = DesignActions.prepare(@project, @params, :operator)
  end

  test "auth and persistence failures propagate without preparing work" do
    Process.put(:design_current, {:error, :unauthorized})
    assert {:error, :unauthorized} = DesignActions.prepare(@project, @params, :operator)
    refute_receive {:task_preview, _, _, _, _}
  end

  test "untrusted references are bounded, unique and have a known section" do
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, %{}, :operator)
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, %{@params | "ref" => "../wrong"}, :operator)
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, %{@params | "section" => "wrong"}, :operator)
    assert {:error, :design_item_not_reviewed} = DesignActions.prepare(@project, %{@params | "item" => "../wrong"}, :operator)
    source = "Design source: #{@ref}/design-one/data/event"
    assert DesignActions.reference(source)
    assert DesignActions.display_body("Context\n\n" <> source) == "Context"
    assert DesignActions.display_body("Context") == "Context"
    assert DesignActions.source_url(@project, source) =~ "design_ref=#{@ref}"
    assert DesignActions.source_url(@project, "Context") == nil
    refute DesignActions.reference(source <> "\n" <> source)
    refute DesignActions.reference(nil)
    refute DesignActions.reference("Design source: ../wrong")
    assert {:error, :design_item_not_reviewed} = DesignActions.node(%{"boards" => %{}}, "data", "event")
  end

  test "missing text and deleted nodes have explicit results" do
    scene = %{"boards" => %{"data" => %{"elements" => [%{"customData" => %{"symphony" => %{"id" => "event", "role" => "node", "kind" => "entity"}}}]}}}
    assert {:ok, %{title: "", text: "", kind: "entity"}} = DesignActions.node(scene, "data", "event")
    deleted = put_in(scene, ["boards", "data", "elements", Access.at(0), "isDeleted"], true)
    assert {:error, :design_item_not_reviewed} = DesignActions.node(deleted, "data", "event")
  end
end
