"""Verify the one-attempt Google continuation behavior in the shipped script."""
import pathlib
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("node"), "Node is required for the login regression")
class BrowserLoginTests(unittest.TestCase):
    def test_continuation_submits_once_and_normalizes_history_before_navigation(self):
        script = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const source = fs.readFileSync(process.argv[1], "utf8");
const actions = []; let armed = true;
const form = {removeAttribute(name) {assert.equal(name, "data-continue"); armed = false; actions.push("disarm");},
  requestSubmit() {actions.push("submit");}};
const context = {document: {querySelector(selector) {assert.equal(selector, 'form[data-continue="true"]'); return armed ? form : null;}},
  window: {history: {replaceState(state, title, url) {assert.equal(url, "/login"); actions.push("history");}}}};
vm.runInNewContext(source, context);
assert.deepEqual(actions, ["history", "disarm", "submit"]);
vm.runInNewContext(source, context);
assert.deepEqual(actions, ["history", "disarm", "submit"]);
'''
        asset = pathlib.Path(__file__).resolve().parents[2] / "elixir/priv/static/browser-login.js"
        subprocess.run(["node", "-e", script, str(asset)], check=True, capture_output=True, text=True)
