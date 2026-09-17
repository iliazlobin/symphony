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
const sent = [], listeners = new Map(), saved = new Map();
const sandbox = {
  window: {}, AbortController, requestAnimationFrame: () => {},
  sessionStorage: {getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value)}
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const draft = {value: "Retain this draft", style: {}, scrollHeight: 50};
const hook = {
  ...sandbox.window.SymphonyHooks.ChatWorkspace,
  el: {
    dataset: {project: "github:example/repo", chatId: "one", eventTarget: "1", running: "false", sessionTab: "chat"},
    addEventListener: (name, handler) => listeners.set(name, handler),
    querySelector: selector => selector === "#chat-message-input" ? draft : null
  },
  pushEventTo: (target, event, payload) => sent.push({target, event, payload}),
  handleEvent: () => {}
};
const key = id => "symphony.chat.tab.v1:github:example/repo:" + id;
saved.set(key("one"), "sources");
hook.mounted();
assert.equal(sent.length, 1);
assert.equal(sent[0].payload.tab, "sources");
sent.length = 0;
// Phoenix retains the hook, patches remounted server defaults, then calls reconnected.
hook.updated();
assert.equal(sent.length, 0);
hook.reconnected();
assert.equal(sent.length, 1);
assert.equal(sent[0].payload.tab, "sources");
assert.equal(draft.value, "Retain this draft");
// A click after restore, including while disconnected, is the latest preference.
const button = {getAttribute: () => "outputs"};
listeners.get("click")({target: {closest: selector => selector.startsWith('[role="tab"]') ? button : null}});
hook.reconnected();
assert.equal(sent.at(-1).payload.tab, "outputs");
assert.equal(draft.value, "Retain this draft");
// Switching scope restores only the new conversation's stored tab.
saved.set(key("two"), "context");
hook.el.dataset.chatId = "two";
hook.updated();
assert.equal(sent.at(-1).payload.chat_id, "two");
assert.equal(sent.at(-1).payload.tab, "context");
// Selecting a row overrides its saved Threads tab before the server opens it.
saved.set(key("three"), "threads");
const row = {getAttribute: () => "three"};
listeners.get("click")({target: {closest: selector => selector.startsWith('button[phx-click="open-chat"]') ? row : null}});
hook.el.dataset.chatId = "three";
hook.updated();
assert.equal(sent.at(-1).payload.chat_id, "three");
assert.equal(sent.at(-1).payload.tab, "chat");
// Threads can be remembered at project scope with no selected conversation.
delete hook.el.dataset.chatId;
saved.set(key("project"), "threads");
hook.updated();
assert.equal(sent.at(-1).payload.chat_id, null);
assert.equal(sent.at(-1).payload.tab, "threads");
const unselectedDraft = draft.value;
hook.reconnected();
assert.equal(sent.at(-1).payload.tab, "threads");
assert.equal(draft.value, unselectedDraft);
// Cleared auth/project state has no conversation identity and sends no restore.
delete hook.el.dataset.project;
delete hook.el.dataset.chatId;
const count = sent.length;
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
