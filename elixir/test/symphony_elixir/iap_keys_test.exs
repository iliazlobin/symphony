Code.require_file("../support/iap_support.exs", __DIR__)

defmodule SymphonyElixir.IAPKeysTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.IAPFixture
  alias SymphonyElixirWeb.{BrowserSessions, IAPKeys}

  setup do
    {_private, public} = IAPFixture.key_pair()
    previous = Application.get_env(:symphony_elixir, :iap_http_plug)
    {:ok, clock} = Agent.start_link(fn -> -1_000 end)
    server = start_supervised!({IAPKeys, name: nil, clock: fn -> Agent.get(clock, & &1) end})
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, owner: self(), keys: %{"fixture" => public}})

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :iap_http_plug, previous)
      else
        Application.delete_env(:symphony_elixir, :iap_http_plug)
      end
    end)

    %{server: server, clock: clock, public: public}
  end

  test "negative monotonic time still performs the first fetch and cached reads avoid network work", ctx do
    assert {:ok, ctx.public} == IAPKeys.key("fixture", ctx.server)
    assert_received :iap_keys_requested
    assert {:ok, ctx.public} == IAPKeys.key("fixture", ctx.server)
    refute_received :iap_keys_requested
    assert {:error, :identity_unavailable} = IAPKeys.key("unknown", ctx.server)
    refute_received :iap_keys_requested
  end

  test "rotation refreshes once when eligible and never returns expired keys after failure", ctx do
    assert {:ok, _} = IAPKeys.key("fixture", ctx.server)
    assert_received :iap_keys_requested
    Agent.update(ctx.clock, &(&1 + 31))
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, owner: self(), keys: %{"rotated" => ctx.public}})
    assert {:ok, ctx.public} == IAPKeys.key("rotated", ctx.server)
    assert_received :iap_keys_requested
    assert {:error, :identity_unavailable} = IAPKeys.key("fixture", ctx.server)
    refute_received :iap_keys_requested
    Agent.update(ctx.clock, &(&1 + 61))
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, owner: self(), keys: %{}, status: 503})
    assert {:error, :identity_unavailable} = IAPKeys.key("rotated", ctx.server)
    assert_received :iap_keys_requested
    assert {:error, :identity_unavailable} = IAPKeys.key("rotated", ctx.server)
    refute_received :iap_keys_requested
  end

  test "an unknown key failure does not invalidate a still fresh verified key", ctx do
    assert {:ok, _} = IAPKeys.key("fixture", ctx.server)
    assert_received :iap_keys_requested
    Agent.update(ctx.clock, &(&1 + 31))
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, owner: self(), keys: %{}, status: 503})
    assert {:error, :identity_unavailable} = IAPKeys.key("unknown", ctx.server)
    assert_received :iap_keys_requested
    assert {:ok, ctx.public} == IAPKeys.key("fixture", ctx.server)
    refute_received :iap_keys_requested
  end

  test "redirects, malformed keys and non-P256 key material fail closed", ctx do
    wrong_curve = :public_key.generate_key({:namedCurve, {1, 3, 132, 0, 34}})
    public_key = {{:ECPoint, elem(wrong_curve, 4)}, {:namedCurve, {1, 3, 132, 0, 34}}}
    wrong_curve = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    for {status, keys} <- [
          {302, %{"fixture" => ctx.public}},
          {200, %{}},
          {200, []},
          {200, %{"fixture" => "invalid PEM"}},
          {200, %{"fixture" => wrong_curve}},
          {200, %{"fixture" => String.duplicate("x", 4_097)}},
          {200, Map.new(1..21, &{to_string(&1), ctx.public})}
        ] do
      response_options = [owner: self(), keys: keys, status: status]
      Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, response_options})
      Agent.update(ctx.clock, &(&1 + 31))
      assert {:error, :identity_unavailable} = IAPKeys.key("fixture", ctx.server)
      assert_received :iap_keys_requested
      refute_received :iap_keys_requested
    end
  end

  test "response cache lifetime is bounded even when the provider supplies a larger max-age", ctx do
    response_options = [owner: self(), keys: %{"fixture" => ctx.public}, cache: "public, max-age=999999"]
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, response_options})
    assert {:ok, _} = IAPKeys.key("fixture", ctx.server)
    assert_received :iap_keys_requested
    Agent.update(ctx.clock, &(&1 + 3_599))
    assert {:ok, _} = IAPKeys.key("fixture", ctx.server)
    refute_received :iap_keys_requested
    Agent.update(ctx.clock, &(&1 + 2))
    assert {:ok, _} = IAPKeys.key("fixture", ctx.server)
    assert_received :iap_keys_requested
  end

  test "stopped key owner yields sanitized unavailable rather than an exception", ctx do
    GenServer.stop(ctx.server)
    assert {:error, :identity_unavailable} = IAPKeys.key("fixture", ctx.server)
  end

  test "IAP grants expire with assertion lifetime while ordinary local grants retain their existing lifetime" do
    {:ok, clock} = Agent.start_link(fn -> -1_000 end)
    server = start_supervised!({BrowserSessions, name: nil, clock: fn -> Agent.get(clock, & &1) end})
    {:ok, iap} = BrowserSessions.issue(:session, %{provider: "iap", identity: %{"exp" => System.system_time(:second) + 600}}, server)
    {:ok, local} = BrowserSessions.issue(:session, %{local: true}, server)
    assert {:ok, _} = BrowserSessions.session(iap, server)
    Agent.update(clock, &(&1 + 661))
    assert {:error, :expired} = BrowserSessions.session(iap, server)
    assert {:ok, %{local: true}} = BrowserSessions.session(local, server)
    Agent.update(clock, &(&1 + 28_800))
    assert {:error, :expired} = BrowserSessions.session(local, server)
  end
end
