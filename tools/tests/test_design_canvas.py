"""Exercise the real visual design editor and its untrusted proposal boundary in Node."""
import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const sandbox = {window: {}, AbortController, TextEncoder};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const api = sandbox.window.SymphonyDesignCanvas, plain = value => JSON.parse(JSON.stringify(value));
const project = "github:example/events-concierge";
class Element {
  constructor(tag, owner) { this.tagName = tag.toUpperCase(); this.ownerDocument = owner; this.children = []; this.dataset = {}; this.style = {}; this.attributes = {}; this.listeners = new Map(); this.className = ""; this.value = ""; this.textContent = ""; this.hidden = false; this.focused = false; }
  get parentElement() { return this.parentNode; }
  get firstChild() { return this.children[0] || null; }
  get classList() { return {add: name => { if (!this.className.split(" ").includes(name)) this.className += " " + name; }, contains: name => this.className.split(" ").includes(name)}; }
  append(...children) { for (const child of children) { child.remove(); child.parentNode = this; this.children.push(child); } }
  removeChild(child) { this.children = this.children.filter(value => value !== child); child.parentNode = null; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(name, value) { this.attributes[name] = String(value); if (name === "class") this.className = value; if (name === "id") this.id = value; if (name.startsWith("data-")) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, x) => x.toUpperCase())] = String(value); }
  matches(selector) {
    return selector.split(",").some(raw => {
      const s = raw.trim(); if (s.startsWith(".")) return this.className.split(" ").includes(s.slice(1));
      const attr = s.match(/^\[([^=\]]+)(?:=['"]([^'"]*)['"])?\]$/);
      if (attr) { const name = attr[1], value = name.startsWith("data-") ? this.dataset[name.slice(5).replace(/-([a-z])/g, (_, x) => x.toUpperCase())] : this.attributes[name]; return attr[2] === undefined ? value !== undefined : value === attr[2]; }
      return this.tagName.toLowerCase() === s;
    });
  }
  closest(selector) { for (let node = this; node; node = node.parentNode) if (node.matches(selector)) return node; return null; }
  querySelectorAll(selector) { return this.children.flatMap(child => (child.matches(selector) ? [child] : []).concat(child.querySelectorAll(selector))); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  addEventListener(name, fn, options) { const handlers = this.listeners.get(name) || []; handlers.push({fn, options}); this.listeners.set(name, handlers); }
  dispatch(name, event = {}) { event.target ||= this; event.preventDefault ||= () => { event.prevented = true; }; for (const {fn, options} of this.listeners.get(name) || []) if (!options.signal.aborted) fn(event); return event; }
  getBoundingClientRect() { return {left: 0, top: 0, width: 800, height: 500}; }
  setPointerCapture() {}
  focus() { this.focused = true; }
  select() { this.selectedText = true; }
}
function mount(options = {}) {
  const document = {createElement: tag => new Element(tag, document), createElementNS: (_, tag) => new Element(tag, document)};
  const root = document.createElement("section"); root.dataset.designProject = project; root.id = "design-fixture";
  const make = (tag, key, value) => { const el = document.createElement(tag); el.dataset[key] = value; root.append(el); return el; };
  const stage = make("div", "designCanvas", "");
  const controls = Object.fromEntries(["undo", "redo", "zoom-in", "zoom-out", "fit", "delete"].map(action => [action, make("button", "canvasAction", action)]));
  const tools = Object.fromEntries(["select", "pan", "note", "component", "entity", "connect", "draw"].map(tool => [tool, make("button", "canvasTool", tool)]));
  const status = make("span", "canvasStatus", ""), scale = make("span", "canvasScale", ""), selection = make("aside", "canvasSelection", ""), suggestions = make("aside", "canvasSuggestions", "");
  const fields = Object.keys({brief:1,functional:1,quality:1,entities:1,components:1,flows:1,decisions:1}).map(name => { const field = make("textarea", "designField", name); field.value = options.fields?.[name] || ""; return field; });
  const changes = [], controller = api.mount(root, {fields, document: options.document, canApply: options.canApply, onChange: doc => changes.push(plain(doc))});
  const click = target => root.dispatch("click", {target});
  const input = (id, kind, value) => { const target = root.querySelector(`[data-canvas-${kind}="${id}"]`); assert(target, "input exists"); target.value = value; root.dispatch("input", {target}); return target; };
  return {root, stage, controls, tools, status, scale, selection, suggestions, fields, changes, controller, click, input};
}
function suggestion(editor, section, changes, overrides = {}) { return {version:1,project,section,base_document:editor.controller.document().document_id,base_revision:editor.controller.document().revision,changes,...overrides}; }
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for canvas tests")
class DesignCanvasTests(unittest.TestCase):
    def run_canvas(self, script):
        result = subprocess.run(
            [shutil.which("node"), "-e", FIXTURE + script,
             str(ROOT / "elixir/priv/static/design-canvas.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_validator_rejects_cross_project_dangling_and_unbounded_documents(self):
        self.run_canvas(r'''
const source = api.empty(project); assert(api.validate(source, project));
assert.equal(api.validate(source, "github:example/other"), null);
const missingIdentity=plain(source); delete missingIdentity.document_id; assert.equal(api.validate(missingIdentity,project),null);
for (const change of [d => d.boards.data.nodes[0].x = NaN,
 d => d.boards.data.nodes[0].id = undefined,
 d => d.boards.data.nodes[0].field = "brief",
 d => d.boards.data.nodes[0].title = "x".repeat(161),
 d => d.boards.data.nodes[0].text = "x".repeat(12001),
 d => d.boards.brief.nodes = [],
 d => d.boards.data.nodes.push({...d.boards.data.nodes[0]}),
 d => d.boards.data.edges.push({id:"edge-1",from:"note-entities",to:"missing",label:"uses"}),
 d => d.boards.data.strokes.push({id:"stroke-1",points:[[0,0],[10001,0]]}),
 d => d.boards.data.strokes.push({id:"stroke-1",points:Array.from({length:601},()=>[1,2])}),
 d => d.boards.data.viewport.scale = 0,
 d => d.boards.data.viewport.secret = "unknown",
 d => d.revision = Number.MAX_SAFE_INTEGER + 1]) {
 const d = plain(source); change(d); assert.equal(api.validate(d, project), null);
}
const old = plain(source); delete old.revision; assert.equal(api.validate(old,project).revision,0);
const cleaned = api.validate(source,project); cleaned.boards.data.nodes[0].text = "Independent copy";
assert.equal(source.boards.data.nodes[0].text, "");
''')

    def test_migration_keeps_legacy_text_and_new_cards_edit_undo_redo(self):
        self.run_canvas(r'''
const legacy = "Legacy requirements\n" + "中".repeat(11900);
const editor = mount({fields:{functional:legacy,brief:"My real scope"}});
assert.equal(editor.changes.length,0);
assert.equal(editor.controller.document().boards.requirements.nodes[0].text,legacy);
editor.controller.select("data"); editor.click(editor.tools.entity);
let doc = editor.controller.document(), node = doc.boards.data.nodes.find(n=>n.kind==="entity"); assert(node);
editor.input(node.id,"title","Event");
assert.equal(editor.root.querySelector(`[data-canvas-text="${node.id}"]`).attributes["aria-label"], "Details of Event");
editor.input(node.id,"text","id: UUID\ntitle: text");
assert.equal(editor.controller.document().boards.data.nodes.find(n=>n.id===node.id).text,"id: UUID\ntitle: text");
const beforeUndo = editor.controller.document().revision; editor.click(editor.controls.undo);
assert.equal(editor.controller.document().boards.data.nodes.find(n=>n.id===node.id).text,"");
assert.equal(editor.controller.document().revision,beforeUndo+1);
editor.click(editor.controls.redo); assert.equal(editor.controller.document().boards.data.nodes.find(n=>n.id===node.id).text,"id: UUID\ntitle: text");
editor.controller.select("brief"); editor.input("note-brief","text","Changed scope");
assert.equal(editor.fields.find(f=>f.dataset.designField==="brief").value,"Changed scope");
editor.click(editor.controls.undo); assert.equal(editor.fields.find(f=>f.dataset.designField==="brief").value,"My real scope");
assert.equal(editor.controller.document().boards.requirements.nodes[0].text,legacy);
const preserved = plain(editor.controller.document()); editor.controller.destroy();
const reload = mount({document:preserved,fields:Object.fromEntries(editor.fields.map(f=>[f.dataset.designField,f.value]))});
assert.deepEqual(plain(reload.controller.document()),preserved);
''')

    def test_connect_relationship_keyboard_move_delete_and_undo_preserve_references(self):
        self.run_canvas(r'''
const editor = mount(); editor.controller.select("data"); editor.click(editor.tools.entity); editor.click(editor.tools.entity);
const nodes = editor.controller.document().boards.data.nodes.filter(n=>n.kind==="entity");
assert(nodes[0].x !== nodes[1].x || nodes[0].y !== nodes[1].y, "consecutive cards have separate positions");
assert(nodes[0].x + 240 <= nodes[1].x || nodes[1].x + 240 <= nodes[0].x || nodes[0].y + 150 <= nodes[1].y || nodes[1].y + 150 <= nodes[0].y, "new cards do not cover each other");
editor.click(editor.tools.connect);
editor.click(editor.root.querySelector(`[data-canvas-node="${nodes[0].id}"]`));
editor.click(editor.root.querySelector(`[data-canvas-node="${nodes[1].id}"]`));
let edge = editor.controller.document().boards.data.edges[0]; assert.equal(edge.label,"1 → many");
const arrow = editor.root.querySelector(`[data-canvas-edge="${edge.id}"]`);
editor.stage.dispatch("pointerdown",{target:arrow,button:0,clientX:100,clientY:100,pointerId:1});
assert.equal(editor.selection.hidden,false); assert.equal(editor.controller.document().boards.data.viewport.x,28);
editor.click(arrow); editor.input(edge.id,"edge-label","many → many");
assert.equal(editor.controller.document().boards.data.edges[0].label,"many → many");
const card = editor.root.querySelector(`[data-canvas-node="${nodes[0].id}"]`), oldX = nodes[0].x;
editor.root.dispatch("keydown",{target:card,key:"ArrowRight"}); assert.equal(editor.controller.document().boards.data.nodes.find(n=>n.id===nodes[0].id).x,oldX+8);
editor.root.dispatch("keydown",{target:editor.root.querySelector(`[data-canvas-node="${nodes[0].id}"]`),key:"Delete"});
assert.equal(editor.controller.document().boards.data.edges.length,0);
editor.click(editor.controls.undo); assert.equal(editor.controller.document().boards.data.edges.length,1);
editor.root.dispatch("keydown",{target:editor.root.querySelector('[data-canvas-node="note-entities"]'),key:"Delete"});
assert(editor.controller.document().boards.data.nodes.some(n=>n.id==="note-entities"));
''')

    def test_proposals_are_reviewed_atomic_and_stale_safe_including_undo(self):
        self.run_canvas(r'''
const editor = mount({fields:{brief:"Original scope"}}), before = plain(editor.controller.document());
const proposal = suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Suggested scope"}},
 {op:"add_node",node:{id:"component-api",kind:"component",title:"API",text:"Owns requests",x:400,y:0}},
 {op:"add_edge",edge:{id:"edge-api",from:"note-brief",to:"component-api",label:"explores"}}]);
assert.equal(editor.controller.proposal(proposal),true); assert.deepEqual(plain(editor.controller.document()),before);
assert.equal(editor.fields[0].value,"Original scope"); assert.equal(editor.suggestions.hidden,false);
editor.click(editor.root.querySelector('[data-canvas-action="apply"]'));
assert.equal(editor.fields[0].value,"Suggested scope"); assert.equal(editor.controller.document().boards.brief.edges.length,1);
assert.equal(editor.controller.document().revision,before.revision+1);
editor.click(editor.controls.undo); assert.equal(editor.fields[0].value,"Original scope"); assert.equal(editor.controller.document().boards.brief.edges.length,0);
assert.equal(editor.controller.proposal(proposal),false);
const stale = suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Outdated"}}]);
assert(editor.controller.proposal(stale)); editor.input("note-brief","text","A human edit after the request");
assert.equal(editor.root.querySelector('[data-canvas-action="apply"]').disabled,true);
editor.click(editor.root.querySelector('[data-canvas-action="apply"]')); assert.equal(editor.fields[0].value,"A human edit after the request");
const unchanged = plain(editor.controller.document());
const invalid = suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Must not partially apply"}}, {op:"add_edge",edge:{from:"missing",to:"note-brief",label:"bad"}}]);
assert.equal(editor.controller.proposal(invalid),false); assert.deepEqual(plain(editor.controller.document()),unchanged);
assert.equal(editor.controller.proposal(suggestion(editor,"brief",[{op:"remove_node",id:"note-brief"}])),false);
const valid = suggestion(editor,"brief",[{op:"add_node",node:{kind:"note",title:"Question",text:"Open question"}}]);
assert(editor.controller.proposal(valid)); editor.click(editor.root.querySelector('[data-canvas-action="dismiss"]'));
assert.deepEqual(plain(editor.controller.document()),unchanged); assert.equal(editor.suggestions.hidden,true);
''')

    def test_keyboard_delete_uses_focused_card_and_rejected_edits_restore_fields(self):
        self.run_canvas(r'''
const editor = mount(); editor.controller.select("data"); editor.click(editor.tools.entity); editor.click(editor.tools.entity);
const entities=editor.controller.document().boards.data.nodes.filter(n=>n.kind==="entity");
editor.root.dispatch("keydown",{target:editor.root.querySelector(`[data-canvas-node="${entities[0].id}"]`),key:"Delete"});
assert(!editor.controller.document().boards.data.nodes.some(n=>n.id===entities[0].id));
assert(editor.controller.document().boards.data.nodes.some(n=>n.id===entities[1].id));
const doc=api.empty(project);
for(const section of ["data","architecture"]) for(let i=0;i<28;i++) doc.boards[section].nodes.push({id:`large-${section}-${i}`,kind:"note",title:"Evidence",text:"x".repeat(12000),x:0,y:0});
doc.boards.decisions.nodes.push({id:"extra-cap",kind:"note",title:"Evidence",text:"x".repeat(10000),x:0,y:0});
assert(api.validate(doc,project));
const large=mount({document:doc});
const before=plain(large.controller.document());
large.input("note-brief","text","x".repeat(12000));
const value=large.fields.find(f=>f.dataset.designField==="brief").value;
assert.equal(value,large.controller.document().boards.brief.nodes[0].text);
assert(large.status.textContent.includes("limit")); assert.deepEqual(plain(large.controller.document()),before);
''')

    def test_partial_context_cannot_replace_or_remove_long_notes(self):
        self.run_canvas(r'''
const original = "Keep all evidence " + "x".repeat(2500);
const editor = mount({fields:{brief:original}});
const before = plain(editor.controller.document());
assert.equal(editor.controller.proposal(suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Partial rewrite"}}])),false);
assert.deepEqual(plain(editor.controller.document()),before);
assert(editor.controller.proposal(suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{title:"Revised title"}}])));
editor.click(editor.root.querySelector('[data-canvas-action="apply"]'));
assert.equal(editor.fields[0].value,original);
const doc = editor.controller.document(); doc.boards.brief.nodes.push({id:"long-note",kind:"note",title:"Evidence",text:original,x:400,y:0});
const second = mount({document:doc,fields:{brief:original}});
assert.equal(second.controller.proposal(suggestion(second,"brief",[{op:"remove_node",id:"long-note"}])),false);
assert(second.controller.proposal(suggestion(second,"brief",[{op:"add_node",node:{kind:"note",title:"Suggestion",text:"Clarify the original evidence"}}])));
''')

    def test_camera_does_not_stale_feedback_and_drawing_is_bounded_and_undoable(self):
        self.run_canvas(r'''
const editor = mount(); const proposal = suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"A useful brief"}}]);
editor.click(editor.controls["zoom-out"]); editor.click(editor.controls.fit);
assert.equal(editor.controller.document().revision,0); assert(editor.controller.proposal(proposal));
editor.click(editor.root.querySelector('[data-canvas-action="dismiss"]')); editor.click(editor.tools.draw);
editor.stage.dispatch("pointerdown",{target:editor.stage,button:0,clientX:10,clientY:10,pointerId:1});
for(let i=0;i<1000;i++) editor.stage.dispatch("pointermove",{target:editor.stage,clientX:i*4,clientY:i%200});
editor.stage.dispatch("pointerup"); const stroke = editor.controller.document().boards.brief.strokes[0];
assert(stroke.points.length<=600); assert(api.validate(editor.controller.document(),project));
const after = editor.controller.document().revision; editor.click(editor.controls.undo);
assert.equal(editor.controller.document().boards.brief.strokes.length,0); assert.equal(editor.controller.document().revision,after+1);
editor.click(editor.controls.redo); assert.equal(editor.controller.document().boards.brief.strokes.length,1);
editor.click(editor.tools.select);
const sketch=editor.root.querySelector(`[data-canvas-stroke="${stroke.id}"]`);
editor.stage.dispatch("pointerdown",{target:sketch,button:0,clientX:100,clientY:100,pointerId:1});
editor.click(sketch); assert.equal(editor.selection.hidden,false);
editor.click(editor.selection.querySelector('[data-canvas-action="delete"]'));
assert.equal(editor.controller.document().boards.brief.strokes.length,0);
const previous = plain(editor.controller.document()); editor.controller.destroy(); editor.click(editor.tools.entity);
assert.deepEqual(plain(editor.controller.document()),previous);
''')

    def test_hostile_proposals_use_plain_text_and_reject_unknown_shapes(self):
        self.run_canvas(r'''
const editor=mount();
for(const changes of [[{op:"update_node",id:"note-brief",patch:{html:"<script>bad</script>"}}],
 [{op:"add_node",node:{kind:"entity",title:"x",text:"中".repeat(2000)}}],
 [{op:"add_node",node:{kind:"entity",title:"x",text:"a",field:"brief"}}],
 [{op:"update_node",id:"note-brief",patch:{text:"x"}},{op:"remove_node",id:"note-brief"}],
 [{op:"add_node",node:{id:"x\" onclick=\"bad",kind:"note",title:"x",text:"x"}}]])
 assert.equal(editor.controller.proposal(suggestion(editor,"brief",changes)),false);
assert.equal(editor.controller.proposal(suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"x"}}],{project:"other"})),false);
const alien=mount(); assert.equal(alien.controller.proposal(suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Wrong document"}}])),false);
const literal='<img src=x onerror=alert(1)>';
assert(editor.controller.proposal(suggestion(editor,"brief",[{op:"add_node",node:{kind:"entity",title:literal,text:literal}}])));
const ghost=editor.root.querySelector(".design-proposed-title"); assert.equal(ghost.textContent,literal);
editor.click(editor.root.querySelector('[data-canvas-action="apply"]'));
assert.equal(editor.controller.document().boards.brief.nodes.at(-1).title,literal);
assert.equal(editor.root.querySelectorAll("img").length,0);
''')

    def test_apply_rechecks_external_draft_and_preview_shows_before_after(self):
        self.run_canvas(r'''
let allowed=true; const editor=mount({fields:{brief:"Existing user scope"},canApply:()=>allowed});
const proposal=suggestion(editor,"brief",[{op:"update_node",id:"note-brief",patch:{text:"A proposed refinement"}}]);
assert(editor.controller.proposal(proposal));
assert.equal(editor.root.querySelector(".design-suggestion-before").textContent,"Before: Existing user scope");
assert.equal(editor.root.querySelector(".design-suggestion-after").textContent,"After: A proposed refinement");
const before=plain(editor.controller.document()); allowed=false;
editor.click(editor.root.querySelector('[data-canvas-action="apply"]'));
assert.deepEqual(plain(editor.controller.document()),before); assert.equal(editor.fields[0].value,"Existing user scope");
assert(editor.status.textContent.includes("another tab"));
allowed=true; editor.click(editor.root.querySelector('[data-canvas-action="apply"]'));
assert.equal(editor.fields[0].value,"A proposed refinement");
''')

    def test_examples_are_illustrative_and_never_overwrite_user_diagrams(self):
        self.run_canvas(r'''
const editor=mount({fields:{brief:"Actual user scope"}});
editor.controller.select("data"); editor.click(editor.tools.entity); const actual=plain(editor.controller.document().boards.data);
assert(editor.controller.example()); assert.deepEqual(plain(editor.controller.document().boards.data),actual);
assert.equal(editor.controller.document().boards.architecture.nodes.filter(node=>!node.field).length,3);
assert.equal(editor.fields[0].value,"Actual user scope"); const before=plain(editor.controller.document());
assert.equal(editor.controller.example(),false); assert.deepEqual(plain(editor.controller.document()),before);
assert.equal(editor.controller.hasContent("data"),true); assert.equal(editor.controller.hasContent("decisions"),false);
''')


if __name__ == "__main__":
    unittest.main()
