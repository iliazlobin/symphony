(function () {
  "use strict";

  const SECTIONS = ["brief", "requirements", "data", "architecture", "decisions"];
  const FIELD_SECTIONS = {brief: "brief", functional: "requirements", quality: "requirements", entities: "data", components: "architecture", flows: "architecture", decisions: "decisions"};
  const FIELD_TITLES = {brief: "Problem and scope", functional: "Functional requirements", quality: "Non-functional requirements", entities: "Entities and relationships", components: "Components", flows: "Main flows", decisions: "Decisions and open questions"};
  const FIELD_HINTS = {brief: "Who needs this? What should improve? What is outside this version?", functional: "What must users be able to do? One behavior per line.", quality: "What needs to be fast, reliable, secure or inexpensive?", entities: "Name the core concepts and their key fields. Add entity cards to explore relationships.", components: "Name the main responsibilities. Add component cards and connect them.", flows: "Follow one request from the user through the system.", decisions: "What is uncertain? What evidence would help us decide?"};
  const ID = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
  const validId = value => typeof value === "string" && ID.test(value);
  const clone = value => JSON.parse(JSON.stringify(value));
  const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const keys = (value, allowed) => plain(value) && Object.keys(value).every(key => allowed.includes(key));
  const finite = (value, min, max) => typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;
  const bytes = value => new TextEncoder().encode(value).length;
  const text = (value, limit) => typeof value === "string" && value.length <= limit;
  const revision = value => Number.isSafeInteger(value) && value >= 0;
  const point = value => Array.isArray(value) && value.length === 2 && value.every(v => finite(v, -10000, 10000));
  const safeProject = value => typeof value === "string" && value.length > 0 && value.length <= 512;
  const bounded = (value, min, max) => Math.max(min, Math.min(max, value));
  const round = value => Math.round(value * 100) / 100;
  let sequence = 0;
  const uid = prefix => prefix + "-" + Date.now().toString(36) + "-" + (++sequence).toString(36);

  function validNode(node, section) {
    return keys(node, ["id", "kind", "title", "text", "x", "y", "width", "field"]) &&
      validId(node.id) && ["note", "component", "entity"].includes(node.kind) &&
      text(node.title, 160) && text(node.text, 12000) && finite(node.x, -10000, 10000) && finite(node.y, -10000, 10000) &&
      (node.width === undefined || finite(node.width, 180, 480)) &&
      (node.field === undefined || (node.kind === "note" && FIELD_SECTIONS[node.field] === section && node.id === "note-" + node.field));
  }

  function validate(value, project) {
    try {
      if (!keys(value, ["version", "project", "document_id", "revision", "boards"]) || value.version !== 1 || value.project !== project || !validId(value.document_id) || !safeProject(project) ||
          (value.revision !== undefined && !revision(value.revision)) || !keys(value.boards, SECTIONS) || SECTIONS.some(section => !plain(value.boards[section])) ||
          bytes(JSON.stringify(value)) > 700000) return null;
      const allIds = new Set(), allFields = new Set();
      for (const section of SECTIONS) {
        const board = value.boards[section];
        if (!keys(board, ["nodes", "edges", "strokes", "viewport"]) || !Array.isArray(board.nodes) || board.nodes.length > 30 ||
            !Array.isArray(board.edges) || board.edges.length > 60 || !Array.isArray(board.strokes) || board.strokes.length > 30 ||
            !keys(board.viewport, ["x", "y", "scale"]) || !finite(board.viewport.x, -30000, 30000) || !finite(board.viewport.y, -30000, 30000) ||
            !finite(board.viewport.scale, 0.2, 2.5)) return null;
        const localIds = new Set();
        for (const node of board.nodes) {
          if (!validNode(node, section) || allIds.has(node.id) || (node.field && allFields.has(node.field))) return null;
          localIds.add(node.id); allIds.add(node.id); if (node.field) allFields.add(node.field);
        }
        for (const edge of board.edges) {
          if (!keys(edge, ["id", "from", "to", "label"]) || !validId(edge.id) || allIds.has(edge.id) || !localIds.has(edge.from) ||
              !localIds.has(edge.to) || edge.from === edge.to || !text(edge.label, 160)) return null;
          allIds.add(edge.id);
        }
        for (const stroke of board.strokes) {
          if (!keys(stroke, ["id", "points"]) || !validId(stroke.id) || allIds.has(stroke.id) || !Array.isArray(stroke.points) ||
              stroke.points.length < 2 || stroke.points.length > 600 || !stroke.points.every(point)) return null;
          allIds.add(stroke.id);
        }
      }
      if (allFields.size !== Object.keys(FIELD_SECTIONS).length) return null;
      const result = clone(value); result.revision = value.revision || 0; return result;
    } catch (_) { return null; }
  }

  function empty(project) {
    if (!safeProject(project)) throw Error("A project is required for a design canvas.");
    const boards = Object.fromEntries(SECTIONS.map(section => [section, {nodes: [], edges: [], strokes: [], viewport: {x: 28, y: 28, scale: 1}}]));
    for (const [field, section] of Object.entries(FIELD_SECTIONS)) {
      const index = boards[section].nodes.length;
      boards[section].nodes.push({id: "note-" + field, kind: "note", field, title: FIELD_TITLES[field], text: "", x: index * 350, y: 0, width: 320});
    }
    return {version: 1, project, document_id: "design-" + (window.crypto?.randomUUID ? window.crypto.randomUUID() : uid("draft") + "-" + Math.random().toString(36).slice(2, 12)), revision: 0, boards};
  }

  function validProposal(value, project) {
    if (!keys(value, ["version", "project", "section", "base_document", "base_revision", "changes"]) || value.version !== 1 || value.project !== project ||
        !SECTIONS.includes(value.section) || !validId(value.base_document) || !revision(value.base_revision) || !Array.isArray(value.changes) || !value.changes.length || value.changes.length > 24 ||
        bytes(JSON.stringify(value)) > 32768) return false;
    const affected = new Set();
    for (const change of value.changes) {
      if (!plain(change)) return false;
      if (change.op === "add_node") {
        const node = change.node;
        if (!keys(change, ["op", "node"]) || !keys(node, ["id", "kind", "title", "text", "x", "y"]) ||
            (node.id !== undefined && !validId(node.id)) || !["note", "component", "entity"].includes(node.kind) ||
            typeof node.title !== "string" || bytes(node.title) > 160 || typeof node.text !== "string" || bytes(node.text) > 4000 ||
            (node.x !== undefined && !finite(node.x, -10000, 10000)) || (node.y !== undefined && !finite(node.y, -10000, 10000))) return false;
      } else if (change.op === "update_node") {
        const patch = change.patch;
        if (!keys(change, ["op", "id", "patch"]) || !validId(change.id) || !keys(patch, ["title", "text", "x", "y"]) || !Object.keys(patch).length ||
            (patch.title !== undefined && (typeof patch.title !== "string" || bytes(patch.title) > 160)) ||
            (patch.text !== undefined && (typeof patch.text !== "string" || bytes(patch.text) > 4000)) ||
            ["x", "y"].some(key => patch[key] !== undefined && !finite(patch[key], -10000, 10000))) return false;
      } else if (["remove_node", "remove_edge"].includes(change.op)) {
        if (!keys(change, ["op", "id"]) || !validId(change.id)) return false;
      } else if (change.op === "add_edge") {
        const edge = change.edge;
        if (!keys(change, ["op", "edge"]) || !keys(edge, ["id", "from", "to", "label"]) ||
            (edge.id !== undefined && !validId(edge.id)) || !validId(edge.from) || !validId(edge.to) || edge.from === edge.to ||
            typeof edge.label !== "string" || bytes(edge.label) > 160) return false;
      } else return false;
      const id = change.id || change.node?.id || change.edge?.id;
      if (id && affected.has(id)) return false;
      if (id) affected.add(id);
    }
    return true;
  }

  function applyChanges(documentValue, suggestion) {
    if (!validProposal(suggestion, documentValue.project) || (suggestion.base_revision !== documentValue.revision || suggestion.base_document !== documentValue.document_id)) return null;
    const next = clone(documentValue), board = next.boards[suggestion.section];
    for (const change of suggestion.changes) {
      if (change.op === "add_node") {
        const count = board.nodes.length;
        board.nodes.push({...change.node, id: change.node.id || uid("n"), x: change.node.x ?? count % 3 * 290, y: change.node.y ?? Math.floor(count / 3) * 230});
      } else if (change.op === "update_node") {
        const node = board.nodes.find(node => node.id === change.id); if (!node) return null;
        Object.assign(node, change.patch);
      } else if (change.op === "remove_node") {
        const node = board.nodes.find(node => node.id === change.id); if (!node || node.field) return null;
        board.nodes = board.nodes.filter(node => node.id !== change.id);
        board.edges = board.edges.filter(edge => edge.from !== change.id && edge.to !== change.id);
      } else if (change.op === "add_edge") {
        board.edges.push({...change.edge, id: change.edge.id || uid("e")});
      } else if (change.op === "remove_edge") {
        if (!board.edges.some(edge => edge.id === change.id)) return null;
        board.edges = board.edges.filter(edge => edge.id !== change.id);
      }
    }
    next.revision++; return validate(next, next.project);
  }

  function mount(root, options = {}) {
    const project = root.dataset.designProject || options.document?.project;
    const dom = root.ownerDocument;
    const stage = root.querySelector("[data-design-canvas]");
    if (!stage) throw Error("The design canvas stage is missing.");
    stage.querySelector(".design-canvas-loading")?.remove();
    const abort = new AbortController(), signal = abort.signal;
    const fields = options.fields || [...root.querySelectorAll("[data-design-field]")];
    const fieldMap = new Map(fields.map(field => [field.dataset.designField, field]));
    let doc = validate(options.document, project) || empty(project), section = "brief", tool = "select", selected = null, connecting = null;
    let undo = [], redo = [], pending = null, gesture = null, editGroup = null;
    const world = dom.createElement("div"), svg = dom.createElementNS("http://www.w3.org/2000/svg", "svg");
    world.className = "design-canvas-world"; svg.classList.add("design-canvas-lines");
    svg.setAttribute("viewBox", "-10000 -10000 20000 20000"); svg.setAttribute("role", "group"); svg.setAttribute("aria-label", "Relationships and sketches"); world.append(svg); stage.append(world);
    const statusNode = root.querySelector("[data-canvas-status]"), scaleNode = root.querySelector("[data-canvas-scale]");
    const selectionNode = root.querySelector("[data-canvas-selection]"), suggestionNode = root.querySelector("[data-canvas-suggestions]");
    const status = message => { if (statusNode) statusNode.textContent = message; };
    const board = () => doc.boards[section];
    const snapshots = () => ({document: clone(doc), fields: Object.fromEntries([...fieldMap].map(([key, field]) => [key, field.value]))});
    const currentFields = () => { for (const part of Object.values(doc.boards)) for (const node of part.nodes) if (node.field && fieldMap.has(node.field)) node.text = fieldMap.get(node.field).value; };
    currentFields();
    const notify = () => { if (options.onChange) options.onChange(clone(doc)); };
    const syncFields = () => { for (const part of Object.values(doc.boards)) for (const node of part.nodes) if (node.field && fieldMap.has(node.field)) fieldMap.get(node.field).value = node.text; };
    const pushUndo = before => { undo.push(before); if (undo.length > 30) undo.shift(); redo = []; };
    function commit(before, message) {
      const candidate = validate({...doc, revision: before.document.revision + 1}, project);
      if (!candidate) { doc = before.document; for (const [key, value] of Object.entries(before.fields)) if (fieldMap.has(key)) fieldMap.get(key).value = value; status("Canvas limit reached. The previous draft is kept."); render(); return false; }
      doc = candidate; pushUndo(before); syncFields(); notify(); render(); if (message) status(message); return true;
    }
    const mutate = (fn, message) => { const before = snapshots(); editGroup = null; fn(); return commit(before, message); };
    const nodeWidth = node => node.width || (node.kind === "note" ? 320 : 240);
    const nodeHeight = node => Math.max(node.kind === "entity" ? 150 : 130, Math.min(370, 78 + (node.text.split("\n").length + Math.ceil(node.text.length / 38)) * 15));
    const screenPoint = event => { const rect = stage.getBoundingClientRect(); return {x: event.clientX - rect.left, y: event.clientY - rect.top}; };
    const canvasPoint = event => { const p = screenPoint(event), v = board().viewport; return {x: round(bounded((p.x - v.x) / v.scale, -10000, 10000)), y: round(bounded((p.y - v.y) / v.scale, -10000, 10000))}; };
    function element(tag, cls, content) { const el = dom.createElement(tag); if (cls) el.className = cls; if (content !== undefined) el.textContent = content; return el; }
    function svgElement(tag, attrs) { const el = dom.createElementNS("http://www.w3.org/2000/svg", tag); for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value); return el; }
    const clear = el => { while (el.firstChild) el.removeChild(el.firstChild); };
    function transform() {
      const v = board().viewport; world.style.transform = `translate(${v.x}px, ${v.y}px) scale(${v.scale})`;
      if (scaleNode) scaleNode.textContent = Math.round(v.scale * 100) + "%";
      stage.style.backgroundSize = 22 * v.scale + "px " + 22 * v.scale + "px";
      stage.style.backgroundPosition = v.x + "px " + v.y + "px";
    }
    function renderLines(part = board(), ghost = false) {
      for (const edge of part.edges) {
        const from = part.nodes.find(node => node.id === edge.from), to = part.nodes.find(node => node.id === edge.to); if (!from || !to) continue;
        const leftToRight = to.x >= from.x, start = {x: from.x + (leftToRight ? nodeWidth(from) : 0), y: from.y + 47};
        const end = {x: to.x + (leftToRight ? 0 : nodeWidth(to)), y: to.y + 47};
        const bend = Math.max(35, Math.abs(end.x - start.x) * 0.4), direction = leftToRight ? 1 : -1;
        const d = `M ${start.x} ${start.y} C ${start.x + bend * direction} ${start.y}, ${end.x - bend * direction} ${end.y}, ${end.x} ${end.y}`;
        const path = svgElement("path", {d, class: "design-canvas-edge" + (ghost ? " is-proposed" : "") + (selected === edge.id ? " is-selected" : ""), "marker-end": "url(#" + root.id + "-canvas-arrow)"});
        if (!ghost) { path.dataset.canvasEdge = edge.id; path.style.pointerEvents = "stroke"; path.setAttribute("role", "button"); path.setAttribute("tabindex", "0"); path.setAttribute("aria-label", "Relationship " + from.title + " to " + to.title + ": " + edge.label); }
        svg.append(path);
        if (edge.label) {
          const label = svgElement("text", {x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 8, class: "design-canvas-edge-label", "text-anchor": "middle"});
          label.textContent = edge.label; if (!ghost) label.dataset.canvasEdge = edge.id; svg.append(label);
        }
      }
      for (const stroke of part.strokes) svg.append(svgElement("polyline", {points: stroke.points.map(p => p.join(",")).join(" "), class: "design-canvas-stroke", "data-canvas-stroke": stroke.id}));
    }
    function renderSelection() {
      if (!selectionNode) return;
      clear(selectionNode);
      const node = board().nodes.find(node => node.id === selected), edge = board().edges.find(edge => edge.id === selected);
      selectionNode.hidden = !node && !edge;
      if (node) {
        selectionNode.append(element("span", "design-selection-caption", node.kind === "entity" ? "Entity · edit fields on the card" : node.kind === "component" ? "Component · edit its responsibility" : "Note · type directly on the card"));
        if (!node.field) { const remove = element("button", "design-selection-delete", "Delete"); remove.type = "button"; remove.dataset.canvasAction = "delete"; selectionNode.append(remove); }
      } else if (edge) {
        const label = element("label", "design-selection-caption", "Relationship");
        const input = element("input", "design-relationship-label"); input.value = edge.label; input.maxLength = 160; input.dataset.canvasEdgeLabel = edge.id; input.setAttribute("aria-label", "Relationship label, for example 1 to many");
        label.append(input); selectionNode.append(label);
        const remove = element("button", "design-selection-delete", "Delete"); remove.type = "button"; remove.dataset.canvasAction = "delete"; selectionNode.append(remove);
      }
    }
    function renderSuggestions() {
      if (!suggestionNode) return;
      clear(suggestionNode); suggestionNode.hidden = !pending;
      if (!pending) return;
      const stale = pending.base_revision !== doc.revision || pending.base_document !== doc.document_id;
      suggestionNode.append(element("strong", "", stale ? "Draft changed — ask for a fresh suggestion" : "Suggested changes"));
      suggestionNode.append(element("p", "", stale ? "Nothing has been applied." : pending.changes.length + " change" + (pending.changes.length === 1 ? "" : "s") + " · review the preview before applying"));
      const list = element("ul", "design-suggestion-list");
      for (const change of pending.changes) {
        const target = doc.boards[pending.section].nodes.find(node => node.id === change.id);
        const item = element("li", "", ({add_node: "Add ", update_node: "Update ", remove_node: "Remove ", add_edge: "Connect ", remove_edge: "Remove relationship "}[change.op]) + (change.node?.title || change.patch?.title || target?.title || change.edge?.label || change.id || "cards"));
        const excerpt = value => value.length > 240 ? value.slice(0, 240) + "…" : value || "(empty)";
        if (change.op === "update_node" && target) {
          for (const key of ["title", "text"]) if (change.patch[key] !== undefined && change.patch[key] !== target[key]) {
            item.append(element("span", "design-suggestion-before", "Before: " + excerpt(target[key])), element("span", "design-suggestion-after", "After: " + excerpt(change.patch[key])));
          }
          if (change.patch.x !== undefined || change.patch.y !== undefined) item.append(element("span", "design-suggestion-after", "Move to " + (change.patch.x ?? target.x) + ", " + (change.patch.y ?? target.y)));
        } else if (change.op === "remove_node" && target) item.append(element("span", "design-suggestion-before", excerpt(target.text)));
        else if (change.op === "add_node" && change.node.text) item.append(element("span", "design-suggestion-after", excerpt(change.node.text)));
        list.append(item);
      }
      suggestionNode.append(list);
      const actions = element("div", "design-suggestion-actions");
      const apply = element("button", "", "Apply changes"); apply.type = "button"; apply.dataset.canvasAction = "apply"; apply.disabled = stale;
      const dismiss = element("button", "", "Dismiss"); dismiss.type = "button"; dismiss.dataset.canvasAction = "dismiss";
      actions.append(apply, dismiss); suggestionNode.append(actions);
    }
    function renderCard(node, ghost = false) {
      const card = element("article", "design-canvas-card design-canvas-" + node.kind + (ghost ? " is-proposed" : "") + (!ghost && selected === node.id ? " is-selected" : ""));
      card.dataset.canvasNode = node.id; card.dataset.canvasNodeId = node.id; card.style.left = node.x + "px"; card.style.top = node.y + "px"; card.style.width = nodeWidth(node) + "px";
      if (ghost) { card.append(element("strong", "design-proposed-title", node.title), element("p", "design-proposed-text", node.text)); world.append(card); return; }
      card.tabIndex = 0; card.setAttribute("aria-label", node.kind + ": " + node.title + ". Use arrow keys to move; Enter to edit.");
      const head = element("div", "design-canvas-card-head"); head.dataset.canvasDrag = node.id;
      const title = element("input", "design-canvas-card-title"); title.value = node.title; title.maxLength = 160; title.dataset.canvasTitle = node.id; title.setAttribute("aria-label", "Title of " + node.kind);
      const grip = element("span", "design-canvas-grip", "⋮⋮"); grip.setAttribute("aria-hidden", "true"); head.append(title, grip); card.append(head);
      const body = element("textarea", "design-canvas-card-text"); body.value = node.text; body.placeholder = node.field ? FIELD_HINTS[node.field] : node.kind === "entity" ? "id: identifier\nname: text\nAdd key fields here" : node.kind === "component" ? "What does this component own?" : "Capture an idea, question or constraint…";
      body.maxLength = node.field ? 12000 : 4000; body.dataset.canvasText = node.id; body.setAttribute("aria-label", node.field ? FIELD_TITLES[node.field] : "Details of " + node.title); body.rows = Math.max(3, Math.min(17, Math.ceil(node.text.length / 38) + node.text.split("\n").length));
      card.append(body);
      if (node.field && !node.text.trim()) card.append(element("span", "design-canvas-note-hint", "Start with a few bullets"));
      world.append(card);
    }
    function render() {
      for (const card of [...world.querySelectorAll(".design-canvas-card")]) card.remove();
      clear(svg);
      const defs = svgElement("defs", {}), marker = svgElement("marker", {id: root.id + "-canvas-arrow", viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 5, markerHeight: 5, orient: "auto-start-reverse"});
      marker.append(svgElement("path", {d: "M 1 1 L 9 5 L 1 9", fill: "none", stroke: "currentColor", "stroke-width": 1.7, "stroke-linecap": "round", "stroke-linejoin": "round"})); defs.append(marker); svg.append(defs);
      renderLines(); for (const node of board().nodes) renderCard(node);
      if (pending && pending.section === section && pending.base_revision === doc.revision) {
        const preview = applyChanges(doc, pending);
        if (preview) {
          const changed = new Set(pending.changes.filter(change => ["add_node", "update_node"].includes(change.op)).map(change => change.id || change.node?.id));
          for (const node of preview.boards[section].nodes) if (changed.has(node.id) || !board().nodes.some(old => old.id === node.id)) renderCard(node, true);
          const addedEdges = new Set(board().edges.map(edge => edge.id));
          renderLines({...preview.boards[section], edges: preview.boards[section].edges.filter(edge => !addedEdges.has(edge.id)), strokes: []}, true);
        }
      }
      transform(); renderSelection(); renderSuggestions();
      for (const button of root.querySelectorAll("[data-canvas-tool]")) button.setAttribute("aria-pressed", button.dataset.canvasTool === tool ? "true" : "false");
      const back = root.querySelector("[data-canvas-action='undo']"), forward = root.querySelector("[data-canvas-action='redo']"); if (back) back.disabled = !undo.length; if (forward) forward.disabled = !redo.length;
      stage.dataset.canvasMode = tool;
    }
    function select(id) { selected = id; render(); }
    function history(direction) {
      const source = direction === "undo" ? undo : redo, target = direction === "undo" ? redo : undo; if (!source.length) return;
      const before = snapshots(), restored = source.pop(); target.push(before); const nextRevision = doc.revision + 1; doc = restored.document; doc.revision = nextRevision;
      for (const [key, value] of Object.entries(restored.fields)) if (fieldMap.has(key)) fieldMap.get(key).value = value;
      selected = null; editGroup = null; syncFields(); notify(); render(); status(direction === "undo" ? "Change undone" : "Change restored");
    }
    function camera(fn) { fn(); notify(); transform(); }
    function zoom(factor, p) {
      camera(() => { const v = board().viewport, old = v.scale, next = bounded(old * factor, 0.2, 2.5); v.x = round(bounded(p.x - (p.x - v.x) * next / old, -30000, 30000)); v.y = round(bounded(p.y - (p.y - v.y) * next / old, -30000, 30000)); v.scale = round(next); });
    }
    function fit() {
      const nodes = board().nodes, points = board().strokes.flatMap(stroke => stroke.points);
      const bounds = nodes.flatMap(node => [[node.x, node.y], [node.x + nodeWidth(node), node.y + nodeHeight(node)]]).concat(points); if (!bounds.length) return;
      const left = Math.min(...bounds.map(p => p[0])), right = Math.max(...bounds.map(p => p[0])), top = Math.min(...bounds.map(p => p[1])), bottom = Math.max(...bounds.map(p => p[1]));
      const rect = stage.getBoundingClientRect(), s = bounded(Math.min((rect.width - 60) / Math.max(320, right - left), (rect.height - 60) / Math.max(160, bottom - top), 1), 0.2, 2.5);
      camera(() => { board().viewport = {x: round((rect.width - (right - left) * s) / 2 - left * s), y: round((rect.height - (bottom - top) * s) / 2 - top * s), scale: round(s)}; });
    }
    function add(kind) {
      const rect = stage.getBoundingClientRect(), v = board().viewport;
      const node = {id: uid("n"), kind, title: kind === "entity" ? "New entity" : kind === "component" ? "New component" : "New note", text: "", x: round(bounded((rect.width / 2 - v.x) / v.scale - 120, -10000, 10000)), y: round(bounded((rect.height / 2 - v.y) / v.scale - 60, -10000, 10000))};
      mutate(() => board().nodes.push(node), "Added " + kind + " · edit its title and details"); selected = node.id; tool = "select"; render();
      const input = world.querySelector(`[data-canvas-title="${node.id}"]`); if (input) { input.focus(); input.select(); }
    }
    function remove() {
      const node = board().nodes.find(node => node.id === selected);
      if (node?.field) { status("This section note keeps your original draft. Edit its text directly."); return; }
      if (!selected) return;
      mutate(() => { board().nodes = board().nodes.filter(node => node.id !== selected); board().edges = board().edges.filter(edge => edge.id !== selected && edge.from !== selected && edge.to !== selected); board().strokes = board().strokes.filter(stroke => stroke.id !== selected); selected = null; }, "Removed selection");
    }
    function apply() {
      if (!pending) return;
      try { if (options.canApply && !options.canApply()) { status("This draft changed in another tab. Reopen it before applying feedback."); return; } }
      catch (_) { status("Draft availability could not be checked. No suggestion was applied."); return; }
      const next = applyChanges(doc, pending); if (!next) { status("Suggestion no longer matches this draft. Ask for a fresh suggestion."); renderSuggestions(); return; }
      const before = snapshots(); doc = next; pending = null; syncFields(); pushUndo(before); notify(); render(); status("Suggested changes applied · Undo is available");
    }
    root.addEventListener("click", event => {
      const button = event.target.closest("[data-canvas-tool], [data-canvas-action]");
      if (button) {
        const chosen = button.dataset.canvasTool, action = button.dataset.canvasAction;
        if (chosen) { editGroup = null; connecting = null; if (["note", "component", "entity"].includes(chosen)) add(chosen); else { tool = chosen; render(); status(chosen === "connect" ? "Select the first card, then the card it connects to" : chosen === "draw" ? "Draw on the canvas · select a sketch to delete it" : chosen === "pan" ? "Drag the canvas to move around" : "Select, edit or move a card"); } }
        else if (action === "undo" || action === "redo") history(action);
        else if (action === "zoom-in" || action === "zoom-out") { const rect = stage.getBoundingClientRect(); zoom(action === "zoom-in" ? 1.2 : 1 / 1.2, {x: rect.width / 2, y: rect.height / 2}); }
        else if (action === "fit") fit(); else if (action === "delete") remove(); else if (action === "apply") apply();
        else if (action === "dismiss") { pending = null; render(); status("Suggestion dismissed · your draft is unchanged"); }
        return;
      }
      const edge = event.target.closest("[data-canvas-edge]"), stroke = event.target.closest("[data-canvas-stroke]"), nodeEl = event.target.closest("[data-canvas-node]");
      if (edge) { select(edge.dataset.canvasEdge); return; } if (stroke) { select(stroke.dataset.canvasStroke); return; }
      if (nodeEl && tool === "connect") {
        const id = nodeEl.dataset.canvasNode;
        if (!connecting) { connecting = id; select(id); status("Now select the destination card"); }
        else if (connecting !== id) { const from = connecting; mutate(() => board().edges.push({id: uid("e"), from, to: id, label: section === "data" ? "1 → many" : "uses"}), "Connected cards · select the arrow to name the relationship"); connecting = null; tool = "select"; render(); }
      }
    }, {signal});
    root.addEventListener("input", event => {
      const target = event.target, id = target.dataset.canvasTitle || target.dataset.canvasText || target.dataset.canvasEdgeLabel;
      if (!id) return;
      const node = board().nodes.find(node => node.id === id), edge = board().edges.find(edge => edge.id === id); if (!node && !edge) return;
      const key = target.dataset.canvasTitle ? "title" : target.dataset.canvasText ? "text" : "label";
      const before = snapshots(), value = target.value.slice(0, key === "text" ? node?.field ? 12000 : 4000 : 160);
      if (node) node[key] = value; else edge.label = value;
      if (node?.field && key === "text" && fieldMap.has(node.field)) fieldMap.get(node.field).value = value;
      const candidate = validate({...doc, revision: doc.revision + 1}, project);
      if (!candidate) { doc = before.document; target.value = node ? before.document.boards[section].nodes.find(n => n.id === id)[key] : edge.label; status("Canvas limit reached. The previous draft is kept."); return; }
      if (editGroup !== id + key) { pushUndo(before); editGroup = id + key; }
      doc = candidate; selected = id; notify(); renderSuggestions();
      if (key === "text") { target.rows = Math.max(3, Math.min(17, Math.ceil(value.length / 38) + value.split("\n").length)); const hint = target.parentElement.querySelector(".design-canvas-note-hint"); if (hint && value.trim()) hint.remove(); }
      if (key !== "label") renderSelection(); status("Draft updated");
      const back = root.querySelector("[data-canvas-action='undo']"); if (back) back.disabled = false;
    }, {signal});
    stage.addEventListener("pointerdown", event => {
      if (event.button !== 0 || event.target.closest("input,textarea,button")) return;
      const nodeEl = event.target.closest("[data-canvas-node]"), p = canvasPoint(event), v = board().viewport;
      if (tool === "connect") return;
      const before = snapshots(); editGroup = null;
      if (tool === "draw") gesture = {kind: "draw", before, stroke: {id: uid("s"), points: [[p.x, p.y]]}};
      else if (tool === "pan" || event.shiftKey || !nodeEl) gesture = {kind: "pan", before, start: screenPoint(event), x: v.x, y: v.y};
      else { const node = board().nodes.find(node => node.id === nodeEl.dataset.canvasNode); if (!node) return; selected = node.id; gesture = {kind: "node", before, id: node.id, start: p, x: node.x, y: node.y}; nodeEl.classList.add("is-selected"); renderSelection(); }
      event.preventDefault(); stage.setPointerCapture(event.pointerId);
    }, {signal});
    stage.addEventListener("pointermove", event => {
      if (!gesture) return;
      const p = canvasPoint(event);
      if (gesture.kind === "pan") { const screen = screenPoint(event); board().viewport.x = round(bounded(gesture.x + screen.x - gesture.start.x, -30000, 30000)); board().viewport.y = round(bounded(gesture.y + screen.y - gesture.start.y, -30000, 30000)); transform(); }
      else if (gesture.kind === "node") {
        const node = board().nodes.find(node => node.id === gesture.id); node.x = round(bounded(gesture.x + p.x - gesture.start.x, -10000, 10000)); node.y = round(bounded(gesture.y + p.y - gesture.start.y, -10000, 10000));
        const card = world.querySelector(`[data-canvas-node="${node.id}"]`); if (card) { card.style.left = node.x + "px"; card.style.top = node.y + "px"; }
        clear(svg); renderLines();
      } else {
        const points = gesture.stroke.points, last = points[points.length - 1]; if (points.length < 600 && Math.hypot(p.x - last[0], p.y - last[1]) > 2) points.push([p.x, p.y]);
        const existing = svg.querySelector(".design-canvas-live-stroke"); if (existing) existing.remove(); svg.append(svgElement("polyline", {points: points.map(p => p.join(",")).join(" "), class: "design-canvas-stroke design-canvas-live-stroke"}));
      }
    }, {signal});
    function finish(cancelled) {
      if (!gesture) return; const current = gesture; gesture = null;
      if (cancelled) { doc = current.before.document; render(); return; }
      if (current.kind === "draw") { if (current.stroke.points.length < 2) { render(); return; } board().strokes.push(current.stroke); }
      if (JSON.stringify(doc) === JSON.stringify(current.before.document)) { render(); return; }
      if (current.kind === "pan") { notify(); render(); return; }
      commit(current.before);
    }
    stage.addEventListener("pointerup", () => finish(false), {signal}); stage.addEventListener("pointercancel", () => finish(true), {signal});
    stage.addEventListener("wheel", event => {
      if (event.target.closest("textarea")) return;
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) zoom(Math.exp(-event.deltaY * 0.005), screenPoint(event));
      else camera(() => { const v = board().viewport; v.x = round(bounded(v.x - event.deltaX, -30000, 30000)); v.y = round(bounded(v.y - event.deltaY, -30000, 30000)); });
    }, {signal, passive: false});
    root.addEventListener("keydown", event => {
      const editing = event.target.closest("input,textarea,[contenteditable]");
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z" && !editing) { event.preventDefault(); history(event.shiftKey ? "redo" : "undo"); return; }
      if (editing) return;
      if (event.key === "Escape") { tool = "select"; connecting = null; selected = null; render(); return; }
      if (event.key === "Delete" || event.key === "Backspace") { if (selected) { event.preventDefault(); remove(); } return; }
      const card = event.target.closest("[data-canvas-node]"), edge = event.target.closest("[data-canvas-edge]");
      if (edge && event.key === "Enter") { event.preventDefault(); select(edge.dataset.canvasEdge); root.querySelector("[data-canvas-edge-label]")?.focus(); return; }
      if (!card) return;
      selected = card.dataset.canvasNode;
      if (event.key === "Enter") { event.preventDefault(); card.querySelector("textarea")?.focus(); return; }
      const delta = {ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0]}[event.key];
      if (delta) { event.preventDefault(); const step = event.shiftKey ? 24 : 8; mutate(() => { const node = board().nodes.find(node => node.id === selected); node.x = bounded(node.x + delta[0] * step, -10000, 10000); node.y = bounded(node.y + delta[1] * step, -10000, 10000); }); world.querySelector(`[data-canvas-node="${selected}"]`)?.focus(); }
    }, {signal});
    render();
    return {
      document: () => clone(doc),
      select(next) { if (!SECTIONS.includes(next)) return; finish(true); section = next; selected = null; connecting = null; editGroup = null; tool = "select"; render(); },
      refreshFields() { const before = snapshots(); currentFields(); if (JSON.stringify(doc) !== JSON.stringify(before.document)) commit(before); else render(); },
      hasContent(part) { const value = doc.boards[part]; return Boolean(value && (value.nodes.some(node => !node.field || node.text.trim()) || value.edges.length || value.strokes.length)); },
      example() {
        const before = snapshots(); let added = false;
        for (const part of ["data", "architecture"]) {
          const value = doc.boards[part]; if (value.nodes.some(node => !node.field) || value.edges.length || value.strokes.length) continue;
          const examples = part === "data" ? [
            ["User preferences", "id: identifier\ninterests: topics\narea: location"],
            ["Saved choice", "id: identifier\nuser_id: reference\nevent_id: reference"],
            ["Event", "id: identifier\ntitle: text\nstarts_at: timestamp"]
          ] : [["Web client", "Collect preferences and show events"], ["Backend", "Rank discovery results and save choices"], ["Data store", "Events, sources and saved choices"]];
          const newNodes = examples.map(([title, text], index) => ({id: uid("n"), kind: part === "data" ? "entity" : "component", title, text, x: index * 280, y: part === "data" ? 260 : 290}));
          value.nodes.push(...newNodes);
          for (let index = 0; index < 2; index++) value.edges.push({id: uid("e"), from: newNodes[index].id, to: newNodes[index + 1].id, label: part === "data" ? index === 0 ? "1 → many" : "many → 1" : index === 0 ? "requests" : "reads / writes"});
          added = true;
        }
        if (added) commit(before, "Illustrative diagrams added · edit or remove these assumptions");
        return added;
      },
      proposal(suggestion) {
        if (!validProposal(suggestion, project)) { status("This suggestion has an unsupported format. Your draft is unchanged."); return false; }
        if ((suggestion.base_revision !== doc.revision || suggestion.base_document !== doc.document_id)) { status("The draft changed since this suggestion. Ask for a fresh suggestion."); return false; }
        if (!applyChanges(doc, suggestion)) { status("This suggestion references unavailable cards. Your draft is unchanged."); return false; }
        pending = clone(suggestion); section = suggestion.section; selected = null; render(); status("Review suggested changes, then Apply or Dismiss"); return true;
      },
      destroy() { abort.abort(); world.remove(); if (selectionNode) clear(selectionNode); if (suggestionNode) clear(suggestionNode); }
    };
  }

  window.SymphonyDesignCanvas = {mount, validate, empty};
})();
