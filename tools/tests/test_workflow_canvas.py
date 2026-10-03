"""Planning view gestures and cross-view board context, exercised against real hooks."""
import ast
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("node"), "Node is required for browser-hook tests")
class WorkflowCanvasTests(unittest.TestCase):
    def run_hook(self, script):
        result = subprocess.run(
            [shutil.which("node"), "-e", script, str(ROOT / "elixir/priv/static/dashboard.js")],
            capture_output=True, text=True, check=False, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def board_fixture(self):
        # Reuse the existing board fixture, then exercise new behavior against the same real hook.
        tree = ast.parse((ROOT / "tools/tests/test_task_board.py").read_text())
        scripts = [node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str) and "function mount(" in node.value]
        self.assertEqual(len(scripts), 1)
        script = scripts[0].split("// A single selector")[0]
        script = script.replace("const navigations = [], sent = [], listeners", "const focusEvents = new Map(); const navigations = [], sent = [], listeners")
        script = script.replace("const sandbox = {TextEncoder", "const sandbox = {requestAnimationFrame: fn=>fn(), TextEncoder")
        script = script.replace("el,pushEvent:", "el,handleEvent:(name,handler)=>focusEvents.set(name,handler),pushEvent:")
        script = script.replace("return {hook,el,navigations", "return {focusEvents,hook,el,navigations")
        return script

    def test_viewport_gestures_keyboard_selection_and_refresh_preserve_camera(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const source=fs.readFileSync(process.argv[1],"utf8"), plain=x=>JSON.parse(JSON.stringify(x));
const listeners=new Map(), events=new Map(); let resize, focusCount=0, viewportEvents=0;
const size={left:20,top:30,width:1200,height:700};
const bounds=()=>({...size,right:size.left+size.width,bottom:size.top+size.height});
const selected={dataset:{planTaskId:"issue:2",nodeX:"348",nodeY:"220",nodeWidth:"260",nodeHeight:"116"},getBoundingClientRect:()=>({left:-500,right:-240,top:220,bottom:336}),querySelector:()=>({focus(){focusCount++;}})};
function scene(mode,width,height){
 const svg={dataset:{contentWidth:String(width),contentHeight:String(height)},attrs:{},setAttribute(k,v){this.attrs[k]=v;},querySelector:()=>selected,querySelectorAll:()=>[selected]};
 const canvas={dataset:{},getBoundingClientRect:bounds,querySelector:()=>svg,setPointerCapture(){},releasePointerCapture(){},removeAttribute(k){if(k==="data-panning")delete this.dataset.panning;},closest:s=>s==="[data-plan-canvas]"?canvas:null};
 return {mode,svg,canvas,panel:{dataset:{planPanel:mode},hidden:false}};
}
const scenes=[scene("dependencies",1284,600)], outputs=[{}];
const el={dataset:{canvasScope:"p",planMode:"dependencies"},addEventListener:(n,f)=>listeners.set(n,f),dispatchEvent(){viewportEvents++;},querySelector:s=>{
 if(s===".plan-gantt-scroll")return null;
 const mode=s.match(/data-plan-panel="([^"]+)"/)?.[1];return scenes.find(scene=>scene.mode===mode)?.canvas||null;
},querySelectorAll:s=>s==="[data-plan-panel]"?scenes.map(s=>s.panel):s==="[data-canvas-zoom]"?outputs:[]};
const sandbox={window:{},AbortController,requestAnimationFrame:fn=>fn(),CustomEvent:class{},ResizeObserver:class{constructor(fn){resize=fn;}observe(){}unobserve(){}disconnect(){this.disconnected=true;}}};
vm.runInNewContext(source,sandbox);const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el,handleEvent:(n,f)=>events.set(n,f)};hook.mounted();
assert(hook.camera().scale>.89 && hook.camera().scale<1);assert(outputs[0].textContent.endsWith("%"));
const initial=plain(hook.camera()),anchor={x:700,y:350};const worldX=initial.x+(anchor.x-size.left)/initial.scale;
let prevented=0;listeners.get("wheel")({target:scenes[0].canvas,deltaY:-100,deltaMode:0,clientX:anchor.x,clientY:anchor.y,preventDefault(){prevented++;}});
assert.equal(prevented,1);assert(hook.camera().scale>initial.scale);assert(Math.abs(hook.camera().x+(anchor.x-size.left)/hook.camera().scale-worldX)<1e-9);
assert.equal(hook.observedCanvas,scenes[0].canvas);
const pointer=(id,x,y)=>({target:scenes[0].canvas,pointerId:id,pointerType:"mouse",button:0,clientX:x,clientY:y,preventDefault(){}});
const beforePan=plain(hook.camera());listeners.get("pointerdown")(pointer(1,300,300));listeners.get("pointermove")(pointer(1,420,360));
assert.equal(hook.camera().x,beforePan.x-120/beforePan.scale);assert.equal(hook.camera().y,beforePan.y-60/beforePan.scale);
listeners.get("pointercancel")(pointer(1,420,360));assert.equal(hook.pointers.size,0);assert.equal(scenes[0].canvas.dataset.panning,undefined);
const beforePinch=hook.camera().scale;listeners.get("pointerdown")(pointer(1,300,300));listeners.get("pointerdown")(pointer(2,500,300));listeners.get("pointermove")(pointer(2,700,300));
assert.equal(hook.camera().scale,beforePinch*2);listeners.get("pointerup")(pointer(1,300,300));listeners.get("lostpointercapture")(pointer(2,700,300));
const saved=plain(hook.camera()), box=scenes[0].svg.attrs.viewBox;hook.beforeUpdate();hook.updated();assert.deepEqual(plain(hook.camera()),saved);assert.equal(scenes[0].svg.attrs.viewBox,box);
const centerX=hook.camera().x+size.width/(2*hook.camera().scale),centerY=hook.camera().y+size.height/(2*hook.camera().scale);size.width=900;size.height=500;resize();
assert(Math.abs(hook.camera().x+size.width/(2*hook.camera().scale)-centerX)<1e-9);assert(Math.abs(hook.camera().y+size.height/(2*hook.camera().scale)-centerY)<1e-9);
const key=k=>listeners.get("keydown")({target:scenes[0].canvas,key:k,preventDefault(){}});const oldX=hook.camera().x;key("ArrowRight");assert(hook.camera().x>oldX);key("f");assert(hook.camera().scale<1);
events.get("focus-plan-task")({id:"issue:2",view:"graph"});assert.equal(focusCount,1);assert.equal(hook.camera().x+size.width/(2*hook.camera().scale),478);
const camera=plain(hook.camera());events.get("focus-plan-task")({id:"issue:2",view:"kanban"});assert.deepEqual(plain(hook.camera()),camera);
el.dataset.selectedId="work:1";hook.updated();assert.equal(hook.mode,"dependencies");assert.equal(scenes[0].panel.hidden,false);
hook.updated();assert.equal(hook.mode,"dependencies"); // Work selection stays in task dependencies.
listeners.get("focusin")({target:{closest:()=>selected}});assert.equal(hook.camera().x+size.width/(2*hook.camera().scale),478);
el.dataset.canvasScope="other";hook.updated();assert.equal(hook.cameras.size,1);assert.notDeepEqual(plain(hook.camera()),camera);
assert(viewportEvents>8);hook.destroyed();assert.equal(hook.abort.signal.aborted,true);assert.equal(hook.pointers.size,0);
''')

    def test_sequence_refresh_preserves_scroll_and_view_switch_focuses_selected_task(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),events=new Map();let scrolled=0,focused=0;
const scroll={scrollLeft:380,scrollTop:264},row={dataset:{planTaskId:"issue:4"},scrollIntoView(){scrolled++;},querySelector:()=>({focus(){focused++;}})};
const el={dataset:{canvasScope:"p",planMode:"timeline"},addEventListener(){},querySelector:s=>s===".plan-gantt-scroll"?scroll:null,querySelectorAll:s=>s==="[data-plan-task-id]"?[row]:[]};
const sandbox={window:{},AbortController,requestAnimationFrame:fn=>fn()};vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el,handleEvent:(n,f)=>events.set(n,f)};hook.mounted();hook.beforeUpdate();scroll.scrollLeft=0;scroll.scrollTop=0;hook.updated();assert.equal(scroll.scrollLeft,380);assert.equal(scroll.scrollTop,264);
events.get("focus-plan-task")({id:"issue:4",view:"gantt"});assert.equal(scrolled,1);assert.equal(focused,1);events.get("focus-plan-task")({id:"issue:4",view:"graph"});assert.equal(focused,1);hook.destroyed();
''')

    def test_calendar_drafts_scale_storage_and_refresh_without_dispatch(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),plain=x=>JSON.parse(JSON.stringify(x));
const stored=new Map(),sent=[],listeners=new Map(),events=new Map(),props=new Map(),label={};let failing=false;
const scroll={clientWidth:800,scrollLeft:180,scrollTop:54},buttons=["day","week","today","fit"].map(a=>({dataset:{calendarAction:a},setAttribute(k,v){this[k]=v;}}));
const el={dataset:{canvasScope:"p",planMode:"timeline",calendarDays:"28",calendarTodayOffset:"7"},style:{setProperty:(k,v)=>props.set(k,v),getPropertyValue:k=>props.get(k)||""},addEventListener:(k,f)=>listeners.set(k,f),dispatchEvent(){},querySelector:s=>s===".plan-gantt-scroll"?scroll:s===".plan-row-name"?{getBoundingClientRect:()=>({width:200})}:s==="[data-calendar-storage-label]"?label:null,querySelectorAll:s=>s==="[data-calendar-action]"?buttons:[]};
const sandbox={window:{},AbortController,CustomEvent:class{},requestAnimationFrame:fn=>fn(),localStorage:{getItem:k=>stored.get(k)||null,setItem(k,v){if(failing)throw Error("quota");stored.set(k,v);}}};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const mount=()=>{const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el,pushEvent:(event,payload)=>sent.push({event,payload:plain(payload)}),handleEvent:(k,f)=>events.set(k,f)};hook.mounted();return hook;};
let hook=mount();assert.equal(label.textContent,"Draft · saved in this browser");assert.equal(props.get("--calendar-days"),"28");assert.equal(sent.length,0);
const change=(field)=>listeners.get("change")({target:field});
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-10-03",checkValidity:()=>true});
assert.deepEqual(sent.at(-1),{event:"change-calendar-plan",payload:{anchor_on:"2026-10-03",durations:{}}});
change({matches:s=>s==="[data-calendar-anchor]",value:"",checkValidity:()=>true});assert.equal(sent.at(-1).payload.anchor_on,null);
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-10-03",checkValidity:()=>true});
change({matches:s=>s==="[data-calendar-duration]",value:"3",dataset:{calendarTaskId:"issue:4"}});
assert.equal(sent.at(-1).payload.durations["issue:4"],3);
const count=sent.length;for(const value of ["0","366","2.5","oops"]){change({matches:s=>s==="[data-calendar-duration]",value,dataset:{calendarTaskId:"issue:4"}});}assert.equal(sent.length,count);
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-02-30",checkValidity:()=>false});assert.equal(sent.length,count);
const center=(scroll.scrollLeft+300)/36;hook.calendarAction("week");assert.equal(props.get("--timeline-day-width"),"14px");assert.equal(buttons[1]["aria-pressed"],"true");assert.equal(scroll.scrollLeft,Math.max(0,center*14-300));
hook.calendarAction("fit");assert.equal(parseFloat(props.get("--timeline-day-width")),576/28);
hook.calendarAction("day");hook.calendarAction("today");assert.equal(scroll.scrollLeft,0);
scroll.scrollLeft=340;scroll.scrollTop=108;hook.beforeUpdate();scroll.scrollLeft=0;scroll.scrollTop=0;hook.updated();assert.equal(scroll.scrollLeft,340);assert.equal(scroll.scrollTop,108);
hook.destroyed();hook=mount();assert.equal(sent.at(-1).payload.durations["issue:4"],3);assert.equal(hook.calendarPrefs.anchor_on,"2026-10-03");
el.dataset.canvasScope="other";hook.updated();assert.deepEqual(plain(hook.calendarPrefs.durations),{});assert.equal(hook.calendarPrefs.anchor_on,null);
hook.destroyed();stored.set("symphony:calendar:v1:other",JSON.stringify({anchor_on:"bad",scale:"agents",durations:{good:365,zero:0,big:366,float:2.5,string:"3"}}));hook=mount();assert.deepEqual(plain(hook.calendarPrefs.durations),{good:365});assert.equal(hook.calendarPrefs.scale,"day");assert.equal(hook.calendarPrefs.anchor_on,null);
hook.destroyed();stored.set("symphony:calendar:v1:other","{");hook=mount();assert.deepEqual(plain(hook.calendarPrefs.durations),{});
failing=true;hook.saveCalendar();assert.equal(label.textContent,"Draft · not saved");hook.calendarAction("week");assert.equal(label.textContent,"Draft · not saved");hook.destroyed();
''')

    def test_filters_and_chat_viewport_remain_consistent_during_rapid_view_change(self):
        script = self.board_fixture()
        self.run_hook(script + r'''
const p=mount({label:["label:stale"]});p.el.dataset.boardView="graph";p.hook.urlKey=null;p.hook.apply();assert.deepEqual(plain(p.hook.prefs.label),[]);
p.hook.prefs.label=["label:backend"];p.hook.apply();p.hook.save();
const link={dataset:{boardViewLink:"gantt"},closest:s=>s==="[data-board-view-link]"?link:null};let prevented=false;
p.listeners.get("click")({target:link,button:0,preventDefault(){prevented=true;}});assert(prevented);assert.equal(p.sent.at(-1).event,"switch-view");assert.deepEqual(plain(p.sent.at(-1).payload),{view:"gantt",filters:{view:"gantt",label:'["label:backend"]'}});
const count=p.sent.length;p.flush();assert.equal(p.sent.length,count); // No stale delayed save changes the new view.
p.el.dataset.boardView="gantt";p.hook.save();p.flush();assert.equal(p.sent.at(-1).payload.view,"gantt");
let modifiersPrevented=false;p.listeners.get("click")({target:link,button:0,ctrlKey:true,preventDefault(){modifiersPrevented=true;}});assert.equal(modifiersPrevented,false);
const originalAll=p.el.querySelectorAll.bind(p.el);const node=(id,hidden=false)=>({dataset:{planTaskId:id},closest:s=>s==="[hidden]"&&hidden?{}:null,getClientRects:()=>[{}],getBoundingClientRect:()=>({left:10,right:200,top:10,bottom:80})});
p.el.querySelectorAll=s=>s==='[data-plan-task-id][data-plan-visible="true"]'?[node("running"),node("running"),node("queued"),node("done",true)]:originalAll(s);
p.el.dataset.chatOpen="true";p.el.dataset.chatProject="github:example/repo";p.el.querySelector("#management-chat-dock").getBoundingClientRect=()=>({left:1000});p.hook.captureContext();
assert.deepEqual(plain(p.sent.at(-1).payload.visible_task_ids),["running"]);assert.deepEqual(plain(p.sent.at(-1).payload.viewport_task_ids),["running"]);
// Unsupported or malformed URL selections stay closed across view switches, while saved preferences remain sanitized.
for (const filters of [{status:"unknown"},{kind:"unknown"},{priority:"P99"},{project:"missing"},{label:"not-json"},{label:'["label:kind:testing"]'},{assignee:'["assignee:bob",false]'},{label:JSON.stringify(Array(21).fill("label:backend"))}]) {
  const bad=mount({},filters);bad.el.dataset.boardView="graph";bad.hook.apply();assert.deepEqual(bad.visible(),[]);bad.hook.save();bad.flush();const closed=bad.hook.serializedFilters("gantt");
  const reopened=mount({},closed);assert.deepEqual(reopened.visible(),[]);
}
const mixed=mount({}, {status:"unknown,work",label:'["label:kind:testing","label:bug, ui"]'});assert.deepEqual(mixed.visible(),["queued"]);
const savedOnly=mount({status:["unknown"],label:["label:kind:testing"]});assert.equal(savedOnly.visible().length,5);
// Only an explicit switch back to the board focuses the selected card, not every update.
let focused=0,scrolled=0;const board=mount();board.el.dataset.boardView="kanban";board.queued.focus=()=>focused++;board.queued.scrollIntoView=()=>scrolled++;
board.focusEvents.get("focus-plan-task")({id:"queued",view:"kanban"});assert.equal(focused,1);assert.equal(scrolled,1);board.hook.updated();assert.equal(focused,1);
board.focusEvents.get("focus-plan-task")({id:"queued",view:"graph"});assert.equal(focused,1);
board.el.dataset.selectedTask="queued";board.hook.prefs.label=["label:backend"];board.hook.apply();assert.equal(board.queued.hidden,false);assert.equal(board.queued.dataset.filterContext,"true");assert.equal(board.lanes.get("work").count.textContent,0);
board.el.dataset.chatOpen="true";board.el.dataset.chatProject="github:example/repo";board.hook.captureContext();assert(!board.sent.at(-1).payload.visible_task_ids.includes("queued"));
const direct={dataset:{boardViewLink:"graph",boardViewTask:"queued"},closest:s=>s==="[data-board-view-link]"?direct:null};board.listeners.get("click")({target:direct,button:0,preventDefault(){}});assert.equal(board.sent.at(-1).payload.id,"queued");assert.equal(board.sent.at(-1).payload.filters.label,'["label:backend"]');

''')

    def test_mobile_filters_toggle_and_close_on_view_navigation(self):
        self.run_hook(self.board_fixture() + r'''
const p=mount(),toolbar={dataset:{mobileFilters:"false"}},attrs={"aria-expanded":"false"};let focus=0;
const button={dataset:{},hasAttribute:name=>name==="data-mobile-filter-toggle",setAttribute(k,v){attrs[k]=v;},focus(){focus++;},closest:s=>s==="button"?button:null,matches:()=>false};
const original=p.el.querySelector.bind(p.el);p.el.querySelector=s=>s==="#board-toolbar"?toolbar:s==="[data-mobile-filter-toggle]"?button:original(s);
const click=()=>p.listeners.get("click")({target:button,button:0});click();assert.equal(toolbar.dataset.mobileFilters,"true");assert.equal(attrs["aria-expanded"],"true");
p.hook.openFilter("label");assert.equal(p.hook.popup,"label");
delete toolbar.dataset.mobileFilters;p.hook.updated();assert.equal(toolbar.dataset.mobileFilters,"true");assert.equal(attrs["aria-expanded"],"true");assert.equal(p.hook.popup,"label");
click();assert.equal(toolbar.dataset.mobileFilters,"false");assert.equal(attrs["aria-expanded"],"false");assert.equal(p.hook.popup,null);
click();p.hook.openFilter("status");p.hook.toggle("status","work");assert.deepEqual(p.visible(),["queued"]);assert.equal(toolbar.dataset.mobileFilters,"true");
const link={dataset:{boardViewLink:"graph"},closest:s=>s==="[data-board-view-link]"?link:null};p.listeners.get("click")({target:link,button:0,preventDefault(){}});
assert.equal(toolbar.dataset.mobileFilters,"false");assert.equal(attrs["aria-expanded"],"false");assert.equal(p.hook.popup,null);assert.equal(p.sent.at(-1).event,"switch-view");assert.equal(p.sent.at(-1).payload.filters.status,"work");
click();let prevented=false;p.listeners.get("keydown")({target:button,key:"Escape",preventDefault(){prevented=true;},stopPropagation(){}});assert(prevented);assert.equal(toolbar.dataset.mobileFilters,"false");assert.equal(focus,1);
''')

    def test_stacked_mobile_chat_does_not_occlude_planning_viewport(self):
        self.run_hook(self.board_fixture() + r'''
for (const view of ["graph","gantt"]) {
  const p=mount(),originalQuery=p.el.querySelector.bind(p.el),originalAll=p.el.querySelectorAll.bind(p.el);
  p.el.dataset.boardView=view;p.el.dataset.chatOpen="true";p.el.dataset.chatProject="github:example/repo";
  let dock={left:0,right:375,top:224,bottom:400};
  const board={left:0,right:375,top:0,bottom:224},area={left:0,right:375,top:80,bottom:224};
  const node=(id,rect)=>({dataset:{planTaskId:id},closest:()=>null,getClientRects:()=>[{}],getBoundingClientRect:()=>rect});
  const nodes=[node("running",{left:150,right:330,top:140,bottom:180}),node("queued",{left:150,right:330,top:200,bottom:260}),node("done",{left:20,right:200,top:240,bottom:280}),node("backlog",{left:400,right:580,top:100,bottom:150})];
  p.el.querySelector=s=>s===".board-main"?{getBoundingClientRect:()=>board}:s==="#management-chat-dock"?{getBoundingClientRect:()=>dock}:s===".plan-gantt-scroll"||s==='[data-plan-panel]:not([hidden]) .plan-canvas'?{getBoundingClientRect:()=>area}:originalQuery(s);
  p.el.querySelectorAll=s=>s==='[data-plan-task-id][data-plan-visible="true"]'?nodes:originalAll(s);
  p.hook.captureContext();assert.deepEqual(plain(p.sent.at(-1).payload.viewport_task_ids),["running","queued"]);
  assert.equal(p.sent.at(-1).payload.visible_task_ids.length,5);
  // The queued node crosses the canvas bottom but its upper portion remains visible.
  // A side dock clips fully covered rows, while a row crossing its top stays visible.
  dock={left:100,right:375,top:160,bottom:400};
  p.hook.captureContext();assert.deepEqual(plain(p.sent.at(-1).payload.viewport_task_ids),["running"]);
}
''')


if __name__ == "__main__":
    unittest.main()
