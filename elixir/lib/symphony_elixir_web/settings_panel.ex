defmodule SymphonyElixirWeb.SettingsPanel do
  @moduledoc "Project settings with explicit controller, browser and runtime ownership."
  use Phoenix.Component

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    ~H"""
    <div class="settings-scope">
      <strong :for={project <- @board.projects}>{project.label}</strong>
      <span class="settings-badge">{if @read_only, do: "Read-only view", else: "Local controller"}</span>
    </div>
    <nav class="settings-tabs" aria-label="Settings sections">
      <button :for={{id, label} <- [{"execution", "Execution"}, {"ai", "AI & chat"}, {"connections", "Connections"}]}
        type="button" phx-click="settings-tab" phx-value-tab={id} aria-pressed={to_string(@tab == id)} aria-controls={"settings-#{id}"}>{label}</button>
    </nav>

    <section id="settings-execution" hidden={@tab != "execution"} aria-label="Execution settings">
      <div class="settings-section"><h3>Execution</h3><p class="muted">{@execution_status}</p>
        <p :if={@read_only} class="settings-help">This board is read-only. Controller changes are unavailable here.</p>
        <p :if={!@read_only && !@authorized} class="settings-help">Unlock operator controls in Connections to make changes.</p>
        <div :if={!@read_only} class="dialog-actions">
          <button :for={{action, label} <- [{"drain", "Drain"}, {"pause", "Pause"}, {"resume", "Resume"}]}
            class="button" disabled={!@can_control} phx-click="prepare-command" phx-value-action={action}>{label}</button>
        </div>
        <p class="settings-help">Drain finishes active work. Pause interrupts it. Resume keeps existing launch gates and budgets.</p>
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
        <p :if={@settings_available && !@can_edit && !@read_only} class="settings-help">Settings are locked or controller state is unavailable. Refresh and unlock controls before editing.</p>
        <p class="settings-help">Lowering the limit lets active tasks finish. Raising it may admit queued work within the workflow ceiling. Budgets are unchanged.</p>
      </div>
      <div class="settings-section"><div class="settings-section-title"><h3>Per-task limits</h3><span class="settings-badge">Read-only</span></div>
        <dl class="settings-values">
          <div><dt>Attempts</dt><dd>{number(value(@settings, ["budgets", "max_attempts"]))}</dd></div>
          <div><dt>Total runtime</dt><dd>{duration(value(@settings, ["budgets", "max_total_runtime_ms"]))}</dd></div>
          <div><dt>Total tokens</dt><dd>{number(value(@settings, ["budgets", "max_total_tokens"]))}</dd></div>
        </dl><p class="settings-help">Cumulative per task, including retries. Budget changes need a reviewed configuration change and restart.</p>
      </div>
    </section>

    <section id="settings-ai" hidden={@tab != "ai"} aria-label="AI and chat settings">
      <div class="settings-section"><div class="settings-section-title"><h3>Chat context defaults</h3><span class="settings-badge">This browser</span></div>
        <form :if={@project_id} id="chat-preferences" phx-hook="ChatPreferences" phx-update="ignore" data-project={@project_id}>
          <label class="settings-check"><input type="checkbox" data-chat-pref="share_context" checked /> Share the current board view</label>
          <label class="settings-check"><input type="checkbox" data-chat-pref="include_selected" checked /> Identify the selected card</label>
          <p class="settings-help">Saved in this browser for this project. Applies to the next message and future visits; earlier messages are unchanged. You can override these in the composer.</p>
          <div class="dialog-actions"><button class="button button-primary" type="button" data-chat-prefs-save>Save preferences</button>
            <button class="button button-quiet" type="button" data-chat-prefs-cancel>Cancel</button>
            <button class="button button-quiet" type="button" data-chat-prefs-reset>Restore defaults</button></div>
          <p data-chat-prefs-status role="status" class="settings-help"></p>
        </form>
        <p :if={!@project_id} class="settings-help">Select one project to set chat preferences.</p>
      </div>
      <div class="settings-section"><div class="settings-section-title"><h3>Model presets</h3><span class="settings-badge">Read-only</span></div>
        <p :if={@read_only} class="settings-help">The connected controller does not report its model presets. Chat is unavailable in this read-only view.</p>
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
      <div class="settings-section"><h3>Operator session</h3>
        <%= cond do %>
          <% @read_only -> %><p class="settings-help">Controls are unavailable in this read-only view. Browser preferences can still be saved.</p>
          <% @authorized -> %>
            <p class="settings-help">Local controls unlocked.</p>
            <form action="/operator/session/logout" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} /><button class="button button-quiet">Lock controls</button></form>
          <% true -> %>
            <p class="settings-help">Unlock controls on this local host with your existing operator token.</p>
            <form action="/operator/session" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} />
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
