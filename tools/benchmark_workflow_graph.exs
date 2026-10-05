# Run from elixir/: mix run --no-start ../tools/benchmark_workflow_graph.exs
Code.require_file("../elixir/test/fixtures/task_graph.exs", __DIR__)
alias SymphonyElixirWeb.{GraphProjection, TaskGraphFixture, WorkflowGraphView}
board = TaskGraphFixture.board()
index = GraphProjection.index(board)
overview = GraphProjection.project(index, nil)
hub = GraphProjection.project(index, "issue:1", %{"mode" => "focus", "direction" => "upstream"})

render = fn selected, options ->
  WorkflowGraphView.content(%{
    __changed__: nil,
    board: board,
    project: "fixture",
    filters: %{},
    visible_task_ids: :all,
    selected_id: selected,
    graph_index: index,
    graph_options: options
  })
  |> Phoenix.HTML.Safe.to_iodata()
  |> IO.iodata_to_binary()
end

measure = fn operation ->
  operation.()

  samples =
    Enum.map(1..7, fn _ ->
      {microseconds, _} = :timer.tc(operation)
      microseconds / 1_000
    end)
    |> Enum.sort()

  %{median_ms: Enum.at(samples, 3), p95_ms: List.last(samples)}
end

report = %{
  runtime: %{
    elixir: System.version(),
    otp: System.otp_release(),
    architecture: to_string(:erlang.system_info(:system_architecture)),
    schedulers: :erlang.system_info(:schedulers_online)
  },
  fixture: %{
    tasks: 1_000,
    dependencies: 3_000,
    milestone_groups: 20,
    hub_prerequisites: 400,
    cycle: [998, 999],
    disconnected: 1_000
  },
  index: measure.(fn -> GraphProjection.index(board) end),
  overview_projection: measure.(fn -> GraphProjection.project(index, nil) end),
  hub_projection:
    measure.(fn ->
      GraphProjection.project(index, "issue:1", %{"mode" => "focus", "direction" => "upstream"})
    end),
  overview_layout_and_render: measure.(fn -> render.(nil, %{}) end),
  hub_layout_and_render: measure.(fn -> render.("issue:1", %{"mode" => "focus", "direction" => "upstream"}) end),
  rendered: %{
    overview_nodes: length(overview["nodes"]),
    overview_arrows: length(overview["edges"]),
    hub_nodes: length(hub["nodes"]),
    hub_arrows: length(hub["edges"]),
    hub_pages: hub["pages"],
    overview_bytes: byte_size(render.(nil, %{})),
    hub_bytes: byte_size(render.("issue:1", %{"mode" => "focus", "direction" => "upstream"}))
  }
}

IO.puts(Jason.encode!(report, pretty: true))
