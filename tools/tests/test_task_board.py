"""Exercise shipped board preferences and interactions without a browser dependency."""
import pathlib
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("node"), "Node is required for the board-hook regression")
class TaskBoardHookTests(unittest.TestCase):
    def test_five_lane_migration_filters_selection_and_drag(self):
        script = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const source = fs.readFileSync(process.argv[1], "utf8");
const plain = value => JSON.parse(JSON.stringify(value));
function mount(savedPrefs = {}, urlFilters = {}, projects = [{id:"github:example/repo",label:"Example"}], projectLinks = []) {
  const navigations = [], sent = [], listeners = new Map(), elements = new Map(), timers = new Map();
  const saved = new Map([["symphony.board.v1:fixture", JSON.stringify(savedPrefs)]]);
  let timerId = 0;
  const classes = () => {const values = new Set(); return {add: (...names) => names.forEach(name => values.add(name)), remove: (...names) => names.forEach(name => values.delete(name)), contains: name => values.has(name)};};
  const lanes = new Map(["backlog", "work", "in_progress", "review", "done"].map(stage => {
    const lane = {dataset:{stage}, hidden:false, classList:classes(), count:{textContent:""}, empty:{}, container:{children:[]}};
    lane.querySelector = selector => selector === "[data-lane-cards]" ? lane.container : selector === "[data-lane-count]" ? lane.count : selector === "[data-lane-empty]" ? lane.empty : selector === ".task-card:not([hidden])" ? lane.container.children.find(card => !card.hidden) : null;
    lane.container.insertBefore = (card, before) => {const children=lane.container.children; children.splice(children.indexOf(card),1); children.splice(before ? children.indexOf(before) : children.length,0,card);};
    lane.container.append = card => lane.container.insertBefore(card,null);
    lane.closest = selector => selector === "[data-stage]" ? lane : null;
    return [stage,lane];
  }));
  const allCards = () => [...lanes.values()].flatMap(lane => lane.container.children);
  function add(id, status, labels = [], assignees = [], milestone = null) {
    const lane = lanes.get(status === "running" ? "in_progress" : status === "ready" ? "work" : status);
    const card = {dataset:{taskId:id,status,project:"github:example/repo",title:id,identifier:id,priority:"P2",labels:JSON.stringify(labels),assignees:JSON.stringify(assignees),milestone:JSON.stringify(milestone)},hidden:false,classList:classes(),focus(){},contains(){return false;},getAttribute:()=>"true",getBoundingClientRect:()=>({left:0,right:300,top:0,bottom:100,height:100}),getClientRects:()=>[{}],offsetHeight:100};
    card.closest = selector => selector === "[data-stage]" ? lane : selector === "[hidden]" ? (card.hidden ? card : null) : ["[data-task-id]",".task-card[data-task-id]"].includes(selector) ? card : null;
    Object.defineProperty(card,"nextSibling",{get:()=>lane.container.children[lane.container.children.indexOf(card)+1] || null});
    lane.container.children.push(card); return card;
  }
  const backlog=add("backlog","backlog"), queued=add("queued","ready",["bug, ui"],["alice","bob"],{id:"7",title:"Launch"}), running=add("running","running",["backend"],["bob"]), reviewed=add("reviewed","review"), done=add("done","done");
  queued.dataset.kind="bug"; running.dataset.kind="operations";
  const el = {dataset:{scope:"fixture",taskKinds:JSON.stringify(["feature","bug","testing","operations","general","invalid"]),projects:JSON.stringify(projects),projectLinks:JSON.stringify(projectLinks),urlFilters:JSON.stringify(urlFilters)},style:{},addEventListener:(name,handler)=>listeners.set(name,handler),
    querySelectorAll(selector) {if(["[data-task-id]",".task-card[data-task-id]"].includes(selector))return allCards();if(selector==="[data-stage]")return [...lanes.values()];if(selector===".drop-target,.drop-before,.drop-after")return [...lanes.values(),...allCards()];return [];},
    querySelector(selector) {
      if(selector.startsWith('[data-stage="')) {const lane=lanes.get(selector.match(/="([^"]+)"/)[1]);if(selector.includes("[data-lane-count]"))return lane.count;if(selector.includes(".task-card"))return lane.querySelector(".task-card:not([hidden])");return lane;}
      if(selector==="#board-dialog[open]")return null;
      if(!elements.has(selector))elements.set(selector,{value:"",textContent:"",style:{},setAttribute(){},removeAttribute(){},focus(){},getBoundingClientRect:()=>({left:0,right:1000,top:0,bottom:900})});
      return elements.get(selector);
    }};
  elements.set("[data-mobile-lane]",{value:"",options:[...lanes.keys()].map(value=>({value}))});
  const sandbox = {TextEncoder, AbortController, URL, URLSearchParams, window:{matchMedia:()=>({matches:false,addEventListener(){}}),addEventListener(){},getSelection:()=>null,location:{href:"http://localhost:8778/",search:"",assign:url=>navigations.push(url)},innerWidth:1400,innerHeight:900},document:{addEventListener(){}},localStorage:{getItem:key=>saved.get(key),setItem:(key,value)=>saved.set(key,value)},setTimeout:(fn)=>{timers.set(++timerId,fn);return timerId;},clearTimeout:id=>timers.delete(id)};
  vm.runInNewContext(source,sandbox);
  const hook={...sandbox.window.SymphonyHooks.TaskBoard,el,pushEvent:(event,payload)=>sent.push({event,payload})};
  hook.mounted();
  return {hook,el,navigations,sent,saved,listeners,lanes,queued,running,backlog,done,elements,visible:()=>allCards().filter(card=>!card.hidden).map(card=>card.dataset.taskId),flush:()=>{const jobs=[...timers.values()];timers.clear();jobs.forEach(fn=>fn());}};
}
// A single selector combines local scope and trusted remote boards without mixing their state.
const projects = [{id:"github:example/repo",label:"example/repo"},{id:"github:example/other",label:"Other"}];
const projectLinks = [{id:"github:example/repo",label:"Example project",url:"http://localhost:8778/"},{id:"github:example/remote",label:"Remote project",url:"http://localhost:8779/"}];
const picker = mount({}, {project:"github:example/repo",status:"in_progress",label:'["label:backend"]'}, projects, projectLinks);
assert.equal(picker.elements.get("#filter-project").placeholder,"Example project");
assert.equal(picker.elements.get("#filter-project").title,"Example project");
assert.deepEqual(plain(picker.hook.options("project")),[["github:example/repo","Example project"],["github:example/other","Other"]]);
picker.hook.openFilter("project");
const rendered = picker.elements.get("#options-project").innerHTML;
assert(rendered.includes('href="http://localhost:8779/"'));
assert(!rendered.includes('href="http://localhost:8778/"')); // Selecting the current controller filters locally.
assert(rendered.includes("All projects"));assert(rendered.includes("example/remote"));
picker.hook.toggle("project", "github:example/other");
assert.equal(picker.hook.popup,null);assert.equal(picker.elements.get("#filter-project").placeholder,"Other");
assert.deepEqual(plain(picker.hook.prefs.project),["github:example/other"]);
assert.deepEqual(plain(picker.hook.prefs.status),["in_progress"]);assert.deepEqual(plain(picker.hook.prefs.label),["label:backend"]);
picker.hook.openFilter("project");picker.hook.toggle("project", "");
assert.equal(picker.elements.get("#filter-project").placeholder,"All projects");
assert.deepEqual(plain(picker.hook.prefs.project),[]);assert.deepEqual(picker.visible(),["running"]);
picker.flush();
const beforeRemote = JSON.stringify(picker.hook.prefs), eventsBeforeRemote = picker.sent.length;
picker.hook.toggle("project", "github:example/remote");
assert.deepEqual(picker.navigations,["http://localhost:8779/"]); // Gateway reuses its session; task bindings and credentials are not copied.
assert.equal(JSON.stringify(picker.hook.prefs),beforeRemote);assert.equal(picker.sent.length,eventsBeforeRemote);
assert.deepEqual(plain(picker.hook.filterValues("project", ["github:example/remote"])),[]);
picker.elements.get("#filter-project").value = "example/remote";
assert.deepEqual(plain(picker.hook.drawOptions("project")),[["github:example/remote","Remote project","http://localhost:8779/"]]);
// Design project navigation keeps Design selected without carrying another project's task focus.
picker.el.dataset.boardView="design";
assert.deepEqual(plain(picker.hook.drawOptions("project")),[["github:example/remote","Remote project","http://localhost:8779/?view=design"]]);
picker.hook.toggle("project","github:example/remote");
assert.equal(picker.navigations.at(-1),"http://localhost:8779/?view=design");
const single = mount({}, {}, [projects[0]], projectLinks);
assert.equal(single.elements.get("#filter-project").placeholder,"Example project");
const multi = mount({project:projects.map(project=>project.id)}, {}, projects, projectLinks);
assert.equal(multi.elements.get("#filter-project").placeholder,"2 projects");
// Task kind is a bounded classifier, independent of subject tags.
assert.deepEqual(plain(picker.hook.filterValues("label",["label:kind:testing","label:symphony:ready","label:category:performance"])),["label:category:performance"]);
// Task kind remains independent of stage and metadata filters.
const kinds=mount({}, {kind:"bug"});
assert.deepEqual(kinds.visible(),["queued"]);
assert.deepEqual(plain(kinds.hook.filterValues("kind",["bug","unknown","bug"])),["bug"]);
assert(kinds.hook.options("kind").some(([id,label])=>id==="invalid" && label==="Needs classification"));
kinds.el.dataset.urlFilters=JSON.stringify({kind:"operations",status:"in_progress"}); kinds.hook.apply();
assert.deepEqual(kinds.visible(),["running"]);
kinds.hook.save(); kinds.flush();
assert.deepEqual(plain(kinds.hook.prefs.kind),["operations"]);
kinds.el.dataset.chatOpen="true"; kinds.el.dataset.chatProject="github:example/repo"; kinds.hook.captureContext();
assert.deepEqual(plain(kinds.sent.at(-1).payload.filters.kind),["operations"]);
// Existing browser preferences retain useful order and metadata, but cannot hide Done.
const b = mount({lane:"running",hiddenLanes:["done","running"],order:{ready:["queued","shared"],running:["running","shared"],done:["done"]},label:["label:bug, ui"]});
assert.equal(b.hook.prefs.lane,"work");
assert.deepEqual(plain(b.hook.prefs.order.work),["queued","shared"]);
assert.deepEqual(plain(b.hook.prefs.order.in_progress),["running","shared"]);
assert(!("hiddenLanes" in b.hook.prefs));assert(!("ready" in b.hook.prefs.order));
assert.equal(b.lanes.get("done").hidden,false);
assert.deepEqual(b.visible(),["queued"]);
b.hook.prefs.label=[];b.hook.apply();assert.deepEqual(b.visible(),["backlog","queued","running","reviewed","done"]);
b.hook.save();b.flush();const persisted=JSON.parse(b.saved.get("symphony.board.v1:fixture"));
assert(!("hiddenLanes" in persisted));assert(!("running" in persisted.order));
assert.equal(persisted.lane,"work");
// New Work order wins over any remaining legacy order and migration is idempotent.
const restored=mount({...persisted,order:{...persisted.order,work:["running","queued"],ready:["queued"]}});
assert.deepEqual(plain(restored.hook.prefs.order.work),["running","queued"]);
for(const legacy of ["ready","running"]) {
  const old=mount({lane:legacy,status:[legacy]});assert.equal(old.hook.prefs.lane,legacy==="ready"?"work":"in_progress");assert.deepEqual(old.visible(),[legacy==="ready"?"queued":"running"]);
}
// Share filters distinguish admission from native execution.
for(const [status,expected] of [["ready",["queued"]],["running",["running"]],["work",["queued"]],["in_progress",["running"]]]) {
  b.el.dataset.urlFilters=JSON.stringify({status});b.hook.apply();assert.deepEqual(b.visible(),expected);
  assert.equal(b.hook.prefs.lane,["running","in_progress"].includes(status)?"in_progress":"work");
}
b.el.dataset.urlFilters=JSON.stringify({status:"work",label:'["label:bug, ui"]',assignee:'["assignee:bob"]'});b.hook.apply();assert.deepEqual(b.visible(),["queued"]);
const beforeSave=b.sent.length;b.hook.save();b.flush();assert.equal(b.sent.length,beforeSave); // URL already equals the selection.
// A filter with no matches keeps its selected value and all five lane headings.
b.hook.prefs.label=["label:gone"];b.hook.apply();assert.deepEqual(b.visible(),[]);assert.equal(b.hook.prefs.label[0],"label:gone");assert([...b.lanes.values()].every(lane=>!lane.hidden));
// Card background selects; title links do not invoke background selection.
b.el.dataset.urlFilters="{}";b.hook.apply();b.hook.prefs.status=[];b.hook.prefs.label=[];b.hook.prefs.assignee=[];b.hook.apply();
b.listeners.get("click")({target:b.queued,button:0});assert.equal(b.sent.at(-1).event,"select-task");
const count=b.sent.length, link={closest:selector=>selector===".task-card[data-task-id]"?b.queued:selector.startsWith("a,button")?link:null};
b.listeners.get("click")({target:link,button:0});assert.equal(b.sent.length,count);
// Crossing execution columns requests a native transition; it never changes running state locally.
const begin=card=>b.listeners.get("dragstart")({target:card,dataTransfer:{setData(){}},preventDefault(){assert.fail("card drag was rejected");}});
const drop=target=>b.listeners.get("drop")({target,preventDefault(){}});
b.hook.announce=()=>{};begin(b.running);drop(b.queued);
assert.equal(b.sent.at(-1).event,"move-task");
assert.equal(b.sent.at(-1).payload.stage,"work");
assert.equal(b.running.dataset.status,"running");assert.equal(b.queued.dataset.status,"ready");
begin(b.backlog);drop(b.lanes.get("work"));assert.equal(b.sent.at(-1).event,"move-task");assert.equal(b.sent.at(-1).payload.stage,"work");
// The new context never advertises hidden columns; legacy detailed filters remain meaningful.
b.el.dataset.chatOpen="true";b.el.dataset.chatProject="github:example/repo";b.hook.prefs.status=["ready"];b.hook.apply();b.hook.captureContext();
const snapshot=b.sent.at(-1).payload;assert.deepEqual(plain(snapshot.hidden_columns),[]);assert.deepEqual(plain(snapshot.filters.status),["ready"]);
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_graph_switch_avoids_close_race_and_restores_opener_focus(self):
        script = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const listeners = new Map(), commands = [];
let document;
function button(id) {
  return {id, isConnected:true, disabled:false, dataset:{}, getClientRects:()=>[{}],
    closest:selector=>selector.includes("#workflow-graph-button") && id === "workflow-graph-button" ? graph : null,
    focus(){document.activeElement=this;}};
}
const title=button("task-title"), graph=button("workflow-graph-button"), close=button("close-dialog");
document={activeElement:title,body:{style:{overflow:""}},documentElement:{},
  addEventListener:(event,handler)=>listeners.set(event,handler),querySelectorAll:()=>[],
  getElementById:id=>id === graph.id ? graph : null};
const dialog={dataset:{nonmodal:"true",contentKey:"task:1"},open:false,scrollTop:0,
  addEventListener(){},querySelector:()=>close,contains:target=>target === close,
  show(){this.open=true;},showModal(){this.open=true;close.focus();},close(){this.open=false;}};
const sandbox={window:{},document,AbortController,queueMicrotask:fn=>fn()};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const hook={...sandbox.window.SymphonyHooks.BoardDialog,el:dialog,pushEvent:event=>commands.push(event)};
hook.mounted();
listeners.get("click")({target:graph});
assert.deepEqual(commands,[]);
document.activeElement=graph;hook.beforeUpdate();
dialog.dataset.nonmodal="false";dialog.dataset.contentKey="graph";hook.updated();
assert.equal(hook.previous,graph);
assert.equal(hook.nonmodal,false);
assert.equal(document.activeElement,close);
hook.destroyed();
assert.equal(document.activeElement,graph);
assert.equal(document.body.style.overflow,"");
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_breadcrumb_menus_fit_chat_dock_and_visual_viewport(self):
        script = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
function fit(shellBounds, menuLeft, viewport) {
  const properties = new Map();
  const menu = {style:{setProperty:(key,value)=>properties.set(key,value)},getBoundingClientRect:()=>({
    left:menuLeft + (parseFloat(properties.get("--chat-menu-offset")) || 0),
    width:Math.min(360, parseFloat(properties.get("--chat-menu-width")) || 360),top:300
  })};
  const details = {open:true,closest:()=>({getBoundingClientRect:()=>shellBounds}),
    querySelector:selector=>selector === ".issue-pr-list" ? menu : null,addEventListener(){}};
  const window = {innerWidth:1360,innerHeight:900,visualViewport:viewport,addEventListener(){}};
  const document = {addEventListener(){}};
  const sandbox = {window,document,AbortController};
  vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
  const hook = {...window.SymphonyHooks.IssuePRMenu,el:details};
  hook.mounted();hook.menuSize.fit();
  const bounds=menu.getBoundingClientRect();
  assert(bounds.left >= Math.max(shellBounds.left,viewport?.offsetLeft || 0)+8);
  assert(bounds.left+bounds.width <= Math.min(shellBounds.right,viewport ? viewport.offsetLeft+viewport.width : window.innerWidth)-8);
  return properties;
}
const dock=fit({left:1000,right:1360,bottom:800},1170,null);
assert.equal(dock.get("--chat-menu-width"),"344px");
assert.equal(dock.get("--chat-menu-offset"),"-162px");
assert.equal(dock.get("--chat-menu-space"),"492px");
const zoomed=fit({left:0,right:390,bottom:800},20,{offsetLeft:50,width:300,offsetTop:40,height:640,addEventListener(){}});
assert.equal(zoomed.get("--chat-menu-width"),"284px");
assert.equal(zoomed.get("--chat-menu-offset"),"38px");
assert.equal(zoomed.get("--chat-menu-space"),"372px");
'''
        root = pathlib.Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [shutil.which("node"), "-e", script, str(root / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
