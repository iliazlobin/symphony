import React from "react";
import {createRoot} from "react-dom/client";
import {Excalidraw, MainMenu, CaptureUpdateAction, convertToExcalidrawElements} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import {createSceneModel, SECTION_IDS} from "./design-scene.js";

const model = createSceneModel(convertToExcalidrawElements);
const clone = value => JSON.parse(JSON.stringify(value));
export const nativeScene = true;
export const validate = (value, project) => model.migrate(value, project);
export const fields = value => model.fields(value);
export const empty = (project, values) => model.empty(project, values);

// Upstream SVG icons reuse local definition IDs. Scope each icon's definitions
// and references so several mounted editors remain valid in one LiveView page.
function scopeSvgIds(stage) {
  if (typeof MutationObserver === "undefined") return () => {};
  const identifiers = new WeakMap(); let sequence = 0;
  const scope = () => {
    for (const svg of stage.querySelectorAll("svg")) {
      const replacements = new Map();
      for (const element of svg.querySelectorAll("[id]")) {
        const original = element.id;
        if (!identifiers.has(element)) identifiers.set(element, {unique: `design-svg-${++sequence}-${Math.random().toString(36).slice(2, 10)}`, originals: new Set()});
        const identity = identifiers.get(element);
        if (original !== identity.unique) { identity.originals.add(original); element.id = identity.unique; }
        for (const alias of identity.originals) replacements.set(alias, identity.unique);
      }
      if (!replacements.size) continue;
      for (const element of [svg, ...svg.querySelectorAll("*")]) for (const attribute of [...element.attributes]) {
        let value = attribute.value.replace(/url\(#([^)]*)\)/g, (match, id) => replacements.has(id) ? `url(#${replacements.get(id)})` : match);
        if (["href", "xlink:href"].includes(attribute.name) && value.startsWith("#") && replacements.has(value.slice(1))) value = "#" + replacements.get(value.slice(1));
        if (["aria-labelledby", "aria-describedby"].includes(attribute.name)) value = value.split(/\s+/).map(id => replacements.get(id) || id).join(" ");
        if (value !== attribute.value) {
          if (attribute.namespaceURI) element.setAttributeNS(attribute.namespaceURI, attribute.name, value);
          else element.setAttribute(attribute.name, value);
        }
      }
    }
  };
  const observer = new MutationObserver(scope);
  observer.observe(stage, {childList: true, subtree: true, attributes: true, attributeFilter: ["id", "href", "xlink:href", "mask", "clip-path", "fill", "filter", "aria-labelledby", "aria-describedby"]});
  scope(); return () => observer.disconnect();
}

export function mount(root, options = {}) {
  const project = root.dataset.designProject;
  const stage = root.querySelector("[data-design-canvas]");
  const statusNode = root.querySelector("[data-canvas-status]");
  const suggestionNode = root.querySelector("[data-canvas-suggestions]");
  const fieldMap = new Map((options.fields || []).map(field => [field.dataset.designField, field]));
  let doc = model.migrate(options.document, project, Object.fromEntries([...fieldMap].map(([key, field]) => [key, field.value])));
  if (!doc) throw new Error("Design draft could not be opened safely");
  let section = "brief", destroyed = false, pending = null, selectedId = null, outlineSignature = null;
  const appearance = root.closest?.("[data-theme]");
  const theme = () => appearance?.dataset.theme === "dark" ? "dark" : "light";
  const themeObserver = !appearance || typeof MutationObserver === "undefined" ? null : new MutationObserver(() => render());
  if (appearance) themeObserver?.observe(appearance, {attributes: true, attributeFilter: ["data-theme"]});
  const outline = root.querySelector("[data-design-outline]"), items = root.querySelector("[data-design-items]"), inspector = root.querySelector("[data-design-inspector]");
  const visited = new Set(), apis = new Map(), interacted = new Set(), invalidBoards = new Set(), editing = new Map();
  const saveSafe = () => invalidBoards.size === 0;
  const reactRoot = createRoot(stage), abort = new AbortController(), unScope = scopeSvgIds(stage);
  const status = text => { if (statusNode) { statusNode.textContent = text; statusNode.hidden = !text; } };
  const syncFields = () => { const values = model.fields(doc); for (const [key, field] of fieldMap) field.value = values[key] || ""; };
  const notify = () => { syncFields(); renderOutline(); options.onChange?.(); };
  function capture(part, elements, state) {
    if (destroyed || state.isLoading) return;
    if (part === section) {
      const selected = elements.filter(element => !element.isDeleted && state.selectedElementIds?.[element.id]);
      const identities = [...new Set(selected.map(element => element.customData?.symphony?.id).filter(Boolean))];
      const nextSelected = identities.length === 1 && model.projection(doc, part).nodes.some(node => node.id === identities[0]) ? identities[0] : null;
      if (selectedId !== nextSelected) { selectedId = nextSelected; renderOutline(); }
    }
    const fitTextId = state.editingTextElement ? undefined : editing.get(part);
    if (state.editingTextElement) editing.set(part, state.editingTextElement.id);
    else editing.delete(part);
    const normalized = model.normalizeElements(elements, part, {adoptBoundText: !state.editingTextElement && !state.newElement, fitTextId});
    const next = clone(doc), before = next.boards[part];
    const contentChanged = model.fingerprint(before.elements) !== model.fingerprint(normalized);
    const camera = {scrollX: state.scrollX, scrollY: state.scrollY, zoom: {value: state.zoom.value}};
    const cameraChanged = JSON.stringify(before.appState) !== JSON.stringify(camera);
    if (!contentChanged && !cameraChanged && !invalidBoards.has(part)) return;
    next.boards[part] = {elements: normalized, appState: camera};
    if (contentChanged && interacted.has(part)) next.revision++;
    const valid = model.validate(next, project);
    if (!valid) { invalidBoards.add(part); status("Changes exceed this draft's limits. Export the drawing before reloading."); options.onChange?.(); if (pending) preview(); return; }
    const recovered = invalidBoards.delete(part);
    doc = valid; syncFields();
    if (model.fingerprint(elements) !== model.fingerprint(normalized)) {
      apis.get(part)?.updateScene({elements: clone(normalized), captureUpdate: CaptureUpdateAction.NEVER});
    }
    if (recovered && saveSafe()) status("");
    if (interacted.has(part)) { notify(); if (pending) preview(); }
  }
  function update(next, part, captureUpdate = CaptureUpdateAction.IMMEDIATELY) {
    if (!saveSafe()) { status("Keep your unsaved drawing. Undo or export it before applying changes."); return false; }
    if (!next) { status("This change no longer matches the drawing. Ask for fresh feedback."); return false; }
    doc = next; interacted.add(part);
    const board = doc.boards[part];
    apis.get(part)?.updateScene({elements: clone(board.elements), captureUpdate});
    notify(); return true;
  }
  function add(part) {
    const kind = part === "data" ? "entity" : part === "architecture" ? "component" : "note";
    const next = model.add(doc, part, kind, {text: kind === "entity" ? "id: identifier\nname: text" : kind === "component" ? "Responsibility" : "Write an idea…"});
    if (update(next, part)) {
      const last = doc.boards[part].elements.filter(el => !el.isDeleted && el.customData?.symphony?.role === "node").at(-1);
      if (last) {
        const ids = Object.fromEntries(doc.boards[part].elements.filter(el => !el.isDeleted && el.customData?.symphony?.id === last.customData.symphony.id).map(el => [el.id, true]));
        apis.get(part)?.updateScene({appState: {selectedElementIds: ids}, captureUpdate: CaptureUpdateAction.NEVER});
        apis.get(part)?.scrollToContent(last, {fitToContent: false, animate: true});
      }
    }
  }
  function fit(part) {
    const api = apis.get(part);
    if (!api) return;
    api.updateScene({appState: {selectedElementIds: {}, selectedGroupIds: {}, editingGroupId: null}, captureUpdate: CaptureUpdateAction.NEVER});
    api.scrollToContent(api.getSceneElements(), {fitToContent: true, animate: true});
  }
  function Editor({part, visible}) {
    const initial = doc.boards[part];
    return <div className="design-native-board" hidden={!visible} data-design-board={part}>
      <Excalidraw
        initialData={{elements: clone(initial.elements), appState: {...initial.appState, currentItemFontFamily: 2, currentItemRoughness: 1, viewBackgroundColor: "#fcfcfe"}}}
        excalidrawAPI={api => { if (!destroyed) apis.set(part, api); }}
        onChange={(elements, state) => capture(part, elements, state)}
        onDuplicate={elements => model.normalizeElements(elements, part)}
        onPaste={data => !Object.keys(data.files || {}).length && !(data.elements || []).some(el => ["image", "embeddable", "iframe"].includes(el.type))}
        onLinkOpen={(_element, event) => event.preventDefault()}
        UIOptions={{tools: {image: false}, canvasActions: {loadScene: false, toggleTheme: false, export: {saveFileToDisk: true}}}}
        handleKeyboardGlobally={false} aiEnabled={false} validateEmbeddable={false} autoFocus={false} theme={theme()}
        name={`${project.split("/").at(-1)}-${part}`}
        renderTopRightUI={() => <div className="design-native-actions">
          <button type="button" onClick={() => add(part)}>{part === "data" ? "+ Entity" : part === "architecture" ? "+ Component" : "+ Note"}</button>
          <button type="button" onClick={() => fit(part)}>Fit</button>
        </div>}
      >
        <MainMenu><MainMenu.DefaultItems.SaveToActiveFile /><MainMenu.DefaultItems.Export /><MainMenu.DefaultItems.Help /></MainMenu>
      </Excalidraw>
    </div>;
  }
  function render() {
    if (destroyed) return;
    visited.add(section);
    reactRoot.render(<>{[...visited].map(part => <Editor key={part} part={part} visible={part === section} />)}</>);
  }
  const text = (tag, value, className) => { const el = root.ownerDocument.createElement(tag); el.textContent = value; if (className) el.className = className; return el; };
  function selectNode(id) {
    const members = doc.boards[section].elements.filter(element => !element.isDeleted && element.customData?.symphony?.id === id);
    const shape = members.find(element => element.customData?.symphony?.role === "node");
    if (!shape) return;
    selectedId = id; apis.get(section)?.updateScene({appState: {selectedElementIds: Object.fromEntries(members.map(element => [element.id, true]))}, captureUpdate: CaptureUpdateAction.NEVER});
    apis.get(section)?.scrollToContent(shape, {fitToContent: false, animate: true}); renderOutline();
  }
  function renderOutline() {
    if (!items || !inspector) return;
    const board = model.projection(doc, section), signature = JSON.stringify([section, selectedId, board]);
    if (signature === outlineSignature) return;
    outlineSignature = signature; items.replaceChildren(); inspector.replaceChildren();
    if (!board.nodes.length) items.append(text("p", "Add a note, entity or component to structure this step.", "design-outline-empty"));
    for (const node of board.nodes) {
      const button = text("button", node.title || "Untitled item", "design-item"); button.type = "button"; button.dataset.designItem = node.id;
      button.setAttribute("aria-pressed", String(node.id === selectedId));
      button.append(text("small", node.kind)); button.addEventListener("click", () => selectNode(node.id)); items.append(button);
    }
    const node = board.nodes.find(node => node.id === selectedId);
    if (!node) { inspector.append(text("p", "Select an item to edit the same content as the drawing.", "design-outline-empty")); return; }
    const titleLabel = text("label", "Title"), titleInput = root.ownerDocument.createElement("input");
    titleInput.value = node.title; titleInput.maxLength = 160; titleInput.setAttribute("aria-label", "Design item title"); titleLabel.append(titleInput);
    const detailsLabel = text("label", section === "data" ? "Fields and rules" : "Details"), detailsInput = root.ownerDocument.createElement("textarea");
    detailsInput.value = node.text; detailsInput.maxLength = 12000; detailsInput.rows = 7; detailsInput.setAttribute("aria-label", "Design item details"); detailsLabel.append(detailsInput);
    const commit = () => {
      if (titleInput.value === node.title && detailsInput.value === node.text) return;
      if (!options.canApply?.()) { status("Save or resolve the draft conflict before editing its outline."); return; }
      if (!update(model.edit(doc, section, node.id, {title: titleInput.value, text: detailsInput.value}), section)) status("Keep titles under 160 bytes; details under 12,000 characters.");
    };
    titleInput.addEventListener("change", commit); detailsInput.addEventListener("change", commit);
    inspector.append(titleLabel, detailsLabel);
    const apply = text("button", "Apply edit", "button button-small"); apply.type = "button";
    apply.addEventListener("click", commit); inspector.append(apply);
    const related = board.edges.filter(edge => edge.from === node.id || edge.to === node.id);
    if (related.length) {
      const relations = text("ul", "", "design-item-relationships");
      for (const edge of related) {
        const other = board.nodes.find(item => item.id === (edge.from === node.id ? edge.to : edge.from));
        const link = text("button", `${edge.from === node.id ? "→" : "←"} ${other?.title || "Item"}${edge.label ? " · " + edge.label : ""}`); link.type = "button"; link.addEventListener("click", () => selectNode(other?.id)); relations.append(link);
      }
      inspector.append(relations);
    }
    const plan = text("button", "Prepare task", "button button-small"); plan.type = "button"; plan.dataset.designPlanItem = node.id;
    plan.addEventListener("click", () => options.plan?.(section, node.id)); inspector.append(plan);
    inspector.append(text("p", "Starts a Backlog task from this reviewed item. Inspect the preview before creating it.", "design-outline-empty"));
  }
  function preview() {
    suggestionNode.replaceChildren(); suggestionNode.hidden = !pending;
    if (!pending) return;
    const next = model.proposal(doc, pending);
    suggestionNode.append(text("strong", "Suggested changes"));
    const current = model.projection(doc, pending.section);
    const list = root.ownerDocument.createElement("ul"); list.className = "design-suggestion-list";
    for (const change of pending.changes) {
      const item = root.ownerDocument.createElement("li");
      const node = current.nodes.find(node => node.id === change.id);
      const labels = {add_node: "Add", update_node: "Update", remove_node: "Remove", add_edge: "Connect", remove_edge: "Remove connection"};
      item.append(text("span", `${labels[change.op]} ${change.node?.title || node?.title || change.edge?.label || change.id || ""}`));
      if (change.op === "update_node") {
        for (const key of ["title", "text"]) if (change.patch[key] !== undefined) {
          item.append(text("span", node?.[key] || "(empty)", "design-suggestion-before"));
          item.append(text("span", change.patch[key], "design-suggestion-after"));
        }
      } else if (change.node?.text) item.append(text("span", change.node.text, "design-suggestion-after"));
      list.append(item);
    }
    suggestionNode.append(list);
    if (!next) suggestionNode.append(text("p", "The drawing changed. Ask for fresh feedback."));
    const actions = root.ownerDocument.createElement("div"); actions.className = "design-suggestion-actions";
    const apply = text("button", "Apply"); apply.type = "button"; apply.disabled = !next || !saveSafe(); apply.dataset.designSuggestionAction = "apply";
    const dismiss = text("button", "Dismiss"); dismiss.type = "button";
    dismiss.dataset.designSuggestionAction = "dismiss";
    actions.append(apply, dismiss); suggestionNode.append(actions);
  }
  suggestionNode.addEventListener("click", event => {
    const action = event.target.closest("[data-design-suggestion-action]")?.dataset.designSuggestionAction;
    if (!pending) return;
    if (action === "dismiss") { pending = null; preview(); status(""); }
    if (action === "apply") {
      if (!options.canApply?.() || !saveSafe()) { status("This draft changed or cannot be saved. No suggestion was applied."); return; }
      const candidate = model.proposal(doc, pending);
      if (update(candidate, pending.section)) { pending = null; preview(); status("Applied · Undo restores your drawing"); }
    }
  }, {signal: abort.signal});
  stage.addEventListener("pointerdown", () => interacted.add(section), {capture: true, signal: abort.signal});
  stage.addEventListener("keydown", () => interacted.add(section), {capture: true, signal: abort.signal});
  stage.addEventListener("wheel", () => interacted.add(section), {capture: true, signal: abort.signal, passive: true});
  for (const eventName of ["drop", "paste"]) stage.addEventListener(eventName, event => {
    const files = event.dataTransfer?.files || event.clipboardData?.files;
    if (files?.length) { event.preventDefault(); event.stopPropagation(); status("Use shapes and text here. Image attachments are not saved in this draft."); }
  }, {capture: true, signal: abort.signal});
  syncFields(); render(); renderOutline();
  return {
    document: () => clone(doc), canSave: saveSafe,
    changes: baseline => model.changes(doc, baseline),
    selectNode,
    editNode: (part, id, patch) => update(model.edit(doc, part, id, patch), part),
    replace(value) {
      const next = model.validate(value, project);
      if (!next || !saveSafe()) return false;
      doc = next; selectedId = null; pending = null; preview();
      for (const part of visited) apis.get(part)?.updateScene({elements: clone(doc.boards[part].elements), appState: doc.boards[part].appState, captureUpdate: CaptureUpdateAction.IMMEDIATELY});
      notify(); return true;
    },
    projection: part => model.projection(doc, part),
    select(part) { if (SECTION_IDS.includes(part)) { section = part; selectedId = null; render(); renderOutline(); } },
    hasContent(part) { const board = model.projection(doc, part); return board.nodes.some(node => !node.field || node.text.trim()) || board.edges.length > 0 || doc.boards[part].elements.some(el => !el.isDeleted && !el.customData?.symphony); },
    refreshFields() { if (!saveSafe()) return; const next = model.withFields(doc, Object.fromEntries([...fieldMap].map(([key, field]) => [key, field.value]))); if (next) { doc = next; for (const part of visited) apis.get(part)?.updateScene({elements: clone(doc.boards[part].elements), captureUpdate: CaptureUpdateAction.IMMEDIATELY}); notify(); } },
    example() { if (!saveSafe()) return; const next = model.example(doc); if (next) { doc = next; for (const part of visited) apis.get(part)?.updateScene({elements: clone(doc.boards[part].elements), captureUpdate: CaptureUpdateAction.IMMEDIATELY}); notify(); } },
    proposal(value) {
      if (!saveSafe() || !model.proposal(doc, value)) { status("This feedback does not match the current drawing. Ask for fresh feedback."); return false; }
      pending = clone(value); section = value.section; render(); preview(); return true;
    },
    destroy() { destroyed = true; abort.abort(); unScope(); themeObserver?.disconnect(); reactRoot.unmount(); apis.clear(); suggestionNode.replaceChildren(); }
  };
}
