"""Exercise the shipped chat hook's reconnect lifecycle without browser dependencies."""
import pathlib
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("node"), "Node is required for the browser-hook regression")
class ChatWorkspaceHookTests(unittest.TestCase):
    def test_rejoin_restores_latest_scoped_tab_without_touching_draft(self):
        script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const sent = [], listeners = new Map(), saved = new Map(), elements = new Map();
const sandbox = {
  window: {}, AbortController, requestAnimationFrame: () => {},
  sessionStorage: {getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value)}
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const draft = {value: "Retain this draft", style: {}, scrollHeight: 50};
elements.set("#chat-message-input", draft);
const hook = {
  ...sandbox.window.SymphonyHooks.ChatWorkspace,
  el: {
    dataset: {project: "github:example/repo", chatId: "one", eventTarget: "1", running: "false", sessionTab: "chat", workspaceView: "conversation"},
    addEventListener: (name, handler) => listeners.set(name, handler),
    querySelector: selector => elements.get(selector) || null,
    querySelectorAll: selector => selector === "#chat-thread-list [data-thread-id]" ? rows : []
  },
  pushEventTo: (target, event, payload) => sent.push({target, event, payload}),
  handleEvent: () => {}
};
const key = id => "symphony.chat.tab.v1:github:example/repo:" + id;
const viewKey = id => "symphony.chat.view.v1:github:example/repo:" + id;
const click = (selector, button) => listeners.get("click")({target: {closest: value => value === selector ? button : null}});
const lastTab = () => sent.filter(item => item.event === "restore-session-tab").at(-1)?.payload.tab;
const lastView = () => sent.filter(item => item.event === "restore-workspace-view").at(-1)?.payload.view;
saved.set(key("one"), "sources");
hook.mounted();
assert.equal(lastTab(), "sources");
sent.length = 0;
hook.updated();
assert.equal(sent.length, 0);
hook.reconnected();
assert.equal(lastTab(), "sources");
assert.equal(draft.value, "Retain this draft");
// Latest click wins on rejoin, and Back keeps the selected chat and draft.
click('[role="tab"][phx-click="session-tab"]', {getAttribute: () => "outputs"});
click('[phx-click="back-to-chats"]', {});
hook.reconnected();
assert.equal(lastTab(), "outputs");
assert.equal(lastView(), "list");
assert.equal(draft.value, "Retain this draft");
// Selecting a row overrides its saved list presentation before opening detail.
saved.set(key("two"), "context");
saved.set(viewKey("two"), "list");
click('button[phx-click="open-chat"]', {getAttribute: () => "two"});
hook.el.dataset.chatId = "two";
hook.updated();
assert.equal(lastTab(), "chat");
assert.equal(lastView(), "conversation");
// Legacy Threads is migrated to list navigation, not restored as a detail tab.
saved.set(key("three"), "threads");
hook.el.dataset.chatId = "three";
hook.updated();
assert.equal(lastTab(), "chat");
assert.equal(lastView(), "list");
assert.equal(saved.get(key("three")), "chat");
delete hook.el.dataset.chatId;
saved.set(viewKey("project"), "list");
hook.updated();
assert.equal(lastView(), "list");
const unselectedDraft = draft.value;
hook.reconnected();
assert.equal(lastView(), "list");
assert.equal(draft.value, unselectedDraft);
// Native drag payloads only originate from this project's list handles.
hook.el.dataset.workspaceView = "list";
hook.updated();
const parent = {querySelectorAll: () => rows};
const row = (id, pinned = "false") => ({dataset: {threadId: id, pinned}, parentElement: parent, getBoundingClientRect: () => ({top: 0, height: 40})});
const rows = [row("a"), row("b"), row("c"), row("pinned", "true")];
let dragStopped = false;
const drag = () => listeners.get("dragstart")({stopPropagation: () => {dragStopped = true;}, target: {closest: () => ({disabled: false, closest: () => rows[0]})}, dataTransfer: {setData: () => {}}, preventDefault: () => assert.fail("valid handle should start drag")});
const drop = (target, clientY) => listeners.get("drop")({target: {closest: () => target}, clientY, preventDefault() {}, stopPropagation() {}});
drag();
assert.ok(dragStopped, "embedded chat drag must not reach the board drag handler");
drop(rows[1], 30);
assert.equal(sent.at(-1).event, "move-thread");
assert.equal(sent.at(-1).payload.id, "a");
assert.equal(sent.at(-1).payload.before_id, "c");
assert.equal(sent.at(-1).payload.pinned, false);
assert.equal(sent.at(-1).payload.project_id, "github:example/repo");
assert.equal(hook.draggedThread, null);
let prevented = false, stopped = false;
listeners.get("click")({target: {closest: selector => selector === 'button[phx-click="open-chat"]' ? {getAttribute: () => "b"} : null}, preventDefault() {prevented = true;}, stopPropagation() {stopped = true;}});
assert.ok(prevented && stopped, "post-drag click cannot open a thread");
let count = sent.length;
drag(); drop(rows[3], 0);
assert.equal(sent.length, count, "cross-group drop ignored");
drag(); elements.set("#chat-thread-search input", {value: "filtered"}); drop(rows[1], 0);
assert.equal(sent.length, count, "search-disabled drop ignored");
elements.delete("#chat-thread-search input");
drag(); rows[0].dataset.pinned = "true"; drop(rows[1], 0);
assert.equal(sent.length, count, "live source pin change invalidates drag");
rows[0].dataset.pinned = "false";
drag(); hook.el.dataset.workspaceView = "conversation"; hook.updated();
assert.equal(hook.draggedThread, null, "view switch clears pending drag");
// Cleared auth/project state sends no restoration and cannot retain a drag.
delete hook.el.dataset.project;
delete hook.el.dataset.chatId;
count = sent.length;
hook.updated();
hook.reconnected();
assert.equal(sent.length, count);
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
