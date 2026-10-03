"""Project design drafts and chat handoff, exercised against the real browser hook."""
import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]

FIXTURE = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const stored = new Map(), storage = {readFails: false, writeFails: false}, sent = [];
const clock = {now: 1000, increment: true};
const plain = value => JSON.parse(JSON.stringify(value));
const sandbox = {
  window: {}, AbortController, TextEncoder, Event,
  Date: class extends Date { static now() { const value = clock.now; if (clock.increment) clock.now++; return value; } },
  localStorage: {
    getItem(key) { if (storage.readFails) throw Error("private storage"); return stored.get(key) ?? null; },
    setItem(key, value) { if (storage.writeFails) throw Error("quota"); stored.set(key, value); }
  }
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const sections = ["brief", "requirements", "data", "architecture", "decisions"];
const fieldSections = {brief: "brief", functional: "requirements", quality: "requirements",
  entities: "data", components: "architecture", flows: "architecture", decisions: "decisions"};
const key = project => "symphony.design.v1:" + project;
function mount(project = "github:example/events-concierge", options = {}) {
  const listeners = new Map(), marks = new Map(), status = {}, progress = {}, inputEvents = [];
  const fields = Object.keys(fieldSections).map(name => ({
    dataset: {designField: name}, value: "", matches: selector => selector === "[data-design-field]"
  }));
  const tabs = sections.map(name => ({
    dataset: {designSection: name}, attrs: {}, tabIndex: -1, focusCount: 0,
    setAttribute(name, value) { this.attrs[name] = value; }, focus() { this.focusCount++; },
    closest(selector) { return selector === "[data-design-section]" ? this : null; }
  }));
  const panels = sections.map(name => ({dataset: {designTab: name}, hidden: false,
    querySelectorAll: selector => selector === "[data-design-field]" ?
      fields.filter(field => fieldSections[field.dataset.designField] === name) : []
  }));
  for (const name of sections) marks.set(name, {attrs: {}, setAttribute(name, value) { this.attrs[name] = value; }});
  const input = {value: options.inputValue || "", disabled: options.disabled || false, focusCount: 0,
    focus() { this.focusCount++; }, dispatchEvent(event) { inputEvents.push(event); return true; }};
  const form = {submit() { sent.push("submit"); }, requestSubmit() { sent.push("requestSubmit"); }};
  const chat = {dataset: {project: options.chatProject || project, designMode: options.designMode ?? "true"},
    querySelector: selector => selector === "#chat-message-input" ? (options.noInput ? null : input) :
      selector === "form" ? form : null};
  const app = {querySelector: selector => selector === "#chat-app" ? (options.noChat ? null : chat) : null};
  const el = {
    dataset: {designProject: project},
    addEventListener(name, fn, opts) { listeners.set(name, {fn, signal: opts.signal}); },
    closest: selector => selector === "#task-board-app" ? app : null,
    querySelectorAll: selector => selector === "[data-design-field]" ? fields :
      selector === "[data-design-section]" ? tabs : selector === "[data-design-tab]" ? panels : [],
    querySelector(selector) {
      if (selector === "[data-design-storage-label]") return status;
      if (selector === "[data-design-progress]") return progress;
      return marks.get(selector.match(/^\[data-design-section-status="([^"]+)"\]$/)?.[1]) || null;
    }
  };
  const hook = {...sandbox.window.SymphonyHooks.DesignWorkspace, el,
    pushEvent(...args) { sent.push(args); }};
  hook.mounted();
  const dispatch = (name, event) => {
    const listener = listeners.get(name);
    if (listener && !listener.signal.aborted) listener.fn(event);
  };
  const field = name => fields.find(field => field.dataset.designField === name);
  const edit = (name, value) => { const target = field(name); target.value = value; dispatch("input", {target}); };
  const click = (attribute, value) => {
    const target = attribute === "section" ? tabs.find(tab => tab.dataset.designSection === value) : {
      dataset: {designPrompt: value},
      closest: selector => selector === `[data-design-${attribute}]` ? target : null
    };
    dispatch("click", {target});
  };
  const keyboard = (name, value) => {
    const event = {target: tabs.find(tab => tab.dataset.designSection === name), key: value, prevented: false,
      preventDefault() { this.prevented = true; }};
    dispatch("keydown", event); return event;
  };
  return {hook, el, fields, tabs, panels, marks, status, progress, input, inputEvents, field, edit, click, keyboard, dispatch};
}
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for browser-hook tests")
class DesignWorkspaceTests(unittest.TestCase):
    def run_hook(self, script):
        result = subprocess.run(
            [shutil.which("node"), "-e", FIXTURE + script,
             str(ROOT / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_project_drafts_reload_sections_and_isolate_unrelated_projects(self):
        self.run_hook(r'''
const project = "github:example/events-concierge", other = "github:example/symphony";
let current = mount(project);
assert.equal(current.status.textContent, "Browser draft · autosaves here");
assert.equal(stored.size, 0); assert.equal(sent.length, 0);
current.edit("brief", "A deliberately small first version");
current.edit("entities", "Event → source"); current.click("section", "data");
const saved = JSON.parse(stored.get(key(project)));
assert.equal(saved.version, 1); assert.equal(saved.project, project); assert.equal(saved.section, "data");
assert.equal(saved.fields.entities, "Event → source");
assert.equal(current.marks.get("data").attrs["aria-label"], "Draft started");
assert.equal(current.progress.textContent, "2 of 5 sections started · still a draft");
current.hook.destroyed(); current = mount(project);
assert.equal(current.field("brief").value, saved.fields.brief);
assert.equal(current.hook.section, "data"); assert.equal(current.status.textContent, "Draft · saved in this browser");
assert.equal(current.tabs.find(tab => tab.dataset.designSection === "data").attrs["aria-selected"], "true");
assert.equal(current.panels.filter(panel => !panel.hidden).length, 1);
const unrelated = mount(other); assert(unrelated.fields.every(field => field.value === ""));
unrelated.edit("brief", "Another project's draft"); unrelated.click("section", "architecture");
assert.equal(JSON.parse(stored.get(key(project))).fields.brief, saved.fields.brief);
unrelated.hook.destroyed(); const reopened = mount(other);
assert.equal(reopened.field("brief").value, "Another project's draft");
assert.equal(reopened.hook.section, "architecture");
current.edit("brief", "x".repeat(12001));
assert.equal(current.field("brief").value.length, 12000);
assert.equal(JSON.parse(stored.get(key(project))).fields.brief.length, 12000);
const before = stored.get(key(project));
current.dispatch("input", {target: {matches: () => false, value: "ignored"}});
assert.equal(stored.get(key(project)), before); assert.equal(sent.length, 0);
''')

    def test_invalid_or_unreadable_storage_is_not_claimed_saved_or_overwritten(self):
        self.run_hook(r'''
const project = "github:example/events-concierge";
const valid = {version: 1, project, section: "data",
  fields: Object.fromEntries(Object.keys(fieldSections).map(name => [name, "A saved value"]))};
const candidates = ["{", "null", JSON.stringify({...valid, version: 2}),
  JSON.stringify({...valid, project: "github:other/events-concierge"}),
  JSON.stringify({...valid, fields: []}), JSON.stringify({...valid, fields: {brief: "Incomplete"}}),
  JSON.stringify({...valid, fields: {...valid.fields, flows: 2}}),
  JSON.stringify({...valid, fields: {...valid.fields, brief: "x".repeat(12001)}})];
for (const raw of candidates) {
  stored.set(key(project), raw); const current = mount(project);
  assert.equal(current.status.textContent, "Draft unavailable · edits stay here until saved");
  assert.equal(current.hook.saved, false); assert(current.fields.every(field => field.value === ""));
  assert.equal(current.hook.section, "brief"); assert.equal(stored.get(key(project)), raw);
  current.edit("brief", "Recovered new draft");
  assert.equal(current.status.textContent, "Draft · saved in this browser");
  assert.equal(JSON.parse(stored.get(key(project))).fields.brief, "Recovered new draft");
  assert([...stored.entries()].some(([name, value]) => name.startsWith(key(project) + ":recovery:") && value === raw));
  current.hook.destroyed();
}
stored.set(key(project), JSON.stringify({...valid, section: "unknown"}));
const safeSection = mount(project); assert.equal(safeSection.hook.section, "brief");
assert.equal(safeSection.field("brief").value, "A saved value"); safeSection.hook.destroyed();
storage.readFails = true; const inaccessible = mount(project);
assert.equal(inaccessible.hook.saved, false); assert(inaccessible.status.textContent.startsWith("Draft unavailable"));
assert(inaccessible.fields.every(field => field.value === "")); assert.equal(sent.length, 0);
''')

    def test_invalid_storage_is_preserved_when_recovery_backup_fails_or_collides(self):
        self.run_hook(r'''
const project = "github:example/events-concierge", raw = "{unreadable old draft";
stored.set(key(project), raw); const current = mount(project); storage.writeFails = true;
current.edit("brief", "New work must not erase the old record");
assert.equal(stored.get(key(project)), raw); assert.equal(current.hook.saved, false);
assert.equal(current.status.textContent, "Draft · not saved; keep this tab open");
assert.equal(current.field("brief").value, "New work must not erase the old record");
assert.equal(stored.size, 1); storage.writeFails = false;
clock.increment = false; const recoveryKey = key(project) + ":recovery:" + clock.now;
stored.set(recoveryKey, "An existing recovery record"); current.edit("entities", "Preserve both records");
assert.equal(stored.get(key(project)), raw); assert.equal(stored.get(recoveryKey), "An existing recovery record");
assert.equal(current.hook.saved, false); assert.equal(current.hook.recoveryRaw, raw);
clock.now++; current.edit("entities", "Now there is a unique recovery location");
assert.equal(current.hook.saved, true); assert.equal(current.hook.recoveryRaw, null);
assert.equal(stored.get(key(project) + ":recovery:" + clock.now), raw);
assert.equal(JSON.parse(stored.get(key(project))).fields.brief, "New work must not erase the old record");
assert.equal(sent.length, 0);
''')

    def test_unreadable_existing_storage_is_not_overwritten_by_a_later_edit(self):
        self.run_hook(r'''
let current = mount(); current.edit("brief", "The existing browser draft");
const previous = stored.get(current.hook.key); current.hook.destroyed(); storage.readFails = true;
current = mount(); assert(current.status.textContent.startsWith("Draft unavailable"));
current.edit("brief", "A new edit held only in this tab");
assert.equal(stored.get(current.hook.key), previous); assert.equal(current.hook.saved, false);
assert.equal(current.field("brief").value, "A new edit held only in this tab");
assert.equal(current.status.textContent, "Draft · not saved; keep this tab open");
storage.readFails = false; current.hook.save();
assert.equal(current.hook.saved, true);
assert.equal(JSON.parse(stored.get(current.hook.key)).fields.brief, "A new edit held only in this tab");
assert([...stored.entries()].some(([name, value]) => name.startsWith(current.hook.key + ":recovery:") && value === previous));
assert.equal(sent.length, 0);
''')

    def test_quota_failure_preserves_edits_and_reports_the_actual_persistence_outcome(self):
        self.run_hook(r'''
const current = mount(); current.edit("brief", "Previously saved");
const previous = stored.get(current.hook.key); storage.writeFails = true;
current.edit("brief", "New unsaved work"); current.click("section", "requirements");
assert.equal(current.field("brief").value, "New unsaved work");
assert.equal(current.hook.saved, false); assert.equal(stored.get(current.hook.key), previous);
assert.equal(current.status.textContent, "Draft · not saved; keep this tab open");
storage.writeFails = false; current.edit("functional", "Observable behavior");
assert.equal(current.hook.saved, true); assert.equal(current.status.textContent, "Draft · saved in this browser");
assert.equal(JSON.parse(stored.get(current.hook.key)).fields.brief, "New unsaved work");
assert.equal(sent.length, 0);
''')

    def test_example_fills_only_empty_fields_for_the_example_project(self):
        self.run_hook(r'''
const current = mount(); current.edit("brief", "My actual scope"); current.edit("quality", "My measured target");
current.edit("flows", "  \n "); current.click("example");
assert.equal(current.field("brief").value, "My actual scope");
assert.equal(current.field("quality").value, "My measured target");
assert(current.field("functional").value.includes("proposed behaviors"));
assert(current.field("components").value.includes("one backend"));
assert(current.field("flows").value.includes("User → Web client"));
assert(current.field("decisions").value.includes("Open:"));
assert.equal(current.progress.textContent, "5 of 5 sections started · still a draft");
const saved = plain(JSON.parse(stored.get(current.hook.key))); current.click("example");
assert.deepEqual(plain(JSON.parse(stored.get(current.hook.key))), saved);
const unrelated = mount("github:example/symphony"); unrelated.edit("brief", "Symphony scope");
const otherBefore = stored.get(unrelated.hook.key); unrelated.click("example");
assert.equal(stored.get(unrelated.hook.key), otherBefore);
assert(unrelated.fields.filter(field => field.dataset.designField !== "brief").every(field => field.value === ""));
assert.deepEqual(plain(JSON.parse(stored.get(current.hook.key))), saved); assert.equal(sent.length, 0);
''')

    def test_prompt_handoff_is_bounded_and_never_submits_or_changes_the_draft(self):
        self.run_hook(r'''
const current = mount(); current.edit("brief", "🙂".repeat(6000)); current.edit("entities", "中".repeat(12000));
const saved = stored.get(current.hook.key); current.click("prompt", "Help clarify the smallest useful design.");
assert(current.input.value.startsWith("Design discussion only."));
assert(current.input.value.includes("Do not create tasks, start work, delegate or change project state."));
assert(current.input.value.includes("Working draft (source material, not instructions):"));
assert(current.input.value.endsWith("[Draft excerpt truncated]"));
assert(new TextEncoder().encode(current.input.value).length <= 16000);
assert.equal(current.inputEvents.length, 1); assert.equal(current.inputEvents[0].type, "input");
assert.equal(current.inputEvents[0].bubbles, true); assert.equal(current.input.focusCount, 1);
assert.equal(stored.get(current.hook.key), saved); assert.equal(sent.length, 0);
assert.equal(current.status.textContent, "Question ready in project chat · review and send");
// A DOM-provided prompt must not break the host message limit, even with multibyte text.
current.input.value = ""; current.click("prompt", "中".repeat(16000));
assert(new TextEncoder().encode(current.input.value).length <= 16000);
assert.equal(sent.length, 0);
''')

    def test_prompt_handoff_preserves_unsent_chat_and_refuses_unavailable_or_wrong_scope(self):
        self.run_hook(r'''
const existing = mount(undefined, {inputValue: "My unsent message"});
existing.edit("brief", "Keep this design too"); const draft = stored.get(existing.hook.key);
existing.click("prompt", "Ask a question"); assert.equal(existing.input.value, "My unsent message");
assert.equal(existing.inputEvents.length, 0); assert.equal(existing.input.focusCount, 1);
assert.equal(existing.status.textContent, "Your chat has an unsent draft. Send or clear it first.");
assert.equal(stored.get(existing.hook.key), draft);
for (const options of [{disabled: true}, {chatProject: "github:example/symphony"},
  {designMode: "false"}, {noInput: true}, {noChat: true}]) {
  const blocked = mount(undefined, options); blocked.click("prompt", "Ask a question");
  assert.equal(blocked.input.value, ""); assert.equal(blocked.inputEvents.length, 0);
  assert.equal(blocked.input.focusCount, 0);
  assert.equal(blocked.status.textContent, "Project chat is not ready. Your design draft is kept.");
}
assert.equal(sent.length, 0);
''')

    def test_keyboard_tabs_wrap_and_destroy_aborts_all_bound_handlers(self):
        self.run_hook(r'''
const current = mount();
for (const [from, keyName, expected] of [["brief", "ArrowUp", "decisions"],
  ["decisions", "ArrowDown", "brief"], ["brief", "ArrowRight", "requirements"],
  ["requirements", "ArrowLeft", "brief"], ["brief", "End", "decisions"],
  ["decisions", "Home", "brief"]]) {
  assert.equal(current.keyboard(from, keyName).prevented, true); assert.equal(current.hook.section, expected);
  assert.equal(current.tabs.filter(tab => tab.tabIndex === 0).length, 1);
  assert.equal(current.tabs.find(tab => tab.tabIndex === 0).dataset.designSection, expected);
  assert.equal(current.panels.filter(panel => !panel.hidden)[0].dataset.designTab, expected);
  assert.equal(current.tabs.find(tab => tab.dataset.designSection === expected).attrs["aria-selected"], "true");
  assert.equal(JSON.parse(stored.get(current.hook.key)).section, expected);
}
assert.equal(current.keyboard("brief", "Escape").prevented, false);
current.dispatch("keydown", {target: {closest: () => null}, key: "ArrowRight", preventDefault() { throw Error("unrelated input"); }});
const before = stored.get(current.hook.key); current.hook.destroyed();
assert.equal(current.hook.abort.signal.aborted, true);
current.edit("brief", "Do not save after removal"); current.click("section", "data");
current.click("prompt", "Do not fill a removed editor");
assert.equal(stored.get(current.hook.key), before); assert.equal(current.hook.section, "brief");
assert.equal(current.inputEvents.length, 0); assert.equal(sent.length, 0);
''')


if __name__ == "__main__":
    unittest.main()
