"""Exercise work-type filtering in the shipped browser hook without external services."""
import pathlib
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("node"), "Node is required for the browser-hook regression")
class TaskBoardHookTests(unittest.TestCase):
    def test_work_type_filter_persistence_urls_context_and_clear(self):
        script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const saved = new Map(), timers = new Map();
let timerID = 0;
const sandbox = {
  AbortController, URLSearchParams,
  setTimeout: callback => { timers.set(++timerID, callback); return timerID; },
  clearTimeout: id => timers.delete(id),
  localStorage: {getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value)},
  document: {addEventListener() {}, activeElement: null},
  window: {location: {search: ""}, innerHeight: 900, innerWidth: 2000,
    addEventListener() {}, matchMedia: () => ({matches: false, addEventListener() {}})}
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const stageNames = ["backlog", "ready", "running", "review", "done"];
const types = ["application", "infrastructure", "deployment", "operations", "unclassified", "invalid"];
const labels = ["Application", "Infrastructure", "Deployment", "Operations", "Unclassified", "Needs classification"];
const node = () => ({dataset: {}, style: {setProperty() {}}, value: "", hidden: false,
  setAttribute() {}, removeAttribute() {}, contains: () => false, focus() {},
  getBoundingClientRect: () => ({top: 0, bottom: 800, left: 0, right: 1600})});
function mount(urlFilters = {}) {
  const sent = [], listeners = new Map(), elements = new Map();
  const element = key => { if (!elements.has(key)) elements.set(key, node()); return elements.get(key); };
  const stages = Object.fromEntries(stageNames.map(stage => [stage, {...node(), dataset: {stage}, cards: []}]));
  const cards = types.map((type, index) => ({...node(),
    dataset: {workType: type, taskId: `github:example/repo:${index + 1}`, project: "github:example/repo", priority: "P2", title: labels[index], identifier: `GH-${index + 1}`},
    closest(selector) { return selector === "[hidden]" ? (this.hidden || stages.ready.hidden ? this : null) : stages.ready; },
    getClientRects() { return this.hidden ? [] : [{}]; }
  }));
  stages.ready.cards = cards;
  for (const [stage, lane] of Object.entries(stages)) {
    const container = {children: lane.cards, append() {}};
    lane.querySelector = selector => selector === "[data-lane-cards]" ? container :
      selector === ".task-card:not([hidden])" ? lane.cards.find(card => !card.hidden) : element(stage + selector);
  }
  const root = {
    ...node(), dataset: {scope: "test", projects: JSON.stringify([{id: "github:example/repo", label: "Example"}]),
      workTypes: JSON.stringify(types.map((type, index) => [type, labels[index]])), urlFilters: JSON.stringify(urlFilters),
      chatOpen: "true", chatProject: "github:example/repo", boardCheckedAt: "2026-09-22T12:00:00Z"},
    addEventListener: (name, callback) => listeners.set(name, callback),
    querySelectorAll: selector => selector === "[data-task-id]" || selector === ".task-card[data-task-id]" ? cards :
      selector === "[data-stage]" ? Object.values(stages) : [],
    querySelector: selector => {
      if (selector === "#board-dialog[open]") return null;
      const stage = selector.match(/^\[data-stage="([^"]+)"\](.*)$/);
      if (stage) return stage[2] ? stages[stage[1]].querySelector(stage[2].trim()) : stages[stage[1]];
      return element(selector);
    }
  };
  element("[data-mobile-lane]").options = stageNames.map(value => ({value}));
  element("#management-chat-dock").getBoundingClientRect = () => ({left: 1800});
  const hook = {...sandbox.window.SymphonyHooks.TaskBoard, el: root, pushEvent: (event, payload) => sent.push({event, payload})};
  hook.mounted();
  return {hook, cards, sent, root, elements, listeners};
}
const ids = state => state.cards.filter(card => !card.hidden).map(card => card.dataset.workType);
let state = mount();
assert.deepEqual(ids(state), types, "old tasks are visible when no type filter is selected");
state.hook.toggle("work_type", "infrastructure");
assert.deepEqual(ids(state), ["infrastructure"]);
assert.ok(state.elements.get("[data-filter-chips]").innerHTML.includes("Infrastructure"));
timers.get(state.hook.urlTimer)();
assert.equal(state.sent.at(-1).event, "board-filters");
assert.equal(state.sent.at(-1).payload.work_type, "infrastructure");
assert.deepEqual(JSON.parse(saved.get("symphony.board.v1:test")).work_type, ["infrastructure"]);
state.hook.captureContext();
const context = state.sent.at(-1).payload;
assert.equal(state.sent.at(-1).event, "board-view-context");
assert.equal(JSON.stringify(context.filters.work_type), '["infrastructure"]');
assert.equal(JSON.stringify(context.visible_task_ids), '["github:example/repo:2"]');
state.hook.destroyed();
state = mount();
assert.deepEqual(ids(state), ["infrastructure"], "browser preferences survive a new hook instance");
state.hook.destroyed();
state = mount({work_type: "unclassified,invalid,unknown"});
assert.deepEqual(ids(state), ["unclassified", "invalid"], "explicit URL overrides saved values and rejects unknown types");
assert.equal(state.elements.get("#filter-work_type").placeholder, "Work type: 2 selected");
state.hook.captureContext();
assert.equal(JSON.stringify(state.sent.at(-1).payload.filters.work_type), '["unclassified","invalid"]');
const button = {dataset: {}, hasAttribute: name => name === "data-clear-filters"};
state.listeners.get("click")({target: {closest: selector => selector === "button" ? button : null}});
assert.deepEqual(ids(state), types, "clear restores all tasks including invalid and unclassified");
timers.get(state.hook.urlTimer)();
assert.equal(state.sent.at(-1).payload.work_type, undefined);
state.hook.destroyed();
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
