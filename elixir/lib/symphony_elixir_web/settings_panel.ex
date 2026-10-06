defmodule SymphonyElixirWeb.SettingsPanel do
  @moduledoc "Project settings with explicit controller, browser and runtime ownership."
  use Phoenix.Component

  alias SymphonyElixirWeb.BrowserAuth

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    assigns =
      assigns
      |> assign(:google_auth, BrowserAuth.google_enabled?())
      |> assign(:iap_auth, SymphonyElixirWeb.IAPIdentity.enabled?())
      |> assign(:return_to, assigns[:return_to] || SymphonyElixirWeb.WorkspacePath.path("/?panel=settings"))

    ~H"""
    <div class="settings-scope">
      <strong :for={project <- @board.projects}>{project.label}</strong>
      <span class="settings-badge">{cond do @read_only -> "Read-only preview"; @iap_auth -> "Cloud controller"; true -> "Local controller" end}</span>
    </div>
    <nav class="settings-tabs" aria-label="Settings sections">
      <button :for={{id, label} <- [{"execution", "Execution"}, {"ai", "AI & chat"}, {"connections", "Connections"}]}
        type="button" phx-click="settings-tab" phx-value-tab={id} aria-pressed={to_string(@tab == id)} aria-controls={"settings-#{id}"}>{label}</button>
    </nav>

    <section id="settings-execution" hidden={@tab != "execution"} aria-label="Execution settings">
      <div class="settings-section"><h3>Execution</h3><p class="muted">{@execution_status}</p>
        <p :if={@read_only} class="settings-help">This board is read-only. Controller changes are unavailable here.</p>
        <p :if={!@read_only && !@authorized} class="settings-help">{if @google_auth, do: "Sign in through Connections to make changes.", else: "Unlock operator controls in Connections to make changes."}</p>
        <div :if={!@read_only} class="dialog-actions">
          <button :for={{action, label} <- [{"drain", "Finish current work"}, {"pause", "Pause now"}, {"resume", "Resume"}]}
            class="button" disabled={!@can_control} phx-click="prepare-command" phx-value-action={action}>{label}</button>
        </div>
        <p class="settings-help">Finish current work stops new starts after active tasks finish. Pause now interrupts active tasks. Resume keeps existing launch gates and budgets.</p>
      </div>
      <div class="settings-section"><div class="settings-section-title"><h3>Concurrent tasks</h3><span class="settings-badge">New starts</span></div>
        <dl class="settings-values">
          <div><dt>Currently allowed</dt><dd>{number(value(@settings, ["concurrency", "effective"]))}</dd></div>
          <div><dt>Workflow default / ceiling</dt><dd>{number(value(@settings, ["concurrency", "default"]))} / {number(value(@settings, ["concurrency", "ceiling"]))}</dd></div>
          <div><dt>Source</dt><dd>{concurrency_source(@settings)}</dd></div>
        </dl>
        <form :if={@can_edit} id="concurrency-settings" phx-change="edit-concurrency" phx-submit="save-concurrency">
          <label class="field">Maximum concurrent tasks
            <input type="number" name="limit" min="1" max={value(@settings, ["concurrency", "ceiling"])} step="1" required value={@draft || value(@settings, ["concurrency", "effective"])} />
          </label>
          <div class="dialog-actions"><button class="button button-primary" type="submit">Save changes</button>
            <button class="button button-quiet" type="button" phx-click="cancel-settings-edit">Cancel</button>
            <button class="button button-quiet" type="button" phx-click="reset-concurrency">Use workflow default</button></div>
        </form>
        <p :if={!@settings_available} class="settings-help">This controller does not report editable settings. Update the controller to enable this feature.</p>
        <p :if={@settings_available && !@can_edit && !@read_only} class="settings-help">{if @google_auth, do: "Settings are locked or controller state is unavailable. Refresh and sign in before editing.", else: "Settings are locked or controller state is unavailable. Refresh and unlock controls before editing."}</p>
        <p class="settings-help">Lowering the limit lets active tasks finish. Raising it may admit queued work within the workflow ceiling. Budgets are unchanged.</p>
      </div>
      <div class="settings-section"><div class="settings-section-title"><h3>Per-task limits</h3><span class="settings-badge">Read-only</span></div>
        <dl class="settings-values">
          <div><dt>Attempts per work cycle</dt><dd>{number(value(@settings, ["budgets", "max_attempts"]))}</dd></div>
          <div><dt>Total runtime</dt><dd>{duration(value(@settings, ["budgets", "max_total_runtime_ms"]))}</dd></div>
          <div><dt>Total tokens</dt><dd>{number(value(@settings, ["budgets", "max_total_tokens"]))}</dd></div>
        </dl><p class="settings-help">Tokens and runtime are cumulative per task. A confirmed Retry cycle renews exhausted attempts only; lifetime usage and launch gates stay unchanged. Limit changes need a reviewed configuration change and restart.</p>
      </div>
    </section>

    <section id="settings-ai" hidden={@tab != "ai"} aria-label="AI and chat settings">
      <div class="settings-section"><h3>Conversation context</h3><p class="settings-help">The current project board view accompanies each message automatically. Inspect current and retained snapshots in the conversation’s Context tab; retrieved references appear in Sources.</p></div>
      <div class="settings-section"><div class="settings-section-title"><h3>Model presets</h3><span class="settings-badge">Read-only</span></div>
        <p :if={@read_only} class="settings-help">The connected controller does not report its model presets. Chat is unavailable in this read-only preview.</p>
        <div :if={!@read_only}>
          <dl class="settings-values">
            <div><dt>Builder</dt><dd>gpt-6-astra · medium</dd></div>
            <div><dt>Independent reviewer</dt><dd>gpt-6-astra · high</dd></div>
            <div><dt>Management chat</dt><dd>{SymphonyElixir.Chat.Runtime.model()} · medium</dd></div>
            <div><dt>Management Codex version</dt><dd>{SymphonyElixir.Chat.Runtime.supported_version()}</dd></div>
          </dl><p class="settings-help">Built-in presets for this application version. These do not establish account access or worker readiness.</p>
        </div>
        <p class="settings-help">Model changes are not supported by this settings editor. Theme, sorting and card density remain in Display.</p>
      </div>
    </section>

    <section id="settings-connections" hidden={@tab != "connections"} aria-label="Connections">
      <div class="settings-section"><div class="settings-section-title"><h3>Connection health</h3><button class="button button-quiet" phx-click="refresh-settings" disabled={@loading}>Refresh status</button></div>
        <dl class="settings-values">
          <div><dt>Issue tracker</dt><dd>{@source_status}</dd></div>
          <div><dt>Controller</dt><dd>{@execution_status}</dd></div>
          <div><dt>Management chat</dt><dd>{@chat_health}</dd></div>
          <div><dt>Model account</dt><dd>Not checked · verify through a chat turn</dd></div>
        </dl>
        <p class="settings-help">{@source_status}. Reading issues does not verify permission to write them. Refresh does not start workers or call a model.</p>
        <p :for={project <- @board.projects}><a :if={project.url} href={project.url} target="_blank" rel="noopener noreferrer">{project.label} ↗</a></p>
      </div>
      <div class="settings-section"><h3>{cond do @iap_auth -> "Google Cloud access"; @google_auth -> "Google sign-in"; true -> "Operator session" end}</h3>
        <%= cond do %>
          <% @read_only && !(@google_auth && @authorized) -> %><p class="settings-help">Controls are unavailable in this read-only view. Browser preferences can still be saved.</p>
          <% @authorized -> %>
            <p class="settings-help">{cond do @iap_auth -> "Signed in through Google Cloud IAP."; @google_auth -> "Signed in to Symphony with Google."; true -> "Local controls unlocked." end}</p>
            <form action="/operator/session/logout" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} /><button class="button button-quiet">{if @google_auth, do: "Sign out", else: "Lock controls"}</button></form>
          <% @google_auth -> %>
            <p class="settings-help">Sign in with an authorized Google account to manage work.</p>
            <form action={if @iap_auth, do: "/auth/iap", else: "/auth/google"} method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} /><input type="hidden" name="return_to" value={@return_to} />
              <button class="button button-primary">{if @iap_auth, do: "Continue to Symphony", else: "Sign in with Google"}</button></form>
          <% true -> %>
            <p class="settings-help">Unlock controls on this local host with your existing operator token.</p>
            <form action="/operator/session" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} /><input type="hidden" name="return_to" value={@return_to} />
              <label class="field">Operator token<input type="password" name="operator_token" autocomplete="off" required /></label>
              <button class="button button-primary">Unlock local controls</button></form>
        <% end %>
      </div>
      <div class="settings-section"><h3>Recorded usage</h3><p>Total tokens: {@total_tokens}</p><p>Runtime: {@runtime_duration}</p>
        <details><summary>Rate limits</summary><pre>{@rate_limits}</pre></details>
      </div>
    </section>
    """
  end

  defp value(settings, keys), do: Enum.reduce(keys, settings, fn key, map -> if is_map(map), do: Map.get(map, key), else: nil end)
  defp number(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp number(_), do: "Not reported"
  defp duration(value) when is_integer(value) and value > 0, do: "#{Float.round(value / 60_000, 1)} min"
  defp duration(_), do: "Not reported"

  defp concurrency_source(settings) do
    case value(settings, ["concurrency", "override"]) do
      n when is_integer(n) -> "Saved operator limit"
      _ -> if(value(settings, ["concurrency", "effective"]), do: "Workflow default", else: "Not reported")
    end
  end
end
