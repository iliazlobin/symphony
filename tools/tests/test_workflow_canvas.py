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
assert.deepEqual(plain(hook.camera()),camera); // Selection never recenters the user's viewport.
hook.updated();assert.equal(hook.mode,"dependencies"); // Work selection stays in task dependencies.
hook.pointerFocus=true;listeners.get("focusin")({target:{closest:()=>selected}});assert.deepEqual(plain(hook.camera()),camera);
hook.pointerFocus=false;
listeners.get("focusin")({target:{closest:()=>selected}});assert.equal(hook.camera().x+size.width/(2*hook.camera().scale),478);
el.dataset.canvasScope="other";hook.updated();assert.equal(hook.cameras.size,1);assert.notDeepEqual(plain(hook.camera()),camera);
assert(viewportEvents>8);hook.destroyed();assert.equal(hook.abort.signal.aborted,true);assert.equal(hook.pointers.size,0);
''')

    def test_selection_is_immediate_coalesced_and_survives_stale_patches_without_camera_or_focus_changes(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const listeners=new Map(),globalEvents=new Map(),replies=[],sent=[],frames=[];let focused=0;
const plain=x=>JSON.parse(JSON.stringify(x));
const nodes=Array.from({length:120},(_,i)=>({dataset:{planTaskId:"issue:"+i,nodeId:"task:"+i,nodeX:String(i*10),nodeY:"100",nodeWidth:"260",nodeHeight:"116",selected:"false",related:"false"},
 querySelector:s=>s===".plan-node-select"?{setAttribute(){},focus(){focused++;}}:s===".plan-node-meta span"?{textContent:"GH-"+i}:{textContent:"Task "+i}}));
const edges=nodes.slice(1).map((n,i)=>({dataset:{edgeSource:n.dataset.nodeId,edgeTarget:nodes[i].dataset.nodeId}}));
const svg={dataset:{contentWidth:"1600",contentHeight:"600"},attrs:{},setAttribute(k,v){this.attrs[k]=v;},querySelector:()=>nodes[0],querySelectorAll:s=>s==="[data-plan-node]"?nodes:s==="[data-edge-source]"?edges:[]};
const canvas={getBoundingClientRect:()=>({left:0,top:0,width:1000,height:600}),querySelector:()=>svg};
const label={hidden:true},links=[{dataset:{},textContent:"Show timeline",setAttribute(k,v){this[k]=v;},href:"http://localhost/?view=gantt&chat_session=work:old"}];
const toolbar={dataset:{},querySelector:()=>label,querySelectorAll:()=>links};
const el={dataset:{canvasScope:"p",planMode:"dependencies",selectedTaskId:"issue:0"},addEventListener:(n,f)=>listeners.set(n,f),dispatchEvent(){},
 contains:()=>false,closest:()=>({querySelector:()=>toolbar}),querySelector:s=>s.includes("data-plan-panel")?canvas:null,querySelectorAll:s=>s==="[data-plan-panel]"?[{dataset:{planPanel:"dependencies"}}]:[]};
const sandbox={document:{addEventListener:(n,f)=>globalEvents.set("document:"+n,f)},window:{location:{href:"http://localhost/"},addEventListener:(n,f)=>globalEvents.set(n,f)},URL,AbortController,CustomEvent:class{},requestAnimationFrame:fn=>frames.push(fn)};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el,pushEvent:(name,payload,reply)=>{sent.push({name,payload:plain(payload)});replies.push(reply);}};hook.mounted();
while(frames.length)frames.shift()();const camera=plain(hook.camera()),viewBox=svg.attrs.viewBox;
const click=id=>{const button={hasAttribute:()=>false,getAttribute:()=>id};let stopped=false;
 listeners.get("click")({target:{closest:s=>s==='[phx-click="select-plan-task"]'?button:null},preventDefault(){},stopPropagation(){stopped=true;}});assert(stopped);};
click("issue:10");assert.equal(nodes[10].dataset.selected,"true");assert.equal(nodes[9].dataset.related,"true");assert.equal(edges[9].dataset.related,"true");
assert.equal(replies.length,1);assert.equal(label.textContent,"GH-10");assert.equal(label.hidden,false);assert.equal(links[0].dataset.boardViewTask,"issue:10");assert(!links[0].href.includes("chat_session"));
assert.equal(links[0]["aria-label"],"Show timeline: GH-10");
click("issue:20");click("issue:30");assert.equal(replies.length,1);assert.equal(nodes[30].dataset.selected,"true");assert.equal(nodes[10].dataset.selected,"false");
// An earlier server response must not flash its selection or reset the viewBox.
hook.beforeUpdate();el.dataset.selectedTaskId="issue:10";svg.attrs.viewBox="0 0 1600 600";nodes.forEach(n=>n.dataset.selected="false");hook.updated();
assert.equal(svg.attrs.viewBox,viewBox);assert.equal(nodes[30].dataset.selected,"true");assert.equal(label.textContent,"GH-30");
replies.shift()({selected_task_id:"issue:10"});assert.equal(replies.length,1);assert.deepEqual(sent.map(s=>s.payload.id),["issue:10","issue:30"]);
assert.equal(nodes[30].dataset.selected,"true");replies.shift()({selected_task_id:"issue:30"});assert.equal(hook.pendingSelection,null);
assert.deepEqual(plain(hook.camera()),camera);assert.equal(focused,0);
while(frames.length)frames.shift()();assert(Number.isFinite(Number(el.dataset.selectionFeedbackMs)));assert(Number.isFinite(Number(el.dataset.selectionSettledMs)));
// A rejected stale card rolls back to the canonical selection; destroyed hooks ignore late replies.
click("issue:40");replies.shift()({selected_task_id:"issue:30"});assert.equal(nodes[40].dataset.selected,"false");assert.equal(nodes[30].dataset.selected,"true");
// A newer picker selection or browser history navigation cancels unsent graph intent.
click("issue:60");click("issue:70");const sentBefore=sent.length;
globalEvents.get("document:click")({button:0,metaKey:true,target:{closest:()=>({tagName:"A"})}});assert.equal(hook.pendingSelection.id,"issue:70");
globalEvents.get("document:click")({target:{closest:()=>({})}});
el.dataset.selectedTaskId="issue:80";nodes.forEach(n=>n.dataset.selected=String(n===nodes[80]));hook.updated();
replies.shift()({selected_task_id:"issue:60"});assert.equal(sent.length,sentBefore);assert.equal(nodes[80].dataset.selected,"true");
click("issue:90");click("issue:100");globalEvents.get("popstate")();replies.shift()({selected_task_id:"issue:90"});assert.equal(hook.pendingSelection,null);assert.equal(replies.length,0);
// A newer graph click survives an older external navigation patch still in flight.
click("issue:40");el.dataset.selectedTaskId="issue:110";hook.updated();assert.equal(nodes[40].dataset.selected,"true");
replies.shift()({selected_task_id:"issue:40"});assert.equal(replies.length,0);
// LiveView removes attributes absent from its template, including after a reply.
while(frames.length)frames.shift()();
const feedback=el.dataset.selectionFeedbackMs,settled=el.dataset.selectionSettledMs;
assert(Number.isFinite(Number(feedback)));assert(Number.isFinite(Number(settled)));
hook.beforeUpdate();delete el.dataset.selectionFeedbackMs;delete el.dataset.selectionSettledMs;hook.updated();
assert.equal(el.dataset.selectionFeedbackMs,feedback);assert.equal(el.dataset.selectionSettledMs,settled);
while(frames.length)frames.shift()();
// A new click clears the previous sample; a superseded RAF cannot republish it.
click("issue:45");click("issue:46");
assert.equal(el.dataset.selectionFeedbackMs,undefined);assert.equal(el.dataset.selectionSettledMs,undefined);
frames.shift()();assert.equal(el.dataset.selectionFeedbackMs,undefined);
frames.shift()();assert(Number.isFinite(Number(el.dataset.selectionFeedbackMs)));
replies.shift()({selected_task_id:"issue:45"});replies.shift()({selected_task_id:"issue:46"});
assert(Number.isFinite(Number(el.dataset.selectionSettledMs)));
// Scope changes clear the sample and ignore both old frame and reply callbacks.
click("issue:47");hook.beforeUpdate();el.dataset.canvasScope="other";
delete el.dataset.selectionFeedbackMs;delete el.dataset.selectionSettledMs;hook.updated();
while(frames.length)frames.shift()();replies.shift()({selected_task_id:"issue:47"});
assert.equal(el.dataset.selectionFeedbackMs,undefined);assert.equal(el.dataset.selectionSettledMs,undefined);
click("issue:50");hook.destroyed();replies.shift()({selected_task_id:"issue:30"});assert.equal(nodes[50].dataset.selected,"true");
''')

    def test_graph_patch_retains_only_original_control_focus_without_revealing_or_stealing_it(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),plain=x=>JSON.parse(JSON.stringify(x));
const listeners=new Map(),focusCalls=[],body={},html={},document={body,documentElement:html,activeElement:body,addEventListener(){}};
function node(id){
 const n={dataset:{nodeId:"task:"+id,planTaskId:"issue:"+id,nodeX:"44",nodeY:"44",nodeWidth:"260",nodeHeight:"116"},
  getBoundingClientRect:()=>({left:-500,right:-240,top:44,bottom:160})};
 n.controls=["select","title"].map(kind=>({isConnected:true,action:kind==="select"?"select-plan-task":"open-card",
  closest:s=>s==="[data-plan-node]"?n:null,matches:s=>s==="button.plan-node-select, button.plan-node-title",
  getAttribute(){return this.action;},focus(options){focusCalls.push({control:this,options:plain(options)});document.activeElement=this;listeners.get("focusin")({target:this});}}));
 n.querySelector=s=>s===".plan-node-select"?n.controls[0]:s===".plan-node-title"?n.controls[1]:null;
 return n;
}
const nodes=[19,25,21,24].map(node),target=nodes[3];
const svg={dataset:{contentWidth:"1284",contentHeight:"600"},attrs:{},setAttribute(k,v){this.attrs[k]=v;},querySelector:()=>null,querySelectorAll:s=>s==="[data-plan-node]"?nodes:[]};
const canvas={getBoundingClientRect:()=>({left:0,top:0,right:1000,bottom:600,width:1000,height:600}),querySelector:()=>svg};
const el={dataset:{canvasScope:"p",planMode:"dependencies"},addEventListener:(n,f)=>listeners.set(n,f),dispatchEvent(){},
 contains:c=>c.isConnected&&nodes.includes(c.closest?.("[data-plan-node]")),querySelector:s=>s.includes("data-plan-panel")?canvas:null,
 querySelectorAll:s=>s==="[data-plan-panel]"?[{dataset:{planPanel:"dependencies"}}]:[]};
const sandbox={document,window:{},AbortController,CustomEvent:class{},requestAnimationFrame:fn=>fn()};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el};hook.mounted();const camera=plain(hook.camera()),viewBox=svg.attrs.viewBox;
// Native reinsertion retains the element but drops focus during filtered 4→7 context expansion.
for(const [i,fallback] of [body,html].entries()){
 const control=target.controls[i];document.activeElement=control;hook.beforeUpdate();
 if(!i)nodes.push(...[20,22,23].map(node));document.activeElement=fallback;svg.attrs.viewBox="0 0 1284 600";hook.updated();
 assert.equal(document.activeElement,control);assert.deepEqual(focusCalls.at(-1),{control,options:{preventScroll:true}});
 assert.deepEqual(plain(hook.camera()),camera);assert.equal(svg.attrs.viewBox,viewBox);assert.equal(hook.restoringPatchFocus,false);
 const count=focusCalls.length;hook.updated();assert.equal(focusCalls.length,count); // A later patch cannot replay old focus.
}
const patch=(mutate)=>{document.activeElement=target.controls[0];hook.beforeUpdate();const count=focusCalls.length;mutate();hook.updated();assert.equal(focusCalls.length,count);};
// Retained focus and newer user focus on inputs/navigation/viewport tools need no restoration.
patch(()=>{});
for(const active of [{tagName:"INPUT"},{tagName:"A"},{tagName:"BUTTON"}]){
 patch(()=>document.activeElement=active);assert.equal(document.activeElement,active);
}
// Replacement, removal, or changed node/action identity must never focus a substitute control.
patch(()=>{target.controls[0].isConnected=false;nodes.splice(nodes.indexOf(target),1,node(24));document.activeElement=body;});
nodes.splice(nodes.findIndex(n=>n.dataset.nodeId==="task:24"),1,target);target.controls[0].isConnected=true;
patch(()=>{target.dataset.planTaskId="issue:other";document.activeElement=body;});target.dataset.planTaskId="issue:24";
patch(()=>{target.controls[0].action="other";document.activeElement=body;});target.controls[0].action="select-plan-task";
patch(()=>{nodes.splice(nodes.indexOf(target),1);document.activeElement=body;});nodes.push(target);
patch(()=>{el.dataset.canvasScope="other";document.activeElement=body;});assert.equal(document.activeElement,body);
// No control was focused before these patches: background and another canvas are left alone.
for(const active of [body,{isConnected:true,closest:()=>node(999),matches:()=>true}]){
 document.activeElement=active;hook.beforeUpdate();const count=focusCalls.length;document.activeElement=body;hook.updated();assert.equal(focusCalls.length,count);
}
hook.destroyed();
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
let hook=mount();assert.equal(label.textContent,"Draft · saved in this browser");assert.equal(props.get("--calendar-days"),"28");assert.equal(sent.length,0);assert.equal(el.dataset.calendarDense,"false");
const change=(field)=>listeners.get("change")({target:field});
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-10-03",checkValidity:()=>true});
assert.deepEqual(sent.at(-1),{event:"change-calendar-plan",payload:{anchor_on:"2026-10-03",durations:{}}});
change({matches:s=>s==="[data-calendar-anchor]",value:"",checkValidity:()=>true});assert.equal(sent.at(-1).payload.anchor_on,null);
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-10-03",checkValidity:()=>true});
change({matches:s=>s==="[data-calendar-duration]",value:"3",dataset:{calendarTaskId:"issue:4"}});
assert.equal(sent.at(-1).payload.durations["issue:4"],3);
const count=sent.length;for(const value of ["0","366","2.5","oops"]){change({matches:s=>s==="[data-calendar-duration]",value,dataset:{calendarTaskId:"issue:4"}});}assert.equal(sent.length,count);
change({matches:s=>s==="[data-calendar-anchor]",value:"2026-02-30",checkValidity:()=>false});assert.equal(sent.length,count);
const center=(scroll.scrollLeft+300)/36;hook.calendarAction("week");assert.equal(props.get("--timeline-day-width"),"14px");assert.equal(buttons[1]["aria-pressed"],"true");assert.equal(scroll.scrollLeft,Math.max(0,center*14-300));assert.equal(el.dataset.calendarDense,"true");
hook.calendarAction("fit");assert.equal(parseFloat(props.get("--timeline-day-width")),576/28);assert.equal(el.dataset.calendarDense,"true");
// Fit keeps day numbers when cells are wide enough; density follows geometry, not the scale name.
scroll.clientWidth=1200;hook.calendarAction("fit");assert.equal(parseFloat(props.get("--timeline-day-width")),976/28);assert.equal(el.dataset.calendarDense,"false");
delete el.dataset.calendarDense;hook.beforeUpdate();hook.updated();assert.equal(el.dataset.calendarDense,"false");
scroll.clientWidth=840;hook.calendarAction("fit");assert.equal(props.get("--timeline-day-width"),"22px");assert.equal(el.dataset.calendarDense,"false");
scroll.clientWidth=839.9;hook.calendarAction("fit");assert.equal(el.dataset.calendarDense,"true");
scroll.clientWidth=800;hook.calendarAction("day");assert.equal(el.dataset.calendarDense,"false");hook.calendarAction("today");assert.equal(scroll.scrollLeft,0);
scroll.scrollLeft=340;scroll.scrollTop=108;hook.beforeUpdate();scroll.scrollLeft=0;scroll.scrollTop=0;hook.updated();assert.equal(scroll.scrollLeft,340);assert.equal(scroll.scrollTop,108);
hook.destroyed();hook=mount();assert.equal(sent.at(-1).payload.durations["issue:4"],3);assert.equal(hook.calendarPrefs.anchor_on,"2026-10-03");
el.dataset.canvasScope="other";hook.updated();assert.deepEqual(plain(hook.calendarPrefs.durations),{});assert.equal(hook.calendarPrefs.anchor_on,null);
hook.destroyed();stored.set("symphony:calendar:v1:other",JSON.stringify({anchor_on:"bad",scale:"agents",durations:{good:365,zero:0,big:366,float:2.5,string:"3"}}));hook=mount();assert.deepEqual(plain(hook.calendarPrefs.durations),{good:365});assert.equal(hook.calendarPrefs.scale,"day");assert.equal(hook.calendarPrefs.anchor_on,null);
hook.destroyed();stored.set("symphony:calendar:v1:other","{");hook=mount();assert.deepEqual(plain(hook.calendarPrefs.durations),{});
failing=true;hook.saveCalendar();assert.equal(label.textContent,"Draft · not saved");hook.calendarAction("week");assert.equal(label.textContent,"Draft · not saved");hook.destroyed();
''')

    def test_calendar_resize_refits_dates_and_preserves_date_center_without_dispatch(self):
        self.run_hook(r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const props=new Map(),sent=[],scroll={clientWidth:1200,scrollLeft:0,scrollTop:54};let nameWidth=260,resize;
const el={dataset:{canvasScope:"p",planMode:"timeline",calendarDays:"28"},style:{setProperty:(k,v)=>props.set(k,v),getPropertyValue:k=>props.get(k)||""},addEventListener(){},dispatchEvent(){},querySelector:s=>s===".plan-gantt-scroll"?scroll:s===".plan-row-name"?{getBoundingClientRect:()=>({width:nameWidth})}:null,querySelectorAll:()=>[]};
const sandbox={window:{},AbortController,CustomEvent:class{},requestAnimationFrame:fn=>fn(),localStorage:{getItem:()=>null,setItem(){}},ResizeObserver:class{constructor(fn){resize=fn;}observe(){}unobserve(){}disconnect(){}}};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const hook={...sandbox.window.SymphonyHooks.WorkflowCanvas,el,pushEvent:(...event)=>sent.push(event)};hook.mounted();
const width=()=>parseFloat(props.get("--timeline-day-width"));
const resizeTo=(viewport,name)=>{scroll.clientWidth=viewport;nameWidth=name;resize();};
hook.calendarAction("fit");assert.equal(width(),916/28);assert.equal(el.dataset.calendarDense,"false");assert.equal(scroll.scrollLeft,0);
resizeTo(390,200);assert.equal(width(),166/28);assert.equal(el.dataset.calendarDense,"true");assert.equal(scroll.scrollLeft,0);assert.equal(hook.calendarViewport.nameWidth,200);
resizeTo(1200,260);assert.equal(width(),916/28);assert.equal(el.dataset.calendarDense,"false");assert.equal(scroll.scrollLeft,0);
// Day/Week keep their fixed cell widths and the date at the viewport center when space changes.
el.dataset.calendarDays="140";hook.calendarAction("day");scroll.scrollLeft=420;
const dayCenter=(scroll.scrollLeft+470)/36;resizeTo(390,200);assert.equal(width(),36);assert.equal(el.dataset.calendarDense,"false");assert.equal((scroll.scrollLeft+95)/36,dayCenter);
resizeTo(1200,260);assert.equal(width(),36);assert.equal(scroll.scrollLeft,420);
hook.calendarAction("week");scroll.scrollLeft=300;
const weekCenter=(scroll.scrollLeft+470)/14;resizeTo(390,200);assert.equal(width(),14);assert.equal(el.dataset.calendarDense,"true");assert.equal((scroll.scrollLeft+95)/14,weekCenter);
resizeTo(1200,260);assert.equal(width(),14);assert.equal(scroll.scrollLeft,300);assert.equal(scroll.scrollTop,54);
assert.equal(sent.length,0);hook.destroyed();
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
