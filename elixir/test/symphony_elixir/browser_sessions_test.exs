defmodule SymphonyElixir.BrowserSessionsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixirWeb.BrowserSessions

  test "flow is consumed exactly once even across concurrent callbacks, sessions are revocable" do
    server = start_supervised!({BrowserSessions, name: nil})
    assert {:ok, flow} = BrowserSessions.issue(:flow, %{nonce: "test"}, server)
    assert byte_size(flow) == 43
    results = 1..8 |> Task.async_stream(fn _ -> BrowserSessions.take_flow(flow, server) end) |> Enum.map(fn {:ok, value} -> value end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, session} = BrowserSessions.issue(:session, %{sub: "operator"}, server)
    assert {:error, :expired} = BrowserSessions.take_flow(session, server)
    assert {:ok, %{sub: "operator"}} = BrowserSessions.session(session, server)
    assert :ok = BrowserSessions.revoke(session, server)
    assert {:error, :expired} = BrowserSessions.session(session, server)
    assert {:error, :invalid} = BrowserSessions.issue(:other, %{}, server)
  end

  test "capacity, TTL and process restart fail closed" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    server = start_supervised!({BrowserSessions, name: nil, capacity: 2, clock: fn -> Agent.get(clock, & &1) end})
    assert {:ok, flow} = BrowserSessions.issue(:flow, %{}, server)
    assert {:ok, session} = BrowserSessions.issue(:session, %{}, server)
    assert {:error, :capacity} = BrowserSessions.issue(:flow, %{}, server)
    Agent.update(clock, fn _ -> 600 end)
    assert {:error, :expired} = BrowserSessions.take_flow(flow, server)
    assert {:ok, %{}} = BrowserSessions.session(session, server)
    Agent.update(clock, fn _ -> 28_800 end)
    assert {:error, :expired} = BrowserSessions.session(session, server)
    assert {:ok, id} = BrowserSessions.issue(:session, %{}, server)
    stop_supervised!(BrowserSessions)
    assert {:error, :unavailable} = BrowserSessions.session(id, server)
    replacement = start_supervised!({BrowserSessions, name: nil})
    assert {:error, :expired} = BrowserSessions.session(id, replacement)
  end

  test "claimed flows remain revocable and expire while completion replaces their capacity slot" do
    clock = start_supervised!({Agent, fn -> 0 end})
    server = start_supervised!({BrowserSessions, name: nil, capacity: 1, clock: fn -> Agent.get(clock, & &1) end})
    assert {:ok, flow} = BrowserSessions.issue(:flow, %{nonce: "test"}, server)
    assert {:error, :expired} = BrowserSessions.complete_flow(flow, %{}, server)
    assert {:ok, %{nonce: "test"}} = BrowserSessions.take_flow(flow, server)
    assert {:error, :expired} = BrowserSessions.session(flow, server)
    assert {:error, :capacity} = BrowserSessions.issue(:flow, %{}, server)
    assert {:ok, ^flow} = BrowserSessions.complete_flow(flow, %{sub: "operator"}, server)
    assert {:error, :expired} = BrowserSessions.complete_flow(flow, %{sub: "different"}, server)
    assert {:ok, %{sub: "operator"}} = BrowserSessions.session(flow, server)
    assert :ok = BrowserSessions.revoke(flow, server)
    assert {:error, :expired} = BrowserSessions.session(flow, server)

    assert {:ok, expired} = BrowserSessions.issue(:flow, %{}, server)
    assert {:ok, %{}} = BrowserSessions.take_flow(expired, server)
    Agent.update(clock, fn _ -> 600 end)
    assert {:error, :expired} = BrowserSessions.complete_flow(expired, %{}, server)

    assert {:ok, revoked} = BrowserSessions.issue(:flow, %{}, server)
    assert {:ok, %{}} = BrowserSessions.take_flow(revoked, server)
    assert :ok = BrowserSessions.revoke(revoked, server)
    assert {:error, :expired} = BrowserSessions.complete_flow(revoked, %{}, server)
  end
end
