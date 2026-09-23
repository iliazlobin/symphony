(() => {
  "use strict";
  const lanes = [["backlog", "Backlog"], ["work", "Work"], ["review", "Review"], ["done", "Done"]];
  const laneForStatus = status => ["ready", "running"].includes(status) ? "work" : status;
  const metadataFilters = ["milestone", "label", "assignee"];
  const boardFilters = ["project", "status", "priority", ...metadataFilters];
  const filterNames = {project: "Project", status: "Status", priority: "Priority", milestone: "Milestone", label: "Tags", assignee: "Assignee"};
  const emptyMetadata = {milestone: "No milestone", label: "No tags", assignee: "Unassigned"};
  const byteLength = value => new TextEncoder().encode(value).length;
  const parse = (text, fallback) => { try { return JSON.parse(text); } catch { return fallback; } };
  const escapeText = value => String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"}[c]));
  const storage = { get(key) { try { return localStorage.getItem(key); } catch { return null; } }, set(key, value) { try { localStorage.setItem(key, value); } catch { /* Preferences are optional. */ } } };
  const observeChatDropdown = (details, selector, signal) => {
    const fit = () => {
      if (!details.open) return;
      const menu = details.querySelector(selector), shell = details.closest(".chat-shell");
      if (!menu || !shell) return;
      const viewport = window.visualViewport;
      const bottom = Math.min(shell.getBoundingClientRect().bottom, viewport ? viewport.offsetTop + viewport.height : window.innerHeight);
      menu.style.setProperty("--chat-menu-space", Math.max(0, Math.floor(bottom - menu.getBoundingClientRect().top - 8)) + "px");
    };
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(fit) : null;
    const shell = details.closest(".chat-shell");
    if (shell) observer?.observe(shell);
    details.addEventListener("toggle", fit, {signal});
    window.addEventListener("resize", fit, {signal});
    window.visualViewport?.addEventListener("resize", fit, {signal});
    window.visualViewport?.addEventListener("scroll", fit, {signal});
    return {fit, disconnect: () => observer?.disconnect()};
  };
  const TaskBoard = {
    mounted() {
      this.prefs = {project: [], status: [], priority: [], milestone: [], label: [], assignee: [], query: "", sort: "manual", order: {}, lane: "work", density: "compact", theme: "light"};
      this.popup = null;
      this.activeOption = 0;
      this.drag = null;
      this.ignoreCardClickUntil = 0;
      this.scope = null;
      this.abort = new AbortController();
      this.darkMode = window.matchMedia("(prefers-color-scheme: dark)");
      const on = (name, handler) => this.el.addEventListener(name, handler, {signal: this.abort.signal});
      this.cardMetadata = card => {
        const strings = raw => { const values = parse(raw, []); return Array.isArray(values) ? values.filter(value => typeof value === "string" && value.length) : []; };
        const milestone = parse(card.dataset.milestone, null);
        return {
          labels: strings(card.dataset.labels), assignees: strings(card.dataset.assignees),
          milestone: milestone && typeof milestone === "object" && !Array.isArray(milestone) && milestone.id && typeof milestone.title === "string" ? milestone : null
        };
      };
      this.metadataLabel = (key, value) => {
        if (value === "__none__") return emptyMetadata[key];
        if (key === "label") return value.slice("label:".length);
        if (key === "assignee") return "@" + value.slice("assignee:".length);
        const separator = value.lastIndexOf(":"), projectId = value.slice("milestone:".length, separator);
        const projects = parse(this.el.dataset.projects, []), project = projects.find(project => project.id === projectId)?.label || projectId;
        return "Milestone #" + value.slice(separator + 1) + (projects.length > 1 ? ` · ${project}` : "");
      };
      this.refreshMetadata = () => {
        const options = Object.fromEntries(metadataFilters.map(key => [key, new Map()]));
        const projects = parse(this.el.dataset.projects, []);
        const cards = [...this.el.querySelectorAll(".task-card[data-task-id]")];
        const multipleProjects = new Set([...projects.map(project => project.id), ...cards.map(card => card.dataset.project)]).size > 1;
        for (const card of cards) {
          const {labels, assignees, milestone} = this.cardMetadata(card);
          labels.forEach(label => options.label.set("label:" + label, label));
          assignees.forEach(login => options.assignee.set("assignee:" + login, "@" + login));
          if (milestone) {
            const project = projects.find(project => project.id === card.dataset.project)?.label || card.dataset.project;
            options.milestone.set(`milestone:${card.dataset.project}:${milestone.id}`, milestone.title + (multipleProjects ? ` · ${project}` : ""));
          }
        }
        this.metadataOptions = options;
      };
      this.options = key => {
        if (key === "project") {
          const directory = parse(this.el.dataset.projectLinks, []);
          return parse(this.el.dataset.projects, []).map(p => [p.id, directory.find(link => link.id === p.id)?.label || p.label]);
        }
        if (key === "status") return [...lanes, ["ready", "Queued"], ["running", "Running"], ["attention", "Needs input"]];
        if (key === "priority") return [["P1", "P1 · High"], ["P2", "P2 · Normal"], ["P3", "P3 · Low"], ["P4", "P4 · Lowest"], ["—", "Unspecified"]];
        const options = new Map(this.metadataOptions?.[key] || []);
        for (const value of this.prefs[key]) if (value !== "__none__" && !options.has(value)) options.set(value, this.metadataLabel(key, value));
        return [...options].sort((a, b) => a[1].localeCompare(b[1])).concat([["__none__", emptyMetadata[key]]]);
      };
      this.projectChoices = () => {
        const local = this.options("project");
        const remote = parse(this.el.dataset.projectLinks, []).filter(link => !local.some(([id]) => id === link.id));
        return [["", "All projects"], ...local, ...remote.map(link => [link.id, link.label, link.url.replace(/\/$/, "") + "/login?continue=1"])];
      };
      this.metadataWithinLimits = values => values.length <= 20 && values.every(value => byteLength(value) <= 240) && byteLength(JSON.stringify(values)) <= 2000;
      this.filterValues = (key, values) => {
        if (!Array.isArray(values)) return [];
        if (!metadataFilters.includes(key)) return [...new Set(values.filter(value => this.options(key).some(([id]) => id === value)))];
        return values.reduce((selected, value) => {
          const valid = typeof value === "string" && !value.includes("\0") && (value === "__none__" ||
            (key === "milestone" ? /^milestone:.+:[1-9][0-9]*$/.test(value) : value.startsWith(key + ":") && value.length > key.length + 1));
          return valid && !selected.includes(value) && this.metadataWithinLimits([...selected, value]) ? [...selected, value] : selected;
        }, []);
      };
      this.load = () => {
        const scope = this.el.dataset.scope;
        if (!scope || this.scope === scope) return;
        this.scope = scope;
        this.key = "symphony.board.v1:" + scope;
        const parsed = parse(storage.get(this.key), {});
        const saved = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
        for (const k of boardFilters) this.prefs[k] = this.filterValues(k, saved[k]);
        this.prefs.query = typeof saved.query === "string" ? saved.query : "";
        this.prefs.sort = ["manual", "priority", "updated", "oldest", "title"].includes(saved.sort) ? saved.sort : "manual";
        const savedLane = laneForStatus(saved.lane);
        this.prefs.lane = lanes.some(([id]) => id === savedLane) ? savedLane : "work";
        const savedOrder = stage => Array.isArray(saved.order?.[stage]) ? saved.order[stage].filter(id => typeof id === "string") : [];
        this.prefs.order = Object.fromEntries(lanes.map(([stage]) => [stage, [...new Set(stage === "work" ? [...savedOrder("work"), ...savedOrder("ready"), ...savedOrder("running")] : savedOrder(stage))]]));
        this.prefs.density = ["compact", "details"].includes(saved.density) ? saved.density : "compact";
        this.prefs.theme = ["light", "dark", "system"].includes(saved.theme) ? saved.theme : "light";
        this.el.querySelector("[data-board-search]").value = this.prefs.query;
        this.el.querySelector("[data-board-sort]").value = this.prefs.sort;
      };
      this.urlKey = null;
      this.readURL = () => {
        const encoded = this.el.dataset.urlFilters || "{}";
        if (this.urlKey === encoded) return;
        const initial = this.urlKey === null;
        this.urlKey = encoded;
        const parsed = parse(encoded, {});
        const filters = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
        if (initial && !Object.keys(filters).length) return;
        for (const key of boardFilters) this.prefs[key] = this.filterValues(key, metadataFilters.includes(key) ? parse(filters[key], []) : typeof filters[key] === "string" ? filters[key].split(",") : []);
        this.prefs.query = typeof filters.q === "string" ? filters.q : "";
        this.prefs.sort = ["manual", "priority", "updated", "oldest", "title"].includes(filters.sort) ? filters.sort : "manual";
        this.el.querySelector("[data-board-search]").value = this.prefs.query;
        this.el.querySelector("[data-board-sort]").value = this.prefs.sort;
      };
      this.save = () => {
        if (this.key) storage.set(this.key, JSON.stringify(this.prefs));
        clearTimeout(this.urlTimer);
        this.urlTimer = setTimeout(() => {
          const filters = {q: this.prefs.query, sort: this.prefs.sort};
          for (const key of boardFilters) filters[key] = metadataFilters.includes(key) ? (this.prefs[key].length ? JSON.stringify(this.prefs[key]) : "") : this.prefs[key].join(",");
          for (const key of Object.keys(filters)) if (!filters[key] || (key === "sort" && filters[key] === "manual")) delete filters[key];
          const parsed = parse(this.el.dataset.urlFilters || "{}", {});
          const current = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
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
      this.closeMenus = (except = null, restoreFocus = false) => {
        let closed = false;
        this.el.querySelectorAll("details.board-menu[open]").forEach(menu => {
          if (menu === except || menu.closest("dialog")) return;
          const focused = menu.contains(document.activeElement);
          menu.open = false; closed = true;
          if (restoreFocus && focused) menu.querySelector("summary")?.focus({preventScroll: true});
        });
        return closed;
      };
      this.applyAppearance = () => {
        this.el.dataset.density = this.prefs.density;
        this.el.dataset.singleProject = String(this.prefs.project.length === 1 || this.options("project").length === 1);
        const theme = this.prefs.theme === "system" ? (this.darkMode.matches ? "dark" : "light") : this.prefs.theme;
        this.el.dataset.theme = theme;
        this.el.style.colorScheme = theme;
        const density = this.el.querySelector("[data-board-density]"), selection = this.el.querySelector("[data-board-theme]");
        if (density) density.value = this.prefs.density;
        if (selection) selection.value = this.prefs.theme;
        this.el.querySelector("[data-board-sort]").value = this.prefs.sort;
      };
      this.drawOptions = key => {
        const input = this.el.querySelector("#filter-" + key), list = this.el.querySelector("#options-" + key);
        const choices = key === "project" ? this.projectChoices() : this.options(key);
        const options = choices.filter(([id, label]) => (key === "project" ? `${label} ${id}` : label).toLowerCase().includes(input.value.toLowerCase()));
        this.activeOption = Math.min(Math.max(0, this.activeOption), Math.max(0, options.length - 1));
        input.setAttribute("aria-expanded", String(this.popup === key));
        list.hidden = this.popup !== key;
        list.innerHTML = options.length ? options.map(([value, label, href], i) => {
          const selected = this.prefs[key].includes(value) || (key === "project" && !this.prefs.project.length && (this.options(key).length === 1 ? value === this.options(key)[0][0] : value === ""));
          const tag = href ? "a" : "button", action = href ? `href="${escapeText(href)}"` : `type="button" data-key="${key}" data-value="${escapeText(value)}"`;
          const subtitle = key === "project" && value ? `<small>${escapeText(value.replace(/^github:/, ""))}</small>` : "";
          return `<${tag} ${action} role="option" class="combo-option" id="option-${key}-${i}" data-active="${i === this.activeOption}" aria-selected="${selected}" title="${escapeText(label)}"><span>${escapeText(label)}${subtitle}</span><span aria-hidden="true">${selected ? "✓" : href ? "↗" : ""}</span></${tag}>`;
        }).join("") : '<p class="option-empty">No matches</p>';
        if (this.popup === key && options.length) input.setAttribute("aria-activedescendant", `option-${key}-${this.activeOption}`);
        else input.removeAttribute("aria-activedescendant");
        return options;
      };
      this.openFilter = key => { this.closeMenus(); if (this.popup !== key) this.closeFilter(); this.popup = key; this.activeOption = 0; this.drawOptions(key); };
      this.toggle = (key, value) => {
        if (key === "project") {
          const choice = this.projectChoices().find(([id]) => id === value);
          if (!choice) return;
          if (choice[2]) { window.location.assign(choice[2]); return; }
          this.prefs.project = value ? [value] : [];
          this.el.querySelector("#filter-project").focus({preventScroll: true});
          this.closeFilter(); this.apply(); this.save();
          return;
        }
        const values = this.prefs[key].includes(value) ? this.prefs[key].filter(v => v !== value) : [...this.prefs[key], value];
        if (metadataFilters.includes(key) && !this.metadataWithinLimits(values)) {
          this.announce("Filter selection is too large to save. Choose fewer or shorter values (up to 20 per filter).");
          return;
        }
        this.prefs[key] = values;
        this.el.querySelector("#filter-" + key).value = "";
        this.activeOption = 0; this.drawOptions(key); this.apply(); this.save();
        this.el.querySelector("#filter-" + key).focus();
      };
      this.announce = message => {
        let status = this.el.querySelector("[data-board-announcement]");
        if (!status) { status = document.createElement("p"); status.dataset.boardAnnouncement = ""; status.className = "board-notice"; status.setAttribute("role", "status"); this.el.querySelector(".board-content").prepend(status); }
        status.textContent = message;
      };
      this.captureContext = () => {
        if (this.el.dataset.chatOpen !== "true" || !this.el.dataset.chatProject) { this.contextKey = null; return; }
        const project = this.el.dataset.chatProject;
        const cards = [...this.el.querySelectorAll(".task-card[data-task-id]")].filter(card =>
          card.dataset.project === project && !card.closest("[hidden]") && card.getClientRects().length > 0);
        const board = this.el.querySelector(".board-main").getBoundingClientRect();
        const laneArea = this.el.querySelector(".kanban-board").getBoundingClientRect();
        const dock = this.el.querySelector("#management-chat-dock").getBoundingClientRect();
        const taskOpen = this.el.querySelector("#board-dialog[open]");
        const inViewport = card => {
          const rect = card.getBoundingClientRect();
          return !taskOpen && rect.bottom > Math.max(0, board.top, laneArea.top) && rect.top < Math.min(window.innerHeight, board.bottom, laneArea.bottom) &&
            rect.right > Math.max(0, board.left, laneArea.left) && rect.left < Math.min(window.innerWidth, board.right, laneArea.right, dock.left);
        };
        // Keep on-screen cards within the bounded list even on a large, scrolled board.
        const viewport = cards.filter(inViewport).slice(0, 50);
        const visible = [...new Set([...viewport, ...cards])].slice(0, 50);
        const snapshot = {
          version: 1, project_id: project,
          filters: {...Object.fromEntries(boardFilters.map(key => [key, key === "milestone" ? this.prefs[key].filter(value => value === "__none__" || value.startsWith(`milestone:${project}:`)) : this.prefs[key]])), q: this.prefs.query, sort: this.prefs.sort},
          selected_task_id: this.el.dataset.selectedTask || null,
          visible_task_ids: visible.map(card => card.dataset.taskId), viewport_task_ids: viewport.map(card => card.dataset.taskId),
          hidden_columns: [],
          board_checked_at: this.el.dataset.boardCheckedAt || null, truncated: cards.length > 50
        };
        const key = JSON.stringify([snapshot, this.el.dataset.contextRevision]);
        if (key !== this.contextKey) {
          this.contextKey = key;
          this.pushEvent("board-view-context", {...snapshot, captured_at: new Date().toISOString()});
        }
      };
      this.scheduleContext = () => {
        clearTimeout(this.contextTimer);
        this.contextTimer = setTimeout(this.captureContext, 100);
      };
      this.apply = () => {
        this.refreshMetadata();
        this.load();
        this.readURL();
        this.applyAppearance();
        const cards = [...this.el.querySelectorAll("[data-task-id]")];
        const linkedTask = this.el.dataset.selectedTask || new URLSearchParams(window.location.search).get("task");
        let matched = 0;
        for (const card of cards) {
          const d = card.dataset, stage = card.closest("[data-stage]").dataset.stage;
          const {labels, assignees, milestone} = this.cardMetadata(card);
          const metadata = {label: labels.map(label => "label:" + label), assignee: assignees.map(login => "assignee:" + login), milestone: milestone ? [`milestone:${d.project}:${milestone.id}`] : []};
          const metadataMatches = metadataFilters.every(key => !this.prefs[key].length || this.prefs[key].some(value => value === "__none__" ? !metadata[key].length : metadata[key].includes(value)));
          const searchable = [d.title, d.identifier, milestone?.title, ...labels, ...assignees.map(login => "@" + login)].join(" ").toLowerCase();
          const matches = metadataMatches && (!this.prefs.project.length || this.prefs.project.includes(d.project)) && (!this.prefs.priority.length || this.prefs.priority.includes(d.priority)) && (!this.prefs.status.length || this.prefs.status.includes(stage) || this.prefs.status.includes(d.status) || (this.prefs.status.includes("attention") && d.attention === "true")) && (!this.prefs.query || searchable.includes(this.prefs.query.toLowerCase()));
          card.hidden = !matches;
          if (matches) matched++;
        }
        this.el.querySelector("[data-result-count]").textContent = `${matched} of ${cards.length} tasks`;
        for (const [stage] of lanes) {
          const lane = this.el.querySelector(`[data-stage="${stage}"]`), container = lane.querySelector("[data-lane-cards]");
          const items = [...container.children];
          const rank = id => { const order = this.prefs.order[stage]; const index = Array.isArray(order) ? order.indexOf(id) : -1; return index < 0 ? 100000 : index; };
          const date = value => Date.parse(value) || 0;
          const priorityRank = value => /^P[1-9]\d*$/.test(value) ? Number(value.slice(1)) : Number.MAX_SAFE_INTEGER;
          items.sort((a,b) => this.prefs.sort === "priority" ? priorityRank(a.dataset.priority) - priorityRank(b.dataset.priority) : this.prefs.sort === "updated" ? date(b.dataset.updated) - date(a.dataset.updated) : this.prefs.sort === "oldest" ? (date(a.dataset.created) || Infinity) - (date(b.dataset.created) || Infinity) : this.prefs.sort === "title" ? a.dataset.title.localeCompare(b.dataset.title) : rank(a.dataset.taskId) - rank(b.dataset.taskId));
          items.forEach((item, index) => { if (container.children[index] !== item) container.insertBefore(item, container.children[index] || null); });
          const count = items.filter(item => !item.hidden).length;
          lane.querySelector("[data-lane-count]").textContent = count;
          lane.querySelector("[data-lane-empty]").hidden = count !== 0;
          lane.querySelector("[data-lane-empty]").textContent = matched ? "No matching tasks" : "No tasks match";
        }
        const linkedStage = cards.find(card => card.dataset.taskId === linkedTask)?.closest("[data-stage]").dataset.stage;
        const mobileContext = JSON.stringify([...boardFilters.map(key => this.prefs[key]), this.prefs.query, linkedTask, linkedStage]);
        const contextChanged = this.mobileContext !== mobileContext;
        this.mobileContext = mobileContext;
        if (contextChanged && linkedStage) this.prefs.lane = linkedStage;
        else if (contextChanged && this.prefs.status.length === 1 && lanes.some(([stage]) => stage === laneForStatus(this.prefs.status[0]))) this.prefs.lane = laneForStatus(this.prefs.status[0]);
        const current = this.el.querySelector(`[data-stage="${this.prefs.lane}"]`);
        if (!current || (contextChanged && !linkedStage && matched && !current.querySelector(".task-card:not([hidden])"))) this.prefs.lane = lanes.find(([stage]) => this.el.querySelector(`[data-stage="${stage}"] .task-card:not([hidden])`))?.[0] || "work";
        this.el.querySelectorAll("[data-stage]").forEach(el => el.dataset.mobileActive = String(el.dataset.stage === this.prefs.lane));
        const mobile = this.el.querySelector("[data-mobile-lane]"); mobile.value = this.prefs.lane;
        for (const option of mobile.options) option.textContent = `${lanes.find(([s]) => s === option.value)[1]} (${this.el.querySelector(`[data-stage="${option.value}"] [data-lane-count]`).textContent})`;
        this.el.querySelector("[data-filter-chips]").innerHTML = boardFilters.filter(key => key !== "project").flatMap(key => this.prefs[key].map(value => { const label = this.options(key).find(([id]) => id === value)?.[1] || value; return `<button type="button" class="filter-chip" data-remove-key="${key}" data-remove-value="${escapeText(value)}" aria-label="Remove ${key} filter ${escapeText(label)}">${escapeText(label)} <span aria-hidden="true">×</span></button>`; })).join("");
        for (const key of boardFilters) {
          const projects = key === "project" ? this.options(key) : [];
          const selectedProject = this.prefs.project.length === 1 ? projects.find(([id]) => id === this.prefs.project[0])?.[1] : !this.prefs.project.length && projects.length === 1 ? projects[0][1] : null;
          const label = key === "project" ? selectedProject || (this.prefs.project.length ? `${this.prefs.project.length} projects` : "All projects") : `${filterNames[key]}: ${this.prefs[key].length ? this.prefs[key].length + " selected" : "All"}`;
          const input = this.el.querySelector("#filter-" + key);
          input.placeholder = label;
          input.title = label;
        }
        this.scheduleContext();
      };
      on("focusin", event => { const key = event.target.closest("[data-filter]")?.dataset.filter; if (key && event.target.matches("input")) this.openFilter(key); });
      on("input", event => { const key = event.target.closest("[data-filter]")?.dataset.filter; if (key) { this.popup = key; this.activeOption = 0; this.drawOptions(key); } else if (event.target.matches("[data-board-search]")) { this.prefs.query = event.target.value; this.apply(); this.save(); } });
      on("keydown", event => {
        if (event.target.closest("dialog")) return;
        if (event.target.matches(".task-card[data-task-id]") && ["Enter", " "].includes(event.key)) {
          if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
          event.preventDefault(); event.stopPropagation();
          if (!event.repeat) this.pushEvent("select-task", {id: event.target.dataset.taskId});
          return;
        }
        if (event.key === "Escape") {
          if (this.popup) { const key = this.popup; this.el.querySelector("#filter-" + key)?.focus({preventScroll: true}); this.closeFilter(); }
          else if (this.closeMenus(null, true)) { /* Keep Escape within the open menu. */ }
          else return;
          event.preventDefault(); event.stopPropagation(); return;
        }
        const key = event.target.closest("[data-filter]")?.dataset.filter;
        if (!key || !event.target.matches("input")) return;
        if (["ArrowDown", "ArrowUp"].includes(event.key)) { event.preventDefault(); if (this.popup !== key) this.openFilter(key); else { this.activeOption += event.key === "ArrowDown" ? 1 : -1; this.drawOptions(key); } }
        else if (event.key === "Enter" && this.popup === key) { event.preventDefault(); const choice = this.drawOptions(key)[this.activeOption]; if (choice) this.toggle(key, choice[0]); }
        else if (event.key === "Tab") this.closeFilter();
      });
      on("click", event => {
        const card = event.target.closest(".task-card[data-task-id]");
        if (card && !event.target.closest("a,button,input,textarea,select,summary,[role=button],[contenteditable]:not([contenteditable=false])")) {
          const selection = window.getSelection();
          const selectingText = selection && !selection.isCollapsed && (card.contains(selection.anchorNode) || card.contains(selection.focusNode));
          if (event.button === 0 && !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey &&
              !this.drag && Date.now() >= this.ignoreCardClickUntil && !selectingText) {
            card.focus({preventScroll: true});
            this.pushEvent("select-task", {id: card.dataset.taskId});
          }
          return;
        }
        const menu = event.target.closest("details.board-menu");
        if (menu && event.target.closest("summary")) { this.closeFilter(); this.closeMenus(menu); }
        const button = event.target.closest("button"); if (!button) return;
        if (button.dataset.filterToggle) { const key = button.dataset.filterToggle; if (this.popup === key) this.closeFilter(); else { this.openFilter(key); this.el.querySelector("#filter-" + key).focus(); } }
        else if (button.dataset.key) this.toggle(button.dataset.key, button.dataset.value);
        else if (button.dataset.removeKey) { this.prefs[button.dataset.removeKey] = this.prefs[button.dataset.removeKey].filter(v => v !== button.dataset.removeValue); this.apply(); this.save(); }
        else if (button.hasAttribute("data-clear-filters")) { for (const key of boardFilters) this.prefs[key] = []; this.prefs.query = ""; this.el.querySelector("[data-board-search]").value = ""; this.closeFilter(); this.apply(); this.save(); }
        else if (button.dataset.copy) navigator.clipboard?.writeText(button.dataset.copy).then(() => { button.textContent = "Copied"; }).catch(() => { button.textContent = "Copy unavailable"; });
      });
      on("change", event => {
        if (event.target.hasAttribute("data-board-sort")) { this.prefs.sort = event.target.value; this.apply(); this.save(); }
        else if (event.target.hasAttribute("data-board-density") && ["compact", "details"].includes(event.target.value)) { this.prefs.density = event.target.value; this.apply(); this.save(); }
        else if (event.target.hasAttribute("data-board-theme") && ["light", "dark", "system"].includes(event.target.value)) { this.prefs.theme = event.target.value; this.apply(); this.save(); }
        else if (event.target.hasAttribute("data-mobile-lane") && lanes.some(([stage]) => stage === event.target.value)) { this.prefs.lane = event.target.value; this.apply(); this.save(); }
      });
      on("dragstart", event => { const card = event.target.closest("[data-task-id]"); if (!card || card.getAttribute("draggable") !== "true" || event.target.closest("select,a,button,summary")) { event.preventDefault(); return; } this.drag = card; card.classList.add("dragging"); event.dataTransfer.effectAllowed = "move"; event.dataTransfer.setData("text/plain", card.dataset.taskId); });
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
        this.ignoreCardClickUntil = Date.now() + 300;
        card.classList.remove("dragging"); this.drag = null; clearDrop();
      });
      on("dragend", () => { this.ignoreCardClickUntil = Date.now() + 300; this.drag?.classList.remove("dragging"); this.drag = null; clearDrop(); });
      document.addEventListener("click", event => {
        if (this.popup && !event.target.closest("[data-filter]")) this.closeFilter();
        this.closeMenus(event.target.closest("details.board-menu"), true);
      }, {signal: this.abort.signal});
      this.darkMode.addEventListener("change", () => this.applyAppearance(), {signal: this.abort.signal});
      this.el.addEventListener("scroll", this.scheduleContext, {capture: true, passive: true, signal: this.abort.signal});
      on("symphony:capture-context", this.captureContext);
      window.addEventListener("scroll", this.scheduleContext, {passive: true, signal: this.abort.signal});
      window.addEventListener("resize", this.scheduleContext, {passive: true, signal: this.abort.signal});
      this.apply();
    },
    beforeUpdate() { this.openMenuKeys = [...this.el.querySelectorAll("details.board-menu[open]")].map(menu => menu.id || menu.className); },
    updated() {
      this.apply();
      if (this.popup) this.drawOptions(this.popup);
      for (const menu of this.el.querySelectorAll("details.board-menu")) {
        if (this.openMenuKeys?.includes(menu.id || menu.className)) menu.open = true;
      }
    },
    destroyed() { this.abort.abort(); clearTimeout(this.urlTimer); clearTimeout(this.contextTimer); }
  };
  const BoardDialog = {
    mounted() {
      this.previous = document.activeElement;
      this.taskId = this.previous?.closest("[data-task-id]")?.dataset.taskId;
      this.bodyOverflow = document.body.style.overflow;
      this.contentKey = this.el.dataset.contentKey;
      this.abort = new AbortController();
      this.closeDialog = () => this.el.dataset.eventTarget ? this.pushEventTo(this.el, "close-dialog", {}) : this.pushEvent("close-dialog", {});
      document.addEventListener("focusin", event => { if (event.target !== document.body && event.target !== document.documentElement) this.lastFocused = event.target; }, {signal: this.abort.signal});
      this.showDialog = () => {
        const nonmodal = this.el.dataset.nonmodal === "true";
        if (this.nonmodal !== nonmodal && this.el.open) this.el.close();
        this.nonmodal = nonmodal;
        document.body.style.overflow = nonmodal ? this.bodyOverflow : "hidden";
        if (!this.el.open) { if (nonmodal) this.el.show(); else this.el.showModal(); }
      };
      this.closeSelector = this.el.dataset.closeSelector || "#close-dialog";
      this.focusDialog = () => (this.el.querySelector(this.closeSelector) || this.el.querySelector("[data-dialog-focus]"))?.focus({preventScroll: true});
      document.addEventListener("click", event => {
        // LiveView links replace the card themselves; a second patch can overwrite their URL.
        if (event.target.closest("a[data-phx-link]")) return;
        if (this.nonmodal && this.el.open && !this.el.contains(event.target)) this.closeDialog();
      }, {capture: true, signal: this.abort.signal});
      document.addEventListener("keydown", event => {
        if (this.nonmodal && this.el.open && event.key === "Escape") {
          event.preventDefault(); event.stopPropagation();
          if (!event.repeat) this.closeDialog();
        }
      }, {capture: true, signal: this.abort.signal});
      this.el.addEventListener("cancel", event => { event.preventDefault(); this.closeDialog(); }, {signal: this.abort.signal});
      this.el.addEventListener("keydown", event => {
        if (this.nonmodal || event.key !== "Tab") return;
        const controls = [...this.el.querySelectorAll('button, a[href], input, select, textarea, summary, [tabindex]')]
          .filter(control => !control.disabled && control.tabIndex >= 0 && control.getClientRects().length);
        const first = controls[0], last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }, {signal: this.abort.signal});
      this.el.addEventListener("click", event => { if (event.target !== this.el) return; const rect = this.el.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) this.closeDialog(); }, {signal: this.abort.signal});
      this.showDialog();
      this.focusDialog();
    },
    beforeUpdate() {
      this.scrollPosition = this.el.scrollTop;
      this.focusedControl = document.activeElement;
      const control = this.focusedControl;
      this.textSelection = typeof control?.selectionStart === "number"
        ? [control.selectionStart, control.selectionEnd, control.selectionDirection] : null;
    },
    updated() {
      const changed = this.contentKey !== this.el.dataset.contentKey;
      this.contentKey = this.el.dataset.contentKey;
      this.showDialog();
      this.el.scrollTop = changed ? 0 : (this.scrollPosition ?? this.el.scrollTop);
      const control = this.focusedControl;
      if (!changed && control?.isConnected && !control.disabled && control !== document.body && control !== document.documentElement && control.getClientRects().length && (this.nonmodal || this.el.contains(control))) {
        control.focus({preventScroll: true});
        if (this.textSelection) control.setSelectionRange(...this.textSelection);
      }
      if (!this.nonmodal && !this.el.contains(document.activeElement)) this.focusDialog();
    },
    destroyed() {
      this.abort.abort();
      const focused = this.lastFocused || document.activeElement;
      if (this.el.open) this.el.close();
      document.body.style.overflow = this.bodyOverflow;
      const previous = this.previous;
      queueMicrotask(() => {
        const replacement = [...document.querySelectorAll("[data-task-id]")].find(card => card.dataset.taskId === this.taskId)?.querySelector(".card-title");
        const visible = target => target?.isConnected && target !== document.body && target !== document.documentElement && !target.closest("[hidden]") && target.getClientRects().length > 0;
        if (visible(focused) && !this.el.contains(focused)) { focused.focus({preventScroll: true}); return; }
        const canRestore = visible(previous);
        const target = canRestore ? previous : (previous?.id ? document.getElementById(previous.id) : null);
        [target, replacement, document.getElementById("settings-button"), document.getElementById("filter-status")].find(visible)?.focus({preventScroll: true});
      });
    }
  };
  const ChatWorkspace = {
    mounted() {
      this.abort = new AbortController();
      this.handleEvent("focus-chat-session", () => requestAnimationFrame(() => this.el.querySelector("#chat-message-input")?.focus({preventScroll: true})));
      this.chatId = this.el.dataset.chatId;
      this.atBottom = true;
      this.running = this.el.dataset.running === "true";
      const on = (name, handler) => this.el.addEventListener(name, handler, {signal: this.abort.signal});
      const tabs = ["chat", "context", "outputs", "sources"];
      const compactTime = new Intl.DateTimeFormat(undefined, {month: "short", day: "numeric", hour: "numeric", minute: "2-digit"});
      const fullTime = new Intl.DateTimeFormat(undefined, {year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit", timeZoneName: "long"});
      this.localizeTimes = () => {
        this.el.querySelectorAll("time[data-chat-timestamp]").forEach(time => {
          const date = new Date(time.dateTime);
          if (!Number.isFinite(date.getTime())) return;
          time.textContent = compactTime.format(date);
          const description = `${time.dataset.timeLabel}: ${fullTime.format(date)}`;
          time.title = description;
          time.setAttribute("aria-label", description);
        });
      };
      this.tabKeyFor = chat => this.el.dataset.project ? "symphony.chat.tab.v1:" + this.el.dataset.project + ":" + (chat || "project") : null;
      this.tabKey = () => this.tabKeyFor(this.el.dataset.chatId);
      this.viewKeyFor = chat => this.el.dataset.project ? "symphony.chat.view.v1:" + this.el.dataset.project + ":" + (chat || "project") : null;
      this.saveView = (view, chat = this.el.dataset.chatId) => { try { const key = this.viewKeyFor(chat); if (key) sessionStorage.setItem(key, view); } catch { /* Presentation remains usable without storage. */ } };
      this.saveTab = tab => { try { const key = this.tabKey(); if (key) sessionStorage.setItem(key, tab); } catch { /* Optional presentation preference. */ } };
      this.loadTab = () => {
        const key = this.tabKey();
        if (key === this.loadedTabKey) return;
        this.loadedTabKey = key;
        if (this.el.dataset.embedded === "true") return;
        try {
          let tab = key && sessionStorage.getItem(key);
          const viewKey = this.viewKeyFor(this.el.dataset.chatId);
          let view = viewKey && sessionStorage.getItem(viewKey);
          // The former Threads tab is now list navigation, never a detail tab.
          if (tab === "threads") { tab = "chat"; this.saveTab(tab); if (!view) { view = "list"; this.saveView(view); } }
          const scope = {project_id: this.el.dataset.project, chat_id: this.el.dataset.chatId || null};
          if (this.el.dataset.embedded !== "true" && key && ["list", "conversation"].includes(view)) this.pushEventTo(this.el.dataset.eventTarget, "restore-workspace-view", {...scope, view});
          if (this.el.dataset.chatId && tabs.includes(tab)) this.pushEventTo(this.el.dataset.eventTarget, "restore-session-tab", {...scope, tab});
        } catch { /* Conversation records do not depend on browser storage. */ }
      };
      this.clearDrag = () => {
        this.draggedThread = null;
        this.el.querySelectorAll?.("[data-chat-drop]").forEach(row => row.removeAttribute("data-chat-drop"));
      };
      this.scope = () => [this.el.dataset.project, this.el.dataset.chatId, this.el.dataset.workspaceView].join(":");
      this.dragScope = this.scope();
      const canDrag = () => this.el.dataset.workspaceView === "list" && !this.el.querySelector("#chat-thread-search input")?.value;
      on("dragstart", event => {
        const handle = event.target.closest("[data-thread-drag]");
        const row = handle?.closest("[data-thread-id]");
        if (!handle || !row || handle.disabled || !canDrag()) { event.preventDefault(); return; }
        event.stopPropagation();
        this.draggedThread = {id: row.dataset.threadId, pinned: row.dataset.pinned, project: this.el.dataset.project};
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", row.dataset.threadId);
      });
      const dropPosition = event => {
        const row = event.target.closest("#chat-thread-list [data-thread-id]");
        const drag = this.draggedThread;
        if (!drag || !row || !canDrag() || drag.project !== this.el.dataset.project || row.dataset.pinned !== drag.pinned || row.dataset.threadId === drag.id) return null;
        const source = Array.from(this.el.querySelectorAll("#chat-thread-list [data-thread-id]")).find(candidate => candidate.dataset.threadId === drag.id);
        if (!source || source.dataset.pinned !== drag.pinned) return null;
        const rows = Array.from(row.parentElement.querySelectorAll("[data-thread-id]"));
        const after = event.clientY > row.getBoundingClientRect().top + row.getBoundingClientRect().height / 2;
        const next = after ? rows.slice(rows.indexOf(row) + 1).find(candidate => candidate.dataset.threadId !== drag.id) : row;
        return {row, after, before: next?.dataset.threadId || null};
      };
      on("dragover", event => {
        if (this.draggedThread) event.stopPropagation();
        const target = dropPosition(event);
        this.el.querySelectorAll?.("[data-chat-drop]").forEach(row => row.removeAttribute("data-chat-drop"));
        if (target) { event.preventDefault(); event.dataTransfer.dropEffect = "move"; target.row.dataset.chatDrop = target.after ? "after" : "before"; }
      });
      on("drop", event => {
        if (this.draggedThread) { event.preventDefault(); event.stopPropagation(); }
        const target = dropPosition(event);
        if (target) {
          event.preventDefault(); event.stopPropagation();
          this.pushEventTo(this.el.dataset.eventTarget, "move-thread", {id: this.draggedThread.id, before_id: target.before, pinned: this.draggedThread.pinned === "true", project_id: this.draggedThread.project});
        }
        this.ignoreThreadClickUntil = Date.now() + 300;
        this.clearDrag();
      });
      on("dragend", event => { if (this.draggedThread) event.stopPropagation(); this.ignoreThreadClickUntil = Date.now() + 300; this.clearDrag(); });
      this.scroll = () => {
        if (this.el.dataset.workspaceView === "list") return;
        const scroller = this.el.querySelector("#session-chat-content");
        if (scroller && this.atBottom) scroller.scrollTop = scroller.scrollHeight;
      };
      this.resizeComposer = () => {
        const input = this.el.querySelector("#chat-message-input");
        if (input) { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 190) + "px"; }
      };
      // Scroll does not bubble; capture the retained conversation scroll container.
      this.el.addEventListener("scroll", event => {
        if (event.target.id === "session-chat-content") this.atBottom = event.target.scrollHeight - event.target.scrollTop - event.target.clientHeight < 90;
      }, {capture: true, signal: this.abort.signal});
      on("input", event => { if (event.target.id === "chat-message-input") this.resizeComposer(); });
      // Queue the current view before LiveView sends this form's message event.
      on("submit", event => {
        if (event.target.id === "chat-composer") this.el.dispatchEvent(new CustomEvent("symphony:capture-context", {bubbles: true}));
      });
      on("keydown", event => {
        const tab = event.target.closest('[role="tab"][phx-click="session-tab"]');
        if (tab && ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
          event.preventDefault();
          const buttons = Array.from(this.el.querySelectorAll('[role="tab"][phx-click="session-tab"]'));
          const index = buttons.indexOf(tab);
          const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + buttons.length) % buttons.length;
          buttons[next]?.focus(); buttons[next]?.click();
        }

        if (event.target.id === "chat-message-input" && event.key === "Enter" && !event.shiftKey && !event.isComposing) {
          event.preventDefault();
          if (!event.target.disabled && event.target.value.trim()) event.target.form.requestSubmit();
        }
      });
      on("click", event => {
        const tab = event.target.closest('[role="tab"][phx-click="session-tab"]');
        if (tab) this.saveTab(tab.getAttribute("phx-value-tab"));
        const thread = event.target.closest('button[phx-click="open-chat"]');
        if (thread && Date.now() < (this.ignoreThreadClickUntil || 0)) { event.preventDefault(); event.stopPropagation(); return; }
        if (thread) {
          this.saveView("conversation", thread.getAttribute("phx-value-id"));
          try { const key = this.tabKeyFor(thread.getAttribute("phx-value-id")); if (key) sessionStorage.setItem(key, "chat"); } catch { /* Row selection still opens Chat on the server. */ }
        }
        if (event.target.closest('[phx-click="back-to-chats"]')) this.saveView("list");
        const boardLink = event.target.closest('a[phx-click="board-link"]');
        if (boardLink && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) event.preventDefault();
        else if (boardLink) event.stopPropagation();
        const starter = event.target.closest("[data-chat-prompt]");
        const input = this.el.querySelector("#chat-message-input");
        if (starter && input && !input.disabled) { input.value = starter.dataset.chatPrompt; input.dispatchEvent(new Event("input", {bubbles: true})); input.focus(); this.resizeComposer(); }
      });
      this.handleEvent("chat-message-sent", ({chat_id, accepted_text}) => {
        if (chat_id !== this.el.dataset.chatId) return;
        const input = this.el.querySelector("#chat-message-input");
        if (input && input.value.trim() && input.value.trim() !== accepted_text) return;
        if (input) { input.value = ""; input.focus(); }
        this.saveView("conversation"); this.saveTab("chat"); this.atBottom = true; this.resizeComposer(); requestAnimationFrame(this.scroll);
      });
      this.loadTab();
      this.localizeTimes();
      requestAnimationFrame(this.scroll);
    },
    updated() {
      if (this.dragScope !== this.scope()) { this.clearDrag(); this.dragScope = this.scope(); }
      if (this.chatId !== this.el.dataset.chatId) { this.chatId = this.el.dataset.chatId; this.atBottom = true; }
      this.loadTab();
      this.localizeTimes();
      this.resizeComposer();
      requestAnimationFrame(() => this.scroll());
    },
    reconnected() {
      // A channel rejoin remounts server state but retains this hook instance.
      this.clearDrag();
      this.loadedTabKey = undefined;
      this.loadTab();
      this.localizeTimes();
    },
    destroyed() { this.abort.abort(); }
  };
  const IssueSwitcher = {
    mounted() {
      this.abort = new AbortController();
      this.menuSize = observeChatDropdown(this.el, ".issue-switcher-menu", this.abort.signal);
      this.activeId = null;
      this.input = () => this.el.querySelector('[role="combobox"]');
      this.options = () => [...this.el.querySelectorAll('[role="option"]')];
      this.sync = () => {
        const options = this.options();
        if (!options.some(option => option.id === this.activeId)) this.activeId = options[0]?.id || null;
        options.forEach(option => { option.tabIndex = -1; option.dataset.active = String(option.id === this.activeId); });
        const input = this.input();
        input?.setAttribute("aria-expanded", String(this.el.open));
        if (this.el.open && this.activeId) input?.setAttribute("aria-activedescendant", this.activeId);
        else input?.removeAttribute("aria-activedescendant");
      };
      this.close = (focus = false) => { this.el.open = false; this.sync(); if (focus) this.el.querySelector("summary")?.focus(); };
      this.el.addEventListener("toggle", () => { this.sync(); if (this.el.open) this.input()?.focus({preventScroll: true}); }, {signal: this.abort.signal});
      this.el.addEventListener("keydown", event => {
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); this.close(true); return; }
        if (event.target !== this.input()) return;
        const options = this.options();
        const current = options.findIndex(option => option.id === this.activeId);
        let index;
        if (event.key === "ArrowDown") index = (current + 1) % options.length;
        else if (event.key === "ArrowUp") index = (current - 1 + options.length) % options.length;
        else if (event.key === "Enter") { event.preventDefault(); options[current]?.click(); return; }
        else return;
        event.preventDefault(); this.activeId = options[index]?.id || null; this.sync(); options[index]?.scrollIntoView({block: "nearest"});
      }, {signal: this.abort.signal});
      this.el.addEventListener("click", event => { if (event.target.closest('[role="option"]')) this.close(true); }, {signal: this.abort.signal});
      document.addEventListener("click", event => { if (!this.el.contains(event.target)) this.close(); }, {signal: this.abort.signal});
      document.addEventListener("focusin", event => { if (!this.el.contains(event.target)) this.close(); }, {signal: this.abort.signal});
      this.sync();
    },
    beforeUpdate() { this.wasOpen = this.el.open; },
    updated() { this.el.open = this.wasOpen; this.sync(); this.menuSize.fit(); },
    destroyed() { this.menuSize.disconnect(); this.abort.abort(); }
  };
  const IssuePRMenu = {
    mounted() {
      this.abort = new AbortController();
      this.menuSize = observeChatDropdown(this.el, ".issue-pr-list", this.abort.signal);
      this.close = (focus = false) => { this.el.open = false; if (focus) this.el.querySelector('summary')?.focus(); };
      this.el.addEventListener('toggle', () => { if (this.el.open) this.el.querySelector('input[type="search"]')?.focus({preventScroll: true}); }, {signal: this.abort.signal});
      this.el.addEventListener('click', event => {
        if (event.target.closest('button, a')) this.close();
      }, {signal: this.abort.signal});
      this.el.addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); this.close(true); } }, {signal: this.abort.signal});
      document.addEventListener('click', event => { if (!this.el.contains(event.target)) this.close(); }, {signal: this.abort.signal});
      document.addEventListener('focusin', event => { if (!this.el.contains(event.target)) this.close(); }, {signal: this.abort.signal});
    },
    beforeUpdate() { this.wasOpen = this.el.open; },
    updated() { this.el.open = this.wasOpen; this.menuSize.fit(); },
    destroyed() { this.menuSize.disconnect(); this.abort.abort(); }
  };
  window.SymphonyHooks = {TaskBoard, BoardDialog, ChatWorkspace, IssueSwitcher, IssuePRMenu};
})();
