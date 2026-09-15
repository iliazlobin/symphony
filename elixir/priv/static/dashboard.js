(() => {
  "use strict";
  const lanes = [["backlog", "Backlog"], ["ready", "Ready"], ["running", "Running"], ["review", "Review"], ["done", "Done"]];
  const parse = (text, fallback) => { try { return JSON.parse(text); } catch { return fallback; } };
  const escapeText = value => String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"}[c]));
  const storage = { get(key) { try { return localStorage.getItem(key); } catch { return null; } }, set(key, value) { try { localStorage.setItem(key, value); } catch { /* Preferences are optional. */ } } };

  const TaskBoard = {
    mounted() {
      this.prefs = {project: [], status: [], priority: [], query: "", sort: "manual", order: {}, lane: "ready"};
      this.popup = null;
      this.activeOption = 0;
      this.drag = null;
      this.scope = null;
      this.abort = new AbortController();
      const on = (name, handler) => this.el.addEventListener(name, handler, {signal: this.abort.signal});
      this.options = key => key === "project" ? parse(this.el.dataset.projects, []).map(p => [p.id, p.label]) : key === "status" ? [...lanes, ["attention", "Needs input"]] : [["P1", "P1 · High"], ["P2", "P2 · Normal"], ["P3", "P3 · Low"], ["P4", "P4 · Lowest"], ["—", "Unspecified"]];
      this.load = () => {
        const scope = this.el.dataset.scope;
        if (!scope || this.scope === scope) return;
        this.scope = scope;
        this.key = "symphony.board.v1:" + scope;
        const parsed = parse(storage.get(this.key), {});
        const saved = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
        for (const k of ["project", "status", "priority"]) this.prefs[k] = Array.isArray(saved[k]) ? saved[k].filter(v => typeof v === "string") : [];
        this.prefs.query = typeof saved.query === "string" ? saved.query : "";
        this.prefs.sort = ["manual", "priority", "updated", "oldest", "title"].includes(saved.sort) ? saved.sort : "manual";
        this.prefs.lane = lanes.some(([id]) => id === saved.lane) ? saved.lane : "ready";
        this.prefs.order = saved.order && typeof saved.order === "object" && !Array.isArray(saved.order) ? saved.order : {};
        this.el.querySelector("[data-board-search]").value = this.prefs.query;
        this.el.querySelector("[data-board-sort]").value = this.prefs.sort;
      };
      this.urlKey = null;
      this.readURL = () => {
        const encoded = this.el.dataset.urlFilters || "{}";
        if (this.urlKey === encoded) return;
        const initial = this.urlKey === null;
        this.urlKey = encoded;
        const filters = parse(encoded, {});
        if (initial && !Object.keys(filters).length) return;
        for (const key of ["project", "status", "priority"]) this.prefs[key] = typeof filters[key] === "string" ? filters[key].split(",").filter(Boolean) : [];
        this.prefs.query = typeof filters.q === "string" ? filters.q : "";
        this.prefs.sort = ["manual", "priority", "updated", "oldest", "title"].includes(filters.sort) ? filters.sort : "manual";
        this.el.querySelector("[data-board-search]").value = this.prefs.query;
        this.el.querySelector("[data-board-sort]").value = this.prefs.sort;
      };
      this.save = () => {
        if (this.key) storage.set(this.key, JSON.stringify(this.prefs));
        clearTimeout(this.urlTimer);
        this.urlTimer = setTimeout(() => {
          const filters = {project: this.prefs.project.join(","), status: this.prefs.status.join(","), priority: this.prefs.priority.join(","), q: this.prefs.query, sort: this.prefs.sort};
          for (const key of Object.keys(filters)) if (!filters[key] || (key === "sort" && filters[key] === "manual")) delete filters[key];
          const current = parse(this.el.dataset.urlFilters || "{}", {});
          if (Object.keys({...filters, ...current}).some(key => filters[key] !== current[key])) this.pushEvent("board-filters", filters);
        }, 180);
      };
      this.closeFilter = () => {
        if (!this.popup) return;
        const key = this.popup;
        this.popup = null;
        this.el.querySelector("#filter-" + key).value = "";
        this.drawOptions(key);
      };
      this.drawOptions = key => {
        const input = this.el.querySelector("#filter-" + key), list = this.el.querySelector("#options-" + key);
        const options = this.options(key).filter(([, label]) => label.toLowerCase().includes(input.value.toLowerCase()));
        this.activeOption = Math.min(Math.max(0, this.activeOption), Math.max(0, options.length - 1));
        input.setAttribute("aria-expanded", String(this.popup === key));
        list.hidden = this.popup !== key;
        list.innerHTML = options.length ? options.map(([value, label], i) => `<button type="button" role="option" class="combo-option" id="option-${key}-${i}" data-key="${key}" data-value="${escapeText(value)}" data-active="${i === this.activeOption}" aria-selected="${this.prefs[key].includes(value)}"><span>${escapeText(label)}</span><span aria-hidden="true">${this.prefs[key].includes(value) ? "✓" : ""}</span></button>`).join("") : '<p class="option-empty">No matches</p>';
        if (this.popup === key && options.length) input.setAttribute("aria-activedescendant", `option-${key}-${this.activeOption}`);
        else input.removeAttribute("aria-activedescendant");
        return options;
      };
      this.openFilter = key => { if (this.popup !== key) this.closeFilter(); this.popup = key; this.activeOption = 0; this.drawOptions(key); };
      this.toggle = (key, value) => {
        this.prefs[key] = this.prefs[key].includes(value) ? this.prefs[key].filter(v => v !== value) : [...this.prefs[key], value];
        this.el.querySelector("#filter-" + key).value = "";
        this.activeOption = 0; this.drawOptions(key); this.apply(); this.save();
        this.el.querySelector("#filter-" + key).focus();
      };
      this.announce = message => {
        let status = this.el.querySelector("[data-board-announcement]");
        if (!status) { status = document.createElement("p"); status.dataset.boardAnnouncement = ""; status.className = "board-notice"; status.setAttribute("role", "status"); this.el.querySelector(".board-content").prepend(status); }
        status.textContent = message;
      };
      this.apply = () => {
        this.load();
        this.readURL();
        const cards = [...this.el.querySelectorAll("[data-task-id]")];
        let visible = 0;
        for (const card of cards) {
          const d = card.dataset, stage = card.closest("[data-stage]").dataset.stage;
          const matches = (!this.prefs.project.length || this.prefs.project.includes(d.project)) && (!this.prefs.priority.length || this.prefs.priority.includes(d.priority)) && (!this.prefs.status.length || this.prefs.status.includes(stage) || (this.prefs.status.includes("attention") && d.attention === "true")) && (!this.prefs.query || [d.title, d.identifier].join(" ").toLowerCase().includes(this.prefs.query.toLowerCase()));
          card.hidden = !matches; if (matches) visible++;
        }
        this.el.querySelector("[data-result-count]").textContent = `${visible} of ${cards.length} tasks`;
        for (const [stage] of lanes) {
          const lane = this.el.querySelector(`[data-stage="${stage}"]`), container = lane.querySelector("[data-lane-cards]");
          const items = [...container.children];
          const rank = id => { const order = this.prefs.order[stage]; const index = Array.isArray(order) ? order.indexOf(id) : -1; return index < 0 ? 100000 : index; };
          const date = value => Date.parse(value) || 0;
          const priorityRank = value => /^P[1-9]\d*$/.test(value) ? Number(value.slice(1)) : Number.MAX_SAFE_INTEGER;
          items.sort((a,b) => this.prefs.sort === "priority" ? priorityRank(a.dataset.priority) - priorityRank(b.dataset.priority) : this.prefs.sort === "updated" ? date(b.dataset.updated) - date(a.dataset.updated) : this.prefs.sort === "oldest" ? (date(a.dataset.created) || Infinity) - (date(b.dataset.created) || Infinity) : this.prefs.sort === "title" ? a.dataset.title.localeCompare(b.dataset.title) : rank(a.dataset.taskId) - rank(b.dataset.taskId));
          items.forEach(item => container.append(item));
          const count = items.filter(item => !item.hidden).length;
          lane.querySelector("[data-lane-count]").textContent = count;
          lane.querySelector("[data-lane-empty]").hidden = count !== 0;
          lane.querySelector("[data-lane-empty]").textContent = visible ? "No matching tasks" : "No tasks match";
        }
        const current = this.el.querySelector(`[data-stage="${this.prefs.lane}"]`);
        if (!current || (current.querySelectorAll(".task-card:not([hidden])").length === 0 && visible)) this.prefs.lane = lanes.find(([s]) => this.el.querySelector(`[data-stage="${s}"] .task-card:not([hidden])`))?.[0] || "ready";
        this.el.querySelectorAll("[data-stage]").forEach(el => el.dataset.mobileActive = String(el.dataset.stage === this.prefs.lane));
        const mobile = this.el.querySelector("[data-mobile-lane]"); mobile.value = this.prefs.lane;
        for (const option of mobile.options) option.textContent = `${lanes.find(([s]) => s === option.value)[1]} (${this.el.querySelector(`[data-stage="${option.value}"] [data-lane-count]`).textContent})`;
        this.el.querySelector("[data-filter-chips]").innerHTML = ["project", "status", "priority"].flatMap(key => this.prefs[key].map(value => { const label = this.options(key).find(([id]) => id === value)?.[1] || value; return `<button type="button" class="filter-chip" data-remove-key="${key}" data-remove-value="${escapeText(value)}" aria-label="Remove ${key} filter ${escapeText(label)}">${escapeText(label)} <span aria-hidden="true">×</span></button>`; })).join("");
        for (const key of ["project", "status", "priority"]) this.el.querySelector("#filter-" + key).placeholder = `${key[0].toUpperCase() + key.slice(1)}: ${this.prefs[key].length ? this.prefs[key].length + " selected" : "All"}`;
      };
      on("focusin", event => { const key = event.target.closest("[data-filter]")?.dataset.filter; if (key && event.target.matches("input")) this.openFilter(key); });
      on("input", event => { const key = event.target.closest("[data-filter]")?.dataset.filter; if (key) { this.popup = key; this.activeOption = 0; this.drawOptions(key); } else if (event.target.matches("[data-board-search]")) { this.prefs.query = event.target.value; this.apply(); this.save(); } });
      on("keydown", event => {
        const key = event.target.closest("[data-filter]")?.dataset.filter;
        if (!key || !event.target.matches("input")) return;
        if (["ArrowDown", "ArrowUp"].includes(event.key)) { event.preventDefault(); if (this.popup !== key) this.openFilter(key); else { this.activeOption += event.key === "ArrowDown" ? 1 : -1; this.drawOptions(key); } }
        else if (event.key === "Enter" && this.popup === key) { event.preventDefault(); const choice = this.drawOptions(key)[this.activeOption]; if (choice) this.toggle(key, choice[0]); }
        else if (["Escape", "Tab"].includes(event.key)) this.closeFilter();
      });
      on("click", event => {
        const button = event.target.closest("button"); if (!button) return;
        if (button.dataset.filterToggle) { const key = button.dataset.filterToggle; if (this.popup === key) this.closeFilter(); else { this.openFilter(key); this.el.querySelector("#filter-" + key).focus(); } }
        else if (button.dataset.key) this.toggle(button.dataset.key, button.dataset.value);
        else if (button.dataset.removeKey) { this.prefs[button.dataset.removeKey] = this.prefs[button.dataset.removeKey].filter(v => v !== button.dataset.removeValue); this.apply(); this.save(); }
        else if (button.hasAttribute("data-clear-filters")) { this.prefs.project = []; this.prefs.status = []; this.prefs.priority = []; this.prefs.query = ""; this.el.querySelector("[data-board-search]").value = ""; this.closeFilter(); this.apply(); this.save(); }
        else if (button.dataset.copy) navigator.clipboard?.writeText(button.dataset.copy).then(() => { button.textContent = "Copied"; }).catch(() => { button.textContent = "Copy unavailable"; });
      });
      on("change", event => {
        if (event.target.hasAttribute("data-board-sort")) { this.prefs.sort = event.target.value; this.apply(); this.save(); }
        else if (event.target.hasAttribute("data-mobile-lane")) { this.prefs.lane = event.target.value; this.apply(); this.save(); }
        else if (event.target.dataset.moveTask && event.target.value) { const stage = event.target.value; event.target.value = ""; this.pushEvent("move-task", {id: event.target.dataset.moveTask, stage}); }
      });
      on("dragstart", event => { const card = event.target.closest("[data-task-id]"); if (!card || event.target.closest("select,a")) return; this.drag = card; card.classList.add("dragging"); event.dataTransfer.effectAllowed = "move"; event.dataTransfer.setData("text/plain", card.dataset.taskId); });
      const clearDrop = () => this.el.querySelectorAll(".drop-target,.drop-before,.drop-after").forEach(el => el.classList.remove("drop-target", "drop-before", "drop-after"));
      on("dragover", event => { const lane = event.target.closest("[data-stage]"); if (!this.drag || !lane) return; event.preventDefault(); clearDrop(); lane.classList.add("drop-target"); const target = event.target.closest("[data-task-id]"); if (target && target !== this.drag) target.classList.add(event.clientY > target.getBoundingClientRect().top + target.offsetHeight / 2 ? "drop-after" : "drop-before"); });
      on("drop", event => {
        const lane = event.target.closest("[data-stage]"); if (!this.drag || !lane) return; event.preventDefault();
        const card = this.drag, target = event.target.closest("[data-task-id]"), stage = lane.dataset.stage;
        if (stage !== card.closest("[data-stage]").dataset.stage) this.pushEvent("move-task", {id: card.dataset.taskId, stage});
        else if (this.prefs.sort !== "manual") this.announce("Choose Manual order to reorder cards. This does not change dispatch priority.");
        else if (target !== card) {
          const container = lane.querySelector("[data-lane-cards]");
          if (target) container.insertBefore(card, target.classList.contains("drop-after") ? target.nextSibling : target); else container.append(card);
          this.prefs.order[stage] = [...container.children].map(el => el.dataset.taskId); this.save(); this.announce("Card order saved in this browser. Dispatch order is unchanged.");
        }
        card.classList.remove("dragging"); this.drag = null; clearDrop();
      });
      on("dragend", () => { this.drag?.classList.remove("dragging"); this.drag = null; clearDrop(); });
      document.addEventListener("click", event => { if (this.popup && !event.target.closest("[data-filter]")) this.closeFilter(); }, {signal: this.abort.signal});
      this.apply();
    },
    updated() { this.apply(); if (this.popup) this.drawOptions(this.popup); },
    destroyed() { this.abort.abort(); clearTimeout(this.urlTimer); }
  };
  const BoardDialog = {
    mounted() {
      this.previous = document.activeElement;
      this.taskId = this.previous?.closest("[data-task-id]")?.dataset.taskId;
      this.bodyOverflow = document.body.style.overflow;
      document.body.style.overflow = "hidden";
      this.abort = new AbortController();
      this.el.addEventListener("cancel", event => { event.preventDefault(); this.pushEvent("close-dialog", {}); }, {signal: this.abort.signal});
      this.el.addEventListener("keydown", event => {
        if (event.key !== "Tab") return;
        const controls = [...this.el.querySelectorAll('button, a[href], input, select, textarea, summary, [tabindex]')]
          .filter(control => !control.disabled && control.tabIndex >= 0 && control.getClientRects().length);
        const first = controls[0], last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }, {signal: this.abort.signal});
      this.el.addEventListener("click", event => { if (event.target !== this.el) return; const rect = this.el.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) this.pushEvent("close-dialog", {}); }, {signal: this.abort.signal});
      this.el.showModal();
      this.el.querySelector("#close-dialog")?.focus();
    },
    updated() {
      if (!this.el.open) this.el.showModal();
      if (!this.el.contains(document.activeElement)) this.el.querySelector("#close-dialog")?.focus({preventScroll: true});
    },
    destroyed() {
      this.abort.abort();
      if (this.el.open) this.el.close();
      document.body.style.overflow = this.bodyOverflow;
      const previous = this.previous;
      requestAnimationFrame(() => {
        const replacement = [...document.querySelectorAll("[data-task-id]")].find(card => card.dataset.taskId === this.taskId)?.querySelector(".card-title");
        const canRestore = previous?.isConnected && previous !== document.body && previous !== document.documentElement;
        const target = canRestore ? previous : (previous?.id ? document.getElementById(previous.id) : null);
        (target || replacement || document.getElementById("settings-button"))?.focus({preventScroll: true});
      });
    }
  };
  const ChatWorkspace = {
    mounted() {
      this.abort = new AbortController();
      this.chatId = this.el.dataset.chatId;
      this.atBottom = true;
      this.running = this.el.dataset.running === "true";
      const on = (name, handler) => this.el.addEventListener(name, handler, {signal: this.abort.signal});
      this.scroll = () => {
        const scroller = this.el.querySelector("#chat-scroll");
        if (scroller && this.atBottom) scroller.scrollTop = scroller.scrollHeight;
      };
      this.resizeComposer = () => {
        const input = this.el.querySelector("#chat-message-input");
        if (input) { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 190) + "px"; }
      };
      // Scroll does not bubble; capture the retained conversation scroll container.
      this.el.addEventListener("scroll", event => {
        if (event.target.id === "chat-scroll") this.atBottom = event.target.scrollHeight - event.target.scrollTop - event.target.clientHeight < 90;
      }, {capture: true, signal: this.abort.signal});
      on("input", event => { if (event.target.id === "chat-message-input") this.resizeComposer(); });
      on("keydown", event => {
        if (event.target.id === "chat-message-input" && event.key === "Enter" && !event.shiftKey && !event.isComposing) {
          event.preventDefault();
          if (this.el.dataset.running !== "true" && event.target.value.trim()) event.target.form.requestSubmit();
        }
      });
      on("click", event => {
        const starter = event.target.closest("[data-chat-prompt]");
        const input = this.el.querySelector("#chat-message-input");
        if (starter && input && !input.disabled) { input.value = starter.dataset.chatPrompt; input.dispatchEvent(new Event("input", {bubbles: true})); input.focus(); this.resizeComposer(); }
      });
      this.handleEvent("chat-message-sent", () => {
        const input = this.el.querySelector("#chat-message-input");
        if (input) { input.value = ""; input.focus(); }
        this.atBottom = true; this.resizeComposer(); requestAnimationFrame(this.scroll);
      });
      requestAnimationFrame(this.scroll);
    },
    updated() {
      if (this.chatId !== this.el.dataset.chatId) { this.chatId = this.el.dataset.chatId; this.atBottom = true; }
      this.resizeComposer();
      requestAnimationFrame(this.scroll);
    },
    destroyed() { this.abort.abort(); }
  };
  window.SymphonyHooks = {TaskBoard, BoardDialog, ChatWorkspace};
})();
