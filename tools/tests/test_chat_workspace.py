"""Exercise the shipped chat hook's reconnect lifecycle without browser dependencies."""
import pathlib
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("node"), "Node is required for the browser-hook regression")
class ChatWorkspaceHookTests(unittest.TestCase):
    def test_drafts_survive_project_navigation_without_crossing_scopes_or_failed_sends(self):
        script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const saved = new Map();
class BrowserEvent {constructor(type, options = {}) {this.type = type; Object.assign(this, options);}}
const sandbox = {
  window: {}, AbortController, Event: BrowserEvent, CustomEvent: BrowserEvent, requestAnimationFrame: callback => callback(),
  sessionStorage: {getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value), removeItem: key => saved.delete(key)}
};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const key = (project, chat) => "symphony.chat.draft.v1:" + JSON.stringify([project, chat || null]);
const mount = (project, chat, value = "") => {
  const listeners = new Map(), events = new Map();
  const input = {id: "chat-message-input", value, disabled: false, style: {}, scrollHeight: 50,
    dataset: {draft: value, draftRevision: "revision-1"}, focus() {},
    dispatchEvent(event) {listeners.get(event.type)?.({target: input});}};
  const hook = {...sandbox.window.SymphonyHooks.ChatWorkspace,
    el: {dataset: {project, chatId: chat, eventTarget: "1", running: "false", sessionTab: "chat", workspaceView: "conversation", embedded: "true"},
      addEventListener: (name, handler) => listeners.set(name, handler),
      querySelector: selector => selector === "#chat-message-input" ? input : null, querySelectorAll: () => [],
      dispatchEvent: event => listeners.get(event.type)?.({target: {id: "chat-composer"}})},
    pushEventTo() {}, handleEvent: (name, handler) => events.set(name, handler)};
  const type = text => {input.value = text; listeners.get("input")({target: input});};
  const submit = () => listeners.get("submit")({target: {id: "chat-composer"}});
  const accept = (accepted_text, chat_id = hook.el.dataset.chatId, client_id = hook.pendingDraft?.revision) => events.get("chat-message-sent")({chat_id, accepted_text, client_id});
  hook.mounted();
  return {hook, input, type, submit, accept, prompt: payload => events.get("task-chat-prompt")(payload)};
};
// Full HTTP project navigation remounts the hook but retains only this tab's storage.
let alpha = mount("github:example/alpha", "task-1");
alpha.type("Alpha unsent draft");
alpha.hook.destroyed();
const beta = mount("github:example/beta", "task-1");
assert.equal(beta.input.value, "", "identical conversation IDs in another project cannot inherit text");
beta.type("Beta draft");
alpha = mount("github:example/alpha", "task-1");
assert.equal(alpha.input.value, "Alpha unsent draft");
assert.equal(saved.get(key("github:example/beta", "task-1")), "Beta draft");
// Existing server drafts win; task and work conversations retain separate text.
const server = mount("github:example/alpha", "task-1", "Component retained draft");
assert.equal(server.input.value, "Component retained draft");
assert.equal(saved.get(key("github:example/alpha", "task-1")), "Component retained draft");
server.hook.el.dataset.chatId = "work-1"; server.input.dataset.draft = ""; server.input.value = ""; server.hook.updated();
assert.equal(server.input.value, "");
server.type("Work draft");
server.hook.el.dataset.chatId = "task-1"; server.input.value = ""; server.hook.updated();
assert.equal(server.input.value, "Component retained draft");
server.hook.el.dataset.chatId = "work-1"; server.input.value = ""; server.hook.updated();
assert.equal(server.input.value, "Work draft");
// A failed submission or channel rejoin has no successful revision and cannot clear it.
server.submit(); server.hook.disconnected();
server.input.value = ""; server.input.dataset.draftRevision = "remounted-revision";
server.hook.updated(); server.hook.reconnected();
assert.equal(server.input.value, "Work draft");
assert.equal(saved.get(key("github:example/alpha", "work-1")), "Work draft");
// Matching success removes storage; another conversation's delayed acknowledgement does not.
server.submit();
server.accept("Work draft", "task-1");
assert.equal(server.input.value, "Work draft");
assert.equal(saved.get(key("github:example/alpha", "work-1")), "Work draft");
server.accept("Work draft");
assert.equal(server.input.value, "");
assert.equal(saved.has(key("github:example/alpha", "work-1")), false);
server.hook.reconnected();
assert.equal(server.input.value, "", "accepted text cannot return on reconnect");
// A first chat can be acknowledged before its new conversation ID reaches the DOM.
const first = mount("github:example/alpha", undefined);
first.type("First message"); first.submit(); first.accept("First message", "created-chat");
assert.equal(first.input.value, "");
assert.equal(saved.has(key("github:example/alpha", undefined)), false);
// A successful blank server patch also clears when the explicit acknowledgement was missed.
server.type("Submit once"); server.submit();
server.input.dataset.draft = ""; server.input.dataset.draftRevision = "revision-2";
server.hook.updated();
assert.equal(server.input.value, "");
assert.equal(saved.has(key("github:example/alpha", "work-1")), false);
// The next draft survives a delayed success or blank server patch for the previous text.
server.type("Previous text"); server.submit(); server.type("Newer text");
server.input.dataset.draftRevision = "revision-3"; server.hook.updated(); server.accept("Previous text");
assert.equal(server.input.value, "Newer text");
assert.equal(saved.get(key("github:example/alpha", "work-1")), "Newer text");
// The same words typed again are a new draft, even when an older send succeeds late.
server.type("Same text"); server.submit(); server.type("Same text"); server.accept("Same text");
assert.equal(server.input.value, "Same text");
assert.equal(saved.get(key("github:example/alpha", "work-1")), "Same text");
server.submit();
server.accept("Same text", "work-1", "older-revision");
assert.equal(server.input.value, "Same text", "a stale accepted nonce cannot clear a fresh submit");
server.input.dataset.draftRevision = "revision-4"; server.input.value = ""; server.hook.updated();
assert.equal(server.input.value, "", "matching server success clears the submitted draft");
// A focused textarea can retain the old value while Phoenix patches the new scope's attributes.
server.type("Work secret"); server.hook.el.dataset.chatId = "unused-task";
server.input.dataset.draft = ""; server.hook.updated();
assert.equal(server.input.value, "");
assert.equal(saved.has(key("github:example/alpha", "unused-task")), false);
server.hook.el.dataset.chatId = "retained-task"; server.input.value = "Work secret";
server.input.dataset.draft = "Server retained task draft"; server.hook.updated();
assert.equal(server.input.value, "Server retained task draft");
assert.equal(saved.get(key("github:example/alpha", "retained-task")), "Server retained task draft");
server.input.dataset.draft = "";
server.hook.el.dataset.chatId = "work-1"; server.hook.updated();
assert.equal(server.input.value, "Work secret");
server.type("");
assert.equal(saved.has(key("github:example/alpha", "work-1")), false);
// A recovery affordance fills the scoped task composer, preserving the unsent draft and never submitting.
const recovery=mount("github:example/alpha", "recover-chat", "  Keep my draft  ");
recovery.hook.el.dataset.taskId="task:1";
const prompt={task_id:"task:1",project_id:"github:example/alpha",prompt:"Read-only: explain recovery."};
recovery.prompt(prompt);
assert.equal(recovery.input.value,"  Keep my draft  \n\nRead-only: explain recovery.");
assert.equal(recovery.hook.pendingDraft,undefined);
assert.equal(saved.get(key("github:example/alpha","recover-chat")),recovery.input.value);
recovery.prompt(prompt);assert.equal(recovery.input.value.split(prompt.prompt).length,2);
for (const wrong of [{...prompt,task_id:"other"},{...prompt,project_id:"github:example/beta"},{...prompt,prompt:"x".repeat(8001)}]) {recovery.prompt(wrong);assert.equal(recovery.input.value,"  Keep my draft  \n\nRead-only: explain recovery.");}
recovery.hook.el.dataset.designMode="true";recovery.type("Design draft");recovery.prompt(prompt);assert.equal(recovery.input.value,"Design draft");
recovery.hook.el.dataset.designMode="false";recovery.type("x".repeat(15999));recovery.prompt(prompt);assert.equal(recovery.input.value.length,15999);
// Anonymous state and blocked browser storage keep the composer usable.
delete server.hook.el.dataset.project; server.type("Unscoped text");
assert.equal([...saved.values()].includes("Unscoped text"), false);
sandbox.sessionStorage.getItem = () => {throw new Error("blocked");};
sandbox.sessionStorage.setItem = () => {throw new Error("blocked");};
sandbox.sessionStorage.removeItem = () => {throw new Error("blocked");};
const blocked = mount("github:example/alpha", "other"); blocked.type("Keep typing"); blocked.hook.reconnected();
assert.equal(blocked.input.value, "Keep typing");
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_history_prepend_keeps_reading_position_and_appends_still_follow_bottom(self):
        script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const frames = [];
const sandbox = {window: {}, AbortController, requestAnimationFrame: callback => frames.push(callback), sessionStorage: {getItem() {}, setItem() {}}};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
let offset = 100, rows = [], focused = 0;
const scroller = {scrollTop: 300, scrollHeight: 1000, clientHeight: 400, getBoundingClientRect: () => ({top: 100})};
const message = id => ({id, getBoundingClientRect: () => ({top: offset, bottom: offset + 100})});
const messages = {dataset: {historyPage: "0"}, querySelectorAll: () => rows};
rows = [message("retained")];
const input = {value: "Keep draft", dataset: {draft: "Keep draft", draftRevision: "one"}, style: {}, scrollHeight: 50, focus() {focused++;}};
const hook = {...sandbox.window.SymphonyHooks.ChatWorkspace,
  el: {dataset: {project: "alpha", chatId: "chat-a", eventTarget: "1", running: "false", sessionTab: "chat", workspaceView: "conversation", embedded: "true"},
    addEventListener() {}, querySelector: selector => ({"#session-chat-content": scroller, "#chat-messages": messages, "#chat-message-input": input}[selector] || null), querySelectorAll: () => []},
  pushEventTo() {}, handleEvent() {}};
hook.mounted(); frames.length = 0;
hook.atBottom = false;
hook.beforeUpdate();
// Show earlier prepends content above the same visible message.
messages.dataset.historyPage = "1"; offset += 600; scroller.scrollHeight += 600;
rows.unshift(message("older"));
hook.updated();
assert.equal(scroller.scrollTop, 900, "retained message stays at the same viewport offset");
assert.equal(hook.atBottom, false);
frames.splice(0).forEach(callback => callback());
assert.equal(scroller.scrollTop, 900);
assert.equal(input.value, "Keep draft");
assert.equal(focused, 0, "history loading never steals focus");
// Ordinary append expands the server window but has no history-page change.
hook.atBottom = true; scroller.scrollTop = 1200; hook.beforeUpdate();
scroller.scrollHeight += 100; rows.push(message("latest"));
hook.updated();
assert.equal(hook.atBottom, true, "appended streaming messages retain bottom follow");
frames.splice(0).forEach(callback => callback());
assert.equal(scroller.scrollTop, scroller.scrollHeight);
// A different conversation cannot reuse the old chat's saved scroll anchor.
hook.beforeUpdate(); hook.el.dataset.chatId = "chat-b"; messages.dataset.historyPage = "2";
scroller.scrollTop = 0; offset += 500;
hook.updated();
assert.equal(scroller.scrollTop, 0);
assert.equal(hook.atBottom, true);
// Empty or unmounted history does not manufacture a scroll anchor.
hook.el.querySelector = () => null;
hook.beforeUpdate();
assert.equal(hook.historyAnchor, null);
hook.destroyed();
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_rejoin_restores_latest_scoped_tab_without_touching_draft(self):
        script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const sent = [], listeners = new Map(), saved = new Map(), elements = new Map(), serverEvents = new Map();
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
  handleEvent: (name, handler) => serverEvents.set(name, handler)
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
// Embedded task conversations cannot restore the retired list view.
hook.el.dataset.embedded = "true";
hook.el.dataset.chatId = "bound-task";
saved.set(viewKey("bound-task"), "list");
const beforeViews = sent.filter(item => item.event === "restore-workspace-view").length;
hook.updated();
assert.equal(sent.filter(item => item.event === "restore-workspace-view").length, beforeViews);
// Enter queues follow-ups while the current response is running.
hook.el.dataset.running = "true";
let submitted = 0;
const input = {id: "chat-message-input", value: "Next instruction", disabled: false, closest: () => null,
  form: {requestSubmit() {submitted++;}}};
listeners.get("keydown")({target: input, key: "Enter", shiftKey: false, isComposing: false, preventDefault() {}});
assert.equal(submitted, 1);
listeners.get("keydown")({target: input, key: "Enter", shiftKey: true, isComposing: false, preventDefault() {}});
assert.equal(submitted, 1, "Shift+Enter stays a newline");
// An acknowledgement from the old conversation cannot clear the new draft.
serverEvents.get("chat-message-sent")({chat_id: "previous-task"});
assert.equal(draft.value, "Retain this draft");
draft.focus = () => {};
// A delayed acknowledgement cannot erase the next draft in the same chat.
serverEvents.get("chat-message-sent")({chat_id: "bound-task", accepted_text: "Earlier message"});
assert.equal(draft.value, "Retain this draft");
hook.pendingDraft = {key: hook.draftKey(), project: hook.el.dataset.project, chatId: "bound-task", text: "Retain this draft", revision: "accepted-nonce", edited: false};
serverEvents.get("chat-message-sent")({chat_id: "bound-task", accepted_text: "Retain this draft", client_id: "accepted-nonce"});
assert.equal(draft.value, "");
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
