"""Exercise status disclosure events in the shipped hook without a browser dependency."""
import pathlib
import shutil
import subprocess
import unittest


FIXTURE = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const timers = new Map(); let timerId = 0, focusCalls = 0, serverEvents = 0;
class Surface {
  constructor() {this.listeners = new Map();}
  addEventListener(name, handler, options = {}) {
    const list = this.listeners.get(name) || [];
    list.push({handler, options}); this.listeners.set(name, list);
  }
  emit(name, values = {}) {
    const event = {target: this, relatedTarget: null, pointerType: "mouse", ...values,
      preventDefault() {this.defaultPrevented = true;}, stopPropagation() {this.stopped = true;}};
    for (const {handler, options} of this.listeners.get(name) || []) {
      if (!options.signal?.aborted) handler(event);
    }
    return event;
  }
}
class Element extends Surface {
  constructor(kind, parent = null) {
    super(); this.kind = kind; this.parent = parent; this.dataset = {}; this.attrs = {};
    this.style = {}; this.isConnected = true; this.nativeOpen = false;
    this.bounds = {left: 40, right: 64, top: 50, bottom: 74, width: 24, height: 24};
  }
  setAttribute(name, value) {this.attrs[name] = value;}
  contains(other) {while (other) {if (other === this) return true; other = other.parent;} return false;}
  closest(selector) {
    if (selector.includes("[data-indicator-trigger]") && this.kind === "trigger") return this;
    if (selector.includes("[data-indicator-detail]") && this.kind === "detail") return this;
    return this.parent?.closest(selector) || null;
  }
  matches(selector) {assert.equal(selector, ":popover-open"); return this.nativeOpen;}
  showPopover() {assert(!this.nativeOpen); this.emit("beforetoggle", {newState: "open"}); this.nativeOpen = true;}
  hidePopover() {assert(this.nativeOpen); this.emit("beforetoggle", {newState: "closed"}); this.nativeOpen = false;}
  getBoundingClientRect() {
    if (this.kind !== "detail") return this.bounds;
    return {...this.bounds, width: Math.min(this.bounds.width, parseFloat(this.style.maxWidth) || Infinity),
      height: Math.min(this.bounds.height, parseFloat(this.style.maxHeight) || Infinity)};
  }
  focus() {focusCalls++; document.activeElement = this;}
  getClientRects() {return [{}];}
}
const document = new Surface();
document.body = {style: {overflow: ""}}; document.documentElement = {}; document.activeElement = document.body;
document.querySelectorAll = () => []; document.getElementById = () => null;
const window = new Surface(); window.innerWidth = 800; window.innerHeight = 600;
window.visualViewport = new Surface(); Object.assign(window.visualViewport, {offsetLeft: 0, offsetTop: 0, width: 800, height: 600});
const sandbox = {window, document, AbortController, queueMicrotask: fn => fn(),
  setTimeout: callback => {const id = ++timerId; timers.set(id, callback); return id;}, clearTimeout: id => timers.delete(id)};
vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);
const flush = () => {const pending = [...timers.values()]; timers.clear(); pending.forEach(callback => callback());};
function mount() {
  const wrapper = new Element("wrapper"), trigger = new Element("trigger", wrapper), detail = new Element("detail", wrapper);
  detail.bounds = {left: 0, right: 300, top: 0, bottom: 100, width: 300, height: 100};
  wrapper.trigger = trigger; wrapper.detail = detail;
  wrapper.querySelector = selector => selector === "[data-indicator-trigger]" ? wrapper.trigger : selector === "[data-indicator-detail]" ? wrapper.detail : null;
  const hook = {...window.SymphonyHooks.StatusIndicator, el: wrapper, pushEvent() {serverEvents++;}};
  hook.mounted(); return {hook, wrapper, trigger, detail};
}
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for the browser-hook regression")
class StatusIndicatorHookTests(unittest.TestCase):
    def run_script(self, script):
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", FIXTURE + script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_hover_focus_touch_and_escape_keep_disclosure_local_and_dismissible(self):
        self.run_script(r'''
const {hook, wrapper, trigger, detail} = mount();
assert.equal(trigger.attrs["aria-expanded"], "false");
wrapper.emit("pointerover", {target: trigger});
assert(detail.nativeOpen); assert.equal(trigger.attrs["aria-expanded"], "true");
// The tooltip is hoverable; crossing its gap has a grace period and cancels closure on entry.
wrapper.emit("pointerout", {target: trigger}); assert(timers.size > 0); assert(detail.nativeOpen);
wrapper.emit("pointerover", {target: detail}); flush(); assert(detail.nativeOpen);
wrapper.emit("pointerout", {target: detail}); flush(); assert(!detail.nativeOpen);
// Focus opens without moving focus, and focusout waits until the next active element settles.
document.activeElement = trigger; wrapper.emit("focusin", {target: trigger}); assert(detail.nativeOpen);
wrapper.emit("focusout", {target: trigger}); document.activeElement = document.body; flush(); assert(!detail.nativeOpen);
wrapper.emit("pointerover", {target: trigger, pointerType: "touch"}); assert(!detail.nativeOpen);
const tap = wrapper.emit("click", {target: trigger});
assert(tap.stopped && tap.defaultPrevented); assert(hook.pinned && detail.nativeOpen);
wrapper.emit("pointerout", {target: trigger}); flush(); assert(detail.nativeOpen);
wrapper.emit("click", {target: trigger}); assert(!detail.nativeOpen);
// First Escape dismisses even with focus retained; a patch or internal pointer transition cannot reopen it.
document.activeElement = trigger; wrapper.emit("focusin", {target: trigger}); assert(detail.nativeOpen);
const escape = document.emit("keydown", {target: trigger, key: "Escape"});
assert(escape.defaultPrevented && escape.stopped); assert(!detail.nativeOpen);
wrapper.emit("pointerover", {target: detail, relatedTarget: trigger}); assert(!detail.nativeOpen);
hook.beforeUpdate(); hook.updated(); assert(!detail.nativeOpen);
wrapper.emit("pointerout", {target: trigger}); wrapper.emit("pointerover", {target: trigger}); assert(detail.nativeOpen);
const detailClick = wrapper.emit("click", {target: detail}); assert(detailClick.stopped); assert(!detailClick.defaultPrevented);
assert.equal(focusCalls, 0); assert.equal(serverEvents, 0); hook.destroyed();
''')

    def test_fixed_popover_fits_visual_viewport_and_tracks_resize_and_scroll(self):
        self.run_script(r'''
const {hook, wrapper, trigger, detail} = mount();
trigger.bounds = {left: 770, right: 794, top: 550, bottom: 574, width: 24, height: 24};
wrapper.emit("pointerover", {target: trigger});
assert.equal(detail.style.inset, "auto"); assert.equal(detail.style.margin, "0");
assert.equal(detail.style.left, "488px"); assert.equal(detail.style.top, "442px");
// A mobile keyboard/zoom changes the visual viewport; dimensions and offsets bound the overlay.
Object.assign(window.visualViewport, {offsetLeft: 100, offsetTop: 200, width: 240, height: 160});
trigger.bounds = {left: 308, right: 332, top: 280, bottom: 304, width: 24, height: 24};
window.visualViewport.emit("resize");
assert.equal(detail.style.maxWidth, "216px"); assert.equal(detail.style.maxHeight, "136px");
assert.equal(detail.style.left, "112px"); assert.equal(detail.style.top, "212px");
trigger.bounds = {left: 112, right: 136, top: 216, bottom: 240, width: 24, height: 24};
document.emit("scroll"); assert.equal(detail.style.left, "112px"); assert.equal(detail.style.top, "248px");
window.emit("resize"); window.visualViewport.emit("scroll"); assert(detail.nativeOpen);
trigger.bounds = {...trigger.bounds, top: 500, bottom: 524}; document.emit("scroll"); assert(!detail.nativeOpen);
assert.equal(trigger.attrs["aria-expanded"], "false"); hook.destroyed();
''')

    def test_native_light_dismissal_patches_and_destruction_retain_one_owner(self):
        self.run_script(r'''
const {hook, wrapper, trigger, detail} = mount();
wrapper.emit("click", {target: trigger}); assert(hook.pinned);
detail.hidePopover(); // Native outside/light dismissal is authoritative for expanded state.
assert.equal(wrapper.dataset.indicatorOpen, "false"); assert(!hook.pinned); assert(hook.dismissed);
hook.beforeUpdate(); hook.updated(); assert(!detail.nativeOpen);
wrapper.emit("click", {target: trigger}); hook.beforeUpdate();
// LiveView may replace children; scoped bindings restore the same disclosure without replacing its text.
const replacement = new Element("detail", wrapper); replacement.bounds = detail.bounds; replacement.textContent = "Fresh retained explanation";
detail.isConnected = false; wrapper.detail = replacement; trigger.attrs["aria-expanded"] = "false";
hook.updated(); assert(replacement.nativeOpen); assert(hook.pinned); assert.equal(replacement.textContent, "Fresh retained explanation");
assert.equal(trigger.attrs["aria-expanded"], "true");
detail.emit("beforetoggle", {newState: "closed"}); assert(hook.open, "removed child listeners must be detached");
hook.pinned = false; hook.hovered = false; wrapper.emit("pointerout"); assert(timers.size > 0);
hook.destroyed(); assert(!replacement.nativeOpen); assert.equal(timers.size, 0);
wrapper.emit("pointerover", {target: trigger}); document.emit("keydown", {key: "Escape"}); window.emit("resize");
assert(!replacement.nativeOpen); assert.equal(serverEvents, 0); assert.equal(focusCalls, 0);
''')

    def test_first_escape_closes_indicator_and_second_closes_task_details(self):
        self.run_script(r'''
for (const indicatorFirst of [false, true]) {
const commands = [], close = new Element("close"), dialog = new Element("dialog");
document.activeElement = close;
dialog.dataset = {nonmodal: "true", contentKey: "task:1"}; dialog.open = false;
dialog.show = () => {dialog.open = true;}; dialog.close = () => {dialog.open = false;};
let indicator;
document.querySelectorAll = selector => selector === '.status-indicator[data-indicator-open="true"]' && indicator?.wrapper.dataset.indicatorOpen === "true" ? [indicator.wrapper] : [];
dialog.querySelector = selector => selector === "#close-dialog" ? close : selector === '[data-dialog-scroll]' ? dialog :
  selector === '.status-indicator[data-indicator-open="true"]' && indicator?.wrapper.dataset.indicatorOpen === "true" ? indicator.wrapper : null;
const detailsHook = {...window.SymphonyHooks.BoardDialog, el: dialog, pushEvent: event => commands.push(event)};
if (indicatorFirst) {indicator = mount(); detailsHook.mounted();}
else {detailsHook.mounted(); indicator = mount();}
indicator.wrapper.parent = dialog;
indicator.wrapper.emit("click", {target: indicator.trigger});
document.emit("click", {target: indicator.trigger}); document.emit("click", {target: indicator.detail});
assert.deepEqual(commands, [], "reading an indication cannot send a close patch");
document.emit("keydown", {target: indicator.trigger, key: "Escape"});
assert(!indicator.detail.nativeOpen); assert.deepEqual(commands, []);
document.emit("keydown", {target: indicator.trigger, key: "Escape"}); assert.deepEqual(commands, ["close-dialog"]);
commands.length = 0;
// A hovered board-card indication outside the nonmodal dialog has the same first-Escape priority.
indicator.wrapper.parent = null; indicator.wrapper.emit("pointerover", {target: indicator.trigger});
document.emit("keydown", {target: indicator.trigger, key: "Escape"});
assert(!indicator.detail.nativeOpen); assert.deepEqual(commands, []);
indicator.hook.destroyed(); detailsHook.destroyed();
}
''')

    def test_missing_enhancement_api_does_not_cancel_native_invoker(self):
        self.run_script(r'''
const {hook, wrapper, trigger, detail} = mount();
detail.showPopover = undefined; detail.hidePopover = undefined;
wrapper.emit("pointerover", {target: trigger}); assert(!detail.nativeOpen);
const click = wrapper.emit("click", {target: trigger});
assert(click.stopped, "the card must not select while its indication is invoked");
assert(!click.defaultPrevented, "native popovertarget activation must remain available");
assert(!hook.pinned); hook.destroyed(); assert.equal(serverEvents, 0);
''')


if __name__ == "__main__":
    unittest.main()
