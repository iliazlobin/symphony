// Project storage owns the draft. Browser storage is a recovery copy, never an
// implicit import or an authority to overwrite a different saved document.
(() => {
  const canonical = value => JSON.stringify(sort(value));
  const sort = value => Array.isArray(value) ? value.map(sort) : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sort(value[key])])) : value;
  const content = scene => scene && canonical({project: scene.project, document_id: scene.document_id, boards:
    Object.fromEntries(Object.entries(scene.boards).map(([section, board]) => [section, board.elements.map(element =>
      Object.fromEntries(Object.entries(element).filter(([key]) => !["version", "versionNonce", "updated", "index"].includes(key))))]))});
  class DesignSync {
    constructor(hook) {
      this.hook = hook; this.el = hook.el; this.project = this.el.dataset.designProject;
      this.revision = 0; this.ready = false; this.conflict = false; this.pending = null; this.busy = false;
      this.abort = new AbortController(); this.baseline = null; this.reviewed = null;
      this.el.addEventListener("click", event => {
        if (event.target.closest("[data-design-use-saved]")) this.useSaved();
        if (event.target.closest("[data-design-import]")) this.importDraft();
        if (event.target.closest("[data-design-review]")) this.showReview();
        if (event.target.closest("[data-design-review-close]")) this.panel(false);
        if (event.target.closest("[data-design-confirm-review]")) this.review();
      }, {signal: this.abort.signal});
      this.el.addEventListener("keydown", event => {
        if (event.key === "Escape" && !this.el.querySelector("[data-design-review-panel]")?.hidden) {
          event.preventDefault(); this.panel(false);
        }
      }, {signal: this.abort.signal});
    }
    request(event, args = {}) {
      return new Promise(resolve => {
        const timer = setTimeout(() => resolve({ok: false, error: "design_request_unconfirmed"}), 8000);
        this.hook.pushEvent(event, {project: this.project, ...args}, reply => { clearTimeout(timer); resolve(reply); });
      });
    }
    async open(local) {
      const reply = await this.request("design-load");
      if (!reply.ok) { this.error(reply.error); return local; }
      if (reply.data.draft && !this.hook.editor.validate(reply.data.draft, this.project)) {
        this.error("design_scene_invalid"); return local;
      }
      this.accept(reply.data); this.serverDraft = reply.data.draft;
      await this.loadBaseline();
      if (this.abort.signal.aborted) return local;
      if (local && this.serverDraft && canonical(local) !== canonical(this.serverDraft)) {
        this.conflict = true;
        this.recovery("This browser has a different draft. Both copies are kept.", true, false);
        this.status("Choose a draft before saving to the project"); return local;
      }
      if (local && !this.serverDraft) {
        this.recovery("A browser draft is available. Save it to the project when ready.", false, true);
        this.status("Browser recovery · not saved to project"); return local;
      }
      this.ready = true; this.status(this.reviewed ? "Saved to project · reviewed version available" : "Project draft · autosaves");
      return this.serverDraft || local;
    }
    accept(data) {
      this.revision = data.storage_revision; this.reviewed = data.reviewed; this.serverDraft = data.draft;
    }
    async loadBaseline(ref = this.reviewed?.ref) {
      if (!ref) { this.baseline = null; return; }
      const reply = await this.request("design-reviewed", {ref});
      if (this.abort.signal.aborted || ref !== this.reviewed?.ref) return;
      if (reply.ok && this.hook.editor.validate(reply.data.scene, this.project)) this.baseline = reply.data.scene;
      else this.error(reply.error);
    }
    canWrite() { return this.ready && !this.conflict && !this.abort.signal.aborted; }
    currentSaved() { return this.canWrite() && !this.busy && !this.pending && content(this.hook.canvas?.document()) === content(this.serverDraft); }
    async saveCurrent() {
      const visible = content(this.hook.canvas?.document());
      this.hook.flush(); this.hook.save();
      while (this.busy && !this.abort.signal.aborted) await this.saving;
      return this.hook.canvas?.canSave() && this.currentSaved() && content(this.hook.canvas?.document()) === visible;
    }
    save(scene) {
      if (!this.canWrite() || !scene) return;
      if (!this.busy && canonical(scene) === canonical(this.serverDraft)) { this.status("Saved to project"); return; }
      this.pending = scene; this.status("Saving to project…"); this.drain();
    }
    async drain() {
      if (this.busy || !this.canWrite() || !this.pending) return;
      this.busy = true;
      const scene = this.pending; this.pending = null;
      this.saving = this.request("design-save", {storage_revision: this.revision, scene});
      const reply = await this.saving;
      this.busy = false;
      if (this.abort.signal.aborted) return;
      if (!reply.ok) {
        this.conflict = true; this.pending = null; this.error(reply.error);
        this.recovery("Your edits are kept in this browser. Reload to check the saved project draft.", false, false); return;
      }
      this.accept(reply.data);
      if (this.pending) this.drain(); else this.status("Saved to project");
    }
    useSaved() {
      if (!this.serverDraft || !this.hook.canvas?.canSave()) return;
      this.ready = false;
      // Preserve a complete original before the explicit choice replaces a
      // browser recovery copy, including when its document identity differs.
      try {
        if (this.hook.loadedRaw) {
          let key = this.hook.key + ":recovery:" + Date.now();
          while (localStorage.getItem(key) !== null) key += "-copy";
          localStorage.setItem(key, this.hook.loadedRaw);
        }
      } catch { this.status("Could not keep the browser recovery. Export it before opening the project draft."); return; }
      if (!this.hook.canvas.replace(this.serverDraft)) return;
      this.conflict = false; this.ready = true; this.recovery("", false, false); this.hook.save();
    }
    importDraft() {
      if (this.serverDraft || !this.hook.canvas?.canSave()) return;
      this.conflict = false; this.ready = true; this.recovery("", false, false); this.hook.save();
    }
    showReview() {
      if (!this.hook.canvas?.canSave()) { this.status("Undo or export the unsaved drawing before reviewing it."); return; }
      if (!this.canWrite()) { this.status("Save the draft to this project before reviewing it."); return; }
      this.hook.flush(); this.hook.save(); this.panel(true);
      const confirm = this.el.querySelector("[data-design-confirm-review]"); if (confirm) confirm.hidden = false;
      const description = this.el.querySelector("[data-design-review-description]"); if (description) description.textContent = "Save this version as the design baseline. You can keep editing a new draft.";
      const changes = this.hook.canvas?.changes(this.baseline) || [];
      const list = this.el.querySelector("[data-design-change-list]"); list?.replaceChildren();
      for (const change of changes) {
        const row = this.el.ownerDocument.createElement("li"); row.textContent = `${change.change} · ${change.section} · ${change.title}`; list?.append(row);
      }
      if (!changes.length && list) {
        const row = this.el.ownerDocument.createElement("li"); row.textContent = "No design changes since the reviewed version."; list.append(row);
      }
      const label = this.el.querySelector("[data-design-review-label]");
      if (label) label.textContent = this.reviewed ? "Previous version remains available to linked tasks." : "First reviewed version";
    }
    async review() {
      if (!this.hook.canvas?.canSave()) { this.status("Undo or export the unsaved drawing before reviewing it."); return; }
      if (!await this.saveCurrent()) { this.status("Save the current drawing before marking this version reviewed. Check the storage message if saving is blocked."); return; }
      const reply = await this.request("design-review", {storage_revision: this.revision});
      if (this.abort.signal.aborted) return;
      if (!reply.ok) { this.error(reply.error); return; }
      this.accept(reply.data); await this.loadBaseline(); this.panel(false); this.status("Design reviewed · keep editing the next draft");
    }
    async plan(section, item) {
      if (!this.hook.canvas?.canSave()) { this.status("Undo or export the unsaved drawing before preparing a task."); return; }
      if (!this.reviewed) { this.status("Review this design version before preparing tasks."); return; }
      if (!await this.saveCurrent()) { this.status("Save the current drawing before preparing a task. Check the storage message if saving is blocked."); return; }
      const reply = await this.request("prepare-design-task", {ref: this.reviewed.ref, section, item});
      if (!reply.ok) this.error(reply.error);
    }
    async sourceReference() {
      if (typeof window.location === "undefined") return;
      const url = new URL(window.location.href), ref = url.searchParams.get("design_ref"), section = url.searchParams.get("design_section"), item = url.searchParams.get("design_item");
      if (!ref || !section || !item) { if (this.sourceKey) this.panel(false); this.sourceKey = null; return; }
      const sourceKey = [ref, section, item, url.searchParams.get("design_task")].join("/");
      if (sourceKey === this.sourceKey) return;
      this.sourceKey = sourceKey;
      const reply = await this.request("design-reviewed", {ref});
      if (this.abort.signal.aborted || this.sourceKey !== sourceKey) return;
      const scene = reply.ok && this.hook.editor.validate(reply.data.scene, this.project);
      const members = scene?.boards[section]?.elements.filter(element => !element.isDeleted && element.customData?.symphony?.id === item) || [];
      if (!members.some(element => element.customData?.symphony?.role === "node")) { this.error("design_item_not_reviewed"); return; }
      this.hook.select(section); this.panel(true);
      const confirm = this.el.querySelector("[data-design-confirm-review]"); if (confirm) confirm.hidden = true;
      const description = this.el.querySelector("[data-design-review-description]");
      if (description) description.textContent = "This is the reviewed version referenced by the task. The current draft stays unchanged.";
      const list = this.el.querySelector("[data-design-change-list]"); list?.replaceChildren();
      for (const role of ["title", "body"]) {
        const member = members.find(element => element.customData?.symphony?.role === role);
        const row = this.el.ownerDocument.createElement("li"); row.textContent = member?.originalText || member?.text || ""; row.style.whiteSpace = "pre-wrap"; list?.append(row);
      }
      const label = this.el.querySelector("[data-design-review-label]");
      if (label) {
        label.replaceChildren(); label.textContent = "Reviewed " + reply.data.reviewed_at;
        const task = url.searchParams.get("design_task");
        if (task?.startsWith(this.project + ":")) {
          for (const key of ["design_ref", "design_section", "design_item", "design_task"]) url.searchParams.delete(key);
          url.searchParams.set("view", "kanban"); url.searchParams.set("task", task);
          const link = this.el.ownerDocument.createElement("a"); link.href = url.pathname + url.search; link.textContent = "Back to task →"; label.append(link);
        }
      }
    }
    error(code) {
      const errors = {
        stale_design_revision: "Project draft changed elsewhere · reload; your browser copy is kept",
        design_document_mismatch: "Different design documents · open the project draft; the browser copy is kept",
        design_request_unconfirmed: "Save not confirmed · reload to check; your browser copy is kept",
        design_scope_changed: "Project configuration changed · reload before saving",
        design_storage_full: "Design storage is full · history and browser edits are kept",
        design_storage_locked: "Another engine owns this design · use that engine",
        design_item_not_reviewed: "Select an item in the reviewed version, or review your changes first",
        design_task_pending: "A task preview is already pending · finish it before preparing another",
        design_item_too_large: "Shorten this item to a scoped outcome before preparing a task",
        unauthorized: "Sign in again to save this project design"
      };
      this.status(errors[code] || "Project design unavailable · your browser draft is kept");
    }
    recovery(message, saved, importing) {
      const panel = this.el.querySelector("[data-design-recovery]"); if (!panel) return;
      panel.hidden = !message;
      const label = panel.querySelector("[data-design-recovery-message]"); if (label) label.textContent = message;
      const use = panel.querySelector("[data-design-use-saved]"); if (use) use.hidden = !saved;
      const copy = panel.querySelector("[data-design-import]"); if (copy) copy.hidden = !importing;
    }
    panel(open) {
      const panel = this.el.querySelector("[data-design-review-panel]"); if (!panel) return;
      panel.hidden = !open;
      if (open) { this.reviewFocus = this.el.ownerDocument.activeElement; panel.querySelector("[data-design-review-close]")?.focus(); }
      else this.reviewFocus?.focus();
    }
    status(text) { if (!this.abort.signal.aborted) this.hook.status(text); }
    destroy() { this.abort.abort(); }
  }
  window.SymphonyDesignSync = DesignSync;
})();
