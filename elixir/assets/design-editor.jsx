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
  let section = "brief", destroyed = false, pending = null;
  const visited = new Set(), apis = new Map(), interacted = new Set(), invalidBoards = new Set(), editing = new Map();
  const saveSafe = () => invalidBoards.size === 0;
  const reactRoot = createRoot(stage), abort = new AbortController(), unScope = scopeSvgIds(stage);
  const status = text => { if (statusNode) { statusNode.textContent = text; statusNode.hidden = !text; } };
  const syncFields = () => { const values = model.fields(doc); for (const [key, field] of fieldMap) field.value = values[key] || ""; };
  const notify = () => { syncFields(); options.onChange?.(); };
  function capture(part, elements, state) {
    if (destroyed || state.isLoading) return;
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
        handleKeyboardGlobally={false} aiEnabled={false} validateEmbeddable={false} autoFocus={false} theme="light"
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
  syncFields(); render();
  return {
    document: () => clone(doc), canSave: saveSafe,
    projection: part => model.projection(doc, part),
    select(part) { if (SECTION_IDS.includes(part)) { section = part; render(); } },
    hasContent(part) { const board = model.projection(doc, part); return board.nodes.some(node => !node.field || node.text.trim()) || board.edges.length > 0 || doc.boards[part].elements.some(el => !el.isDeleted && !el.customData?.symphony); },
    refreshFields() { if (!saveSafe()) return; const next = model.withFields(doc, Object.fromEntries([...fieldMap].map(([key, field]) => [key, field.value]))); if (next) { doc = next; for (const part of visited) apis.get(part)?.updateScene({elements: clone(doc.boards[part].elements), captureUpdate: CaptureUpdateAction.IMMEDIATELY}); notify(); } },
    example() { if (!saveSafe()) return; const next = model.example(doc); if (next) { doc = next; for (const part of visited) apis.get(part)?.updateScene({elements: clone(doc.boards[part].elements), captureUpdate: CaptureUpdateAction.IMMEDIATELY}); notify(); } },
    proposal(value) {
      if (!saveSafe() || !model.proposal(doc, value)) { status("This feedback does not match the current drawing. Ask for fresh feedback."); return false; }
      pending = clone(value); section = value.section; render(); preview(); return true;
    },
    destroy() { destroyed = true; abort.abort(); unScope(); reactRoot.unmount(); apis.clear(); suggestionNode.replaceChildren(); }
  };
}
