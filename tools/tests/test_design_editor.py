"""Lifecycle checks against the actual React editor's public callbacks.

Excalidraw's native rendering and history are verified in the browser. This
fixture substitutes only its DOM/React host and imperative API, so rejected
callbacks and writes can be observed without starting a private project.
"""
import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
import assert from "node:assert/strict";
import fs from "node:fs";
import {createRequire} from "node:module";
import {pathToFileURL} from "node:url";
const root = process.argv[1], require = createRequire(root + "/elixir/assets/package.json");
const {transformSync} = require("esbuild");
const scene = await import(pathToFileURL(root + "/elixir/assets/design-scene.js").href);
const copy = value => JSON.parse(JSON.stringify(value));
let sequence = 0, host;
function convert(skeletons) {
  return skeletons.map(skeleton => {
    const lines = (skeleton.text || "").split("\n"), font = skeleton.fontSize || 16;
    const points = skeleton.points || [], xs = points.map(point => point[0]), ys = points.map(point => point[1]);
    return {id: "native-" + ++sequence, type: skeleton.type, x: 0, y: 0, angle: 0,
      width: 100, height: 100, groupIds: [], version: 1, versionNonce: 42, updated: 1,
      isDeleted: false, boundElements: null, ...copy(skeleton),
      ...(skeleton.type === "text" ? {text: skeleton.text || "", originalText: skeleton.originalText ?? skeleton.text ?? "",
        width: Math.max(...lines.map(line => line.length)) * font * .55, height: Math.max(1, lines.length) * font * 1.25} : {}),
      ...(["arrow", "line"].includes(skeleton.type) ? {startBinding: null, endBinding: null,
        width: points.length ? Math.max(...xs) - Math.min(...xs) : 100,
        height: points.length ? Math.max(...ys) - Math.min(...ys) : 0} : {})};
  });
}
class Element {
  constructor(tag = "div") { this.tag = tag; this.children = []; this.listeners = new Map(); this.hidden = false; this.dataset = {}; }
  append(...items) { for (const item of items) item.parent = this; this.children.push(...items); }
  replaceChildren(...items) { for (const item of this.children) item.parent = null; this.children = []; this.append(...items); }
  addEventListener(name, callback, options = {}) { this.listeners.set(name, {callback, signal: options.signal}); }
  querySelectorAll() { return []; }
  closest(selector) { return selector === "[data-design-suggestion-action]" && this.dataset.designSuggestionAction ? this : this.parent?.closest(selector); }
  dispatch(name, event = {target: this}) { const listener = this.listeners.get(name); if (!listener?.signal?.aborted) listener?.callback(event); this.parent?.dispatch(name, event); }
}
const React = {Fragment: "fragment", createElement(type, props, ...children) {
  return typeof type === "function" ? type({...props, children}) : {type, props: props || {}, children};
}};
function Excalidraw(props) {
  const part = props.name.split("-").at(-1), fixture = host;
  fixture.callbacks.set(part, props);
  // React re-renders retain an instance keyed by its section; API access must
  // not remount it or silently start another native-history owner.
  if (!fixture.apis.has(part)) fixture.apis.set(part, {
    updateScene(value) { fixture.updates.push({part, value: copy(value)}); },
    scrollToContent() { fixture.fits.push(part); },
    getSceneElements() { return fixture.controller.document().boards[part].elements; }
  });
  props.excalidrawAPI(fixture.apis.get(part));
  return null;
}
const MainMenu = () => null;
MainMenu.DefaultItems = {SaveToActiveFile: () => null, Export: () => null, Help: () => null};
const dependencies = {
  react: React,
  "react-dom/client": {createRoot: () => { const fixture = host; return {
    render() { fixture.renders++; }, unmount() { fixture.unmounted = true; }
  }; }},
  "@excalidraw/excalidraw": {Excalidraw, MainMenu, convertToExcalidrawElements: convert,
    CaptureUpdateAction: {IMMEDIATELY: "immediately", NEVER: "never"}},
  "@excalidraw/excalidraw/index.css": {}, "./design-scene.js": scene
};
const editorSource = fs.readFileSync(root + "/elixir/assets/design-editor.jsx", "utf8");
const transformed = transformSync(editorSource, {loader: "jsx", format: "cjs"}).code;
const module = {exports: {}};
new Function("require", "module", "exports", transformed)(name => {
  assert(name in dependencies, "Unexpected editor dependency: " + name); return dependencies[name];
}, module, module.exports);
const editor = module.exports, project = "github:example/events-concierge";
const camera = {isLoading: false, scrollX: 0, scrollY: 0, zoom: {value: 1}};
function mount(document) {
  const stage = new Element(), status = new Element("p"), suggestions = new Element("aside");
  const fields = Object.keys(scene.FIELD_SECTIONS).map(field => ({dataset: {designField: field}, value: ""}));
  const fixture = {stage, status, suggestions, fields, callbacks: new Map(), apis: new Map(),
    updates: [], fits: [], renders: 0, notifications: 0, unmounted: false, applyAuthorized: true};
  host = fixture;
  const root = {dataset: {designProject: project}, ownerDocument: {createElement: tag => new Element(tag)},
    querySelector(selector) { return selector === "[data-design-canvas]" ? stage :
      selector === "[data-canvas-status]" ? status : selector === "[data-canvas-suggestions]" ? suggestions : null; }};
  fixture.controller = editor.mount(root, {fields, document, canApply: () => fixture.applyAuthorized,
    onChange() { fixture.notifications++; }});
  fixture.select = part => { host = fixture; fixture.controller.select(part); };
  fixture.capture = (part, elements, state = camera) => fixture.callbacks.get(part).onChange(copy(elements), state);
  fixture.add = part => fixture.callbacks.get(part).renderTopRightUI().children[0].props.onClick();
  return fixture;
}
function invalid(elements) { const result = copy(elements); result.find(element => element.type === "text").originalText = "x".repeat(scene.SCENE_LIMITS.text + 1); return result; }
function findButton(element, label) { return element.tag === "button" && element.textContent === label ? element : element.children.map(child => findButton(child, label)).find(Boolean); }
function proposal(fixture, section, changes) { const document = fixture.controller.document(); return {version: 1, project, section,
  base_document: document.document_id, base_revision: document.revision, changes}; }
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for editor lifecycle tests")
@unittest.skipUnless((ROOT / "elixir/assets/node_modules/esbuild").exists(),
                     "Install the pinned editor build dependencies with npm ci in elixir/assets")
class DesignEditorTests(unittest.TestCase):
    def run_editor(self, script):
        result = subprocess.run(
            [shutil.which("node"), "--input-type=module", "-e", FIXTURE + script, str(ROOT)],
            capture_output=True, text=True, check=False, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_initialization_and_hidden_callbacks_do_not_emit_saves(self):
        self.run_editor(r'''
assert.equal(typeof MutationObserver, "undefined");
const source = editor.empty(project, {brief: "Original scope"}), original = copy(source), fixture = mount(source);
assert.deepEqual(source, original); assert.equal(fixture.notifications, 0); assert.equal(fixture.updates.length, 0);
fixture.capture("brief", fixture.controller.document().boards.brief.elements);
fixture.select("data"); fixture.capture("data", fixture.controller.document().boards.data.elements);
fixture.capture("brief", fixture.controller.document().boards.brief.elements, {...camera, scrollX: 100});
assert.equal(fixture.notifications, 0); assert.equal(fixture.updates.length, 0);
assert.equal(fixture.controller.document().revision, original.revision);
assert.equal(fixture.fields.find(field => field.dataset.designField === "brief").value, "Original scope");
assert.equal(fixture.apis.size, 2); assert(fixture.controller.canSave());
''')

    def test_svg_scope_repairs_react_rewrites_and_preserves_namespaces(self):
        self.run_editor(r'''
const observers = [];
globalThis.MutationObserver = class {
  constructor(callback) { this.callback = callback; observers.push(this); }
  observe(stage, options) { this.stage = stage; this.options = options; }
  disconnect() { this.disconnected = true; }
};
const fixture = mount(), observer = observers[0];
assert.equal(observer.stage, fixture.stage);
assert(observer.options.attributeFilter.includes("xlink:href"));
function icon() {
  const definition = {id: "a", attributes: []};
  const reference = {attributes: [
    {name: "mask", value: "url(#a)", namespaceURI: null},
    {name: "href", value: "#a", namespaceURI: null},
    {name: "xlink:href", value: "#a", namespaceURI: "http://www.w3.org/1999/xlink"},
    {name: "aria-labelledby", value: "a other", namespaceURI: null}
  ], writes: [], setAttribute(name, value) {
    this.attributes.find(attribute => attribute.name === name).value = value;
    this.writes.push({name, value, namespace: null});
  }, setAttributeNS(namespace, name, value) {
    this.attributes.find(attribute => attribute.name === name).value = value;
    this.writes.push({name, value, namespace});
  }};
  const svg = {attributes: [], querySelectorAll(selector) {
    return selector === "[id]" ? [definition] : [definition, reference];
  }};
  return {definition, reference, svg};
}
const first = icon(), second = icon();
fixture.stage.querySelectorAll = selector => selector === "svg" ? [first.svg, second.svg] : [];
observer.callback();
assert.notEqual(first.definition.id, second.definition.id);
for (const instance of [first, second]) {
  const unique = instance.definition.id;
  assert.notEqual(unique, "a");
  assert.deepEqual(instance.reference.attributes.map(attribute => attribute.value),
    [`url(#${unique})`, `#${unique}`, `#${unique}`, `${unique} other`]);
  assert(instance.reference.writes.some(write => write.name === "xlink:href" &&
    write.namespace === "http://www.w3.org/1999/xlink"));
  // React can rewrite references while leaving the scoped definition intact.
  instance.reference.attributes[0].value = "url(#a)";
  instance.reference.attributes[1].value = "#a";
  instance.reference.attributes[2].value = "#a";
  instance.reference.attributes[3].value = "a other";
}
const originalIds = [first.definition.id, second.definition.id];
observer.callback();
assert.deepEqual([first.definition.id, second.definition.id], originalIds);
for (const instance of [first, second]) assert.deepEqual(instance.reference.attributes.map(attribute => attribute.value),
  [`url(#${instance.definition.id})`, `#${instance.definition.id}`, `#${instance.definition.id}`, `${instance.definition.id} other`]);
const writeCount = first.reference.writes.length + second.reference.writes.length;
observer.callback();
assert.equal(first.reference.writes.length + second.reference.writes.length, writeCount);
fixture.controller.destroy(); assert(observer.disconnected);
delete globalThis.MutationObserver;
''')

    def test_invalid_scene_cannot_be_replaced_by_add_example_or_field_refresh(self):
        self.run_editor(r'''
const fixture = mount(), baseline = fixture.controller.document();
fixture.stage.dispatch("pointerdown"); fixture.capture("brief", invalid(baseline.boards.brief.elements));
assert.equal(fixture.controller.canSave(), false);
const rejectedNotifications = fixture.notifications;
fixture.add("brief"); fixture.controller.example();
fixture.fields.find(field => field.dataset.designField === "brief").value = "A new field value";
fixture.controller.refreshFields();
assert.equal(fixture.updates.length, 0); assert.equal(fixture.notifications, rejectedNotifications);
assert.equal(fixture.controller.canSave(), false); assert.deepEqual(fixture.controller.document(), baseline);
// Undo or a direct native correction may return the invalid board to validity.
fixture.capture("brief", baseline.boards.brief.elements);
assert(fixture.controller.canSave()); fixture.add("brief"); assert(fixture.updates.length > 0);
''')

    def test_hidden_board_cannot_clear_another_boards_invalid_content(self):
        self.run_editor(r'''
const fixture = mount(); fixture.select("data"); const baseline = fixture.controller.document();
fixture.stage.dispatch("pointerdown"); fixture.capture("data", invalid(baseline.boards.data.elements));
assert.equal(fixture.controller.canSave(), false);
const rejectedNotifications = fixture.notifications;
fixture.capture("brief", baseline.boards.brief.elements);
fixture.capture("brief", baseline.boards.brief.elements, {...camera, scrollY: 100});
assert.equal(fixture.controller.canSave(), false); fixture.select("brief"); fixture.add("brief");
assert.equal(fixture.updates.length, 0); assert.equal(fixture.notifications, rejectedNotifications);
fixture.capture("data", baseline.boards.data.elements);
assert(fixture.controller.canSave()); fixture.add("brief"); assert(fixture.updates.length > 0);
''')

    def test_destroy_ignores_delayed_native_callbacks(self):
        self.run_editor(r'''
const fixture = mount(), baseline = fixture.controller.document(), delayed = fixture.callbacks.get("brief").onChange;
fixture.controller.destroy(); fixture.stage.dispatch("pointerdown");
const changed = copy(baseline.boards.brief.elements); changed[0].x += 100;
delayed(changed, camera); delayed(invalid(changed), camera);
assert.deepEqual(fixture.controller.document(), baseline); assert(fixture.controller.canSave());
assert.equal(fixture.notifications, 0); assert.equal(fixture.updates.length, 0); assert(fixture.unmounted);
''')

    def test_review_rechecks_current_revision_and_cross_tab_authority_on_apply(self):
        self.run_editor(r'''
const fixture = mount(), change = [{op: "update_node", id: "note-brief", patch: {text: "Reviewed scope"}}];
assert(fixture.controller.proposal(proposal(fixture, "brief", change)));
const original = fixture.controller.document(), changed = copy(original.boards.brief.elements);
fixture.stage.dispatch("pointerdown"); changed.find(element => element.customData?.symphony?.role === "body").originalText = "New human scope";
fixture.capture("brief", changed);
const apply = findButton(fixture.suggestions, "Apply"); assert(apply.disabled);
apply.dispatch("click"); assert.equal(fixture.updates.length, 0);
assert.equal(editor.fields(fixture.controller.document()).brief, "New human scope");
const next = proposal(fixture, "brief", change); assert(fixture.controller.proposal(next));
fixture.applyAuthorized = false; findButton(fixture.suggestions, "Apply").dispatch("click");
assert.equal(fixture.updates.length, 0); assert.equal(editor.fields(fixture.controller.document()).brief, "New human scope");
fixture.applyAuthorized = true;
findButton(fixture.suggestions, "Apply").dispatch("click");
assert.equal(editor.fields(fixture.controller.document()).brief, "Reviewed scope");
assert.equal(fixture.updates.at(-1).value.captureUpdate, "immediately");
''')


if __name__ == "__main__":
    unittest.main()
