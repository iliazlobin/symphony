defmodule SymphonyElixir.TaskDraftTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TaskDraft

  @draft %{"title" => "Document tests", "description" => "Add the command to the README.", "verification" => "Run the command and check the README link."}

  test "the shared form creates a bounded issue body with an explicit dependency default" do
    assert {:ok, args} = TaskDraft.action_args(@draft)

    assert args == %{
             "action" => "create_task",
             "title" => @draft["title"],
             "body" => "## Description\n\nAdd the command to the README.\n\n## Verification\n\nRun the command and check the README link.\n\nDepends on: none"
           }
  end

  test "explicit dependencies are preserved and conflicting or malformed declarations fail closed" do
    description = @draft["description"] <> "\n\nDepends on: #12, #34"
    assert {:ok, args} = TaskDraft.action_args(Map.put(@draft, "description", description))
    assert args["body"] =~ description
    refute args["body"] =~ "Depends on: none"

    for invalid <- ["Depends on: #12, #12", "depends on: none", "Depends on: none\nDepends on: #12"] do
      assert {:error, {:invalid_dependency_declaration, _}} = TaskDraft.action_args(Map.put(@draft, "description", invalid))
    end

    assert {:error, {:invalid_dependency_declaration, _}} =
             @draft
             |> Map.put("description", description)
             |> Map.put("verification", "Depends on: none")
             |> TaskDraft.action_args()
  end

  test "required fields, exact field keys, UTF-8 and byte limits are validated without truncation" do
    assert {:error, :invalid_task_fields} = TaskDraft.action_args(nil)
    assert {:error, :invalid_task_fields} = TaskDraft.action_args(%{})
    assert {:error, :invalid_task_fields} = TaskDraft.action_args(Map.put(@draft, "priority", 1))

    for field <- ~w(title description verification), value <- [nil, 1, <<255>>] do
      assert {:error, :required_fields} = TaskDraft.action_args(Map.put(@draft, field, value))
    end

    for title <- ["", " \n "] do
      assert {:error, :required_fields} = TaskDraft.action_args(Map.put(@draft, "title", title))
    end

    for {field, limit} <- [{"title", 200}, {"description", 4_000}, {"verification", 4_000}] do
      assert {:ok, _} = TaskDraft.action_args(Map.put(@draft, field, String.duplicate("x", limit)))
      assert {:error, {:field_too_long, ^field, ^limit}} = TaskDraft.action_args(Map.put(@draft, field, String.duplicate("x", limit + 1)))
      assert {:error, {:field_too_long, ^field, ^limit}} = TaskDraft.action_args(Map.put(@draft, field, String.duplicate("é", limit)))
    end

    assert {:error, {:field_too_long, "title", 200}} = TaskDraft.validate_lengths(%{})
  end

  test "optional details may be omitted or blank without adding empty issue sections" do
    for details <- [%{}, %{"description" => ""}, %{"verification" => ""}, %{"description" => " \n ", "verification" => "\t"}] do
      assert {:ok, %{"title" => "Title only", "body" => "Depends on: none"}} =
               TaskDraft.action_args(Map.put(details, "title", "Title only"))
    end

    assert {:ok, %{"body" => "## Description\n\nContext\n\nDepends on: none"}} =
             TaskDraft.action_args(%{"title" => "Task", "description" => "Context"})

    assert {:ok, %{"body" => "## Verification\n\nCheck it\n\nDepends on: none"}} =
             TaskDraft.action_args(%{"title" => "Task", "verification" => "Check it"})
  end
end
