"""Observe the shipped renderer's source guards, SVG filtering and asynchronous ownership."""
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const namespace="http://www.w3.org/2000/svg";
class Element {
 constructor(name="div",attrs={}){this.localName=name;this.namespaceURI=namespace;this.attributes=[];this.children=[];this.style={};this.dataset={};this.textContent="";this.removed=false;for(const [key,value] of Object.entries(attrs))this.setAttribute(key,value);}
 setAttribute(name,value){this.removeAttribute(name);this.attributes.push({name,value:String(value)});}
 getAttribute(name){return this.attributes.find(attribute=>attribute.name===name)?.value ?? null;}
 removeAttribute(name){this.attributes=this.attributes.filter(attribute=>attribute.name!==name);}
 removeAttributeNode(attribute){this.attributes=this.attributes.filter(item=>item!==attribute);}
 append(...nodes){for(const node of nodes){node.parent=this;this.children.push(node);}}
 replaceChildren(...nodes){this.children=[];this.append(...nodes);}
 remove(){this.removed=true;if(this.parent)this.parent.children=this.parent.children.filter(child=>child!==this);}
 querySelectorAll(){return this.children.flatMap(child=>[child,...child.querySelectorAll("*")]);}
}
function svg(markup){
 const root=new Element("svg",{xmlns:namespace,viewBox:"0 0 800 400",height:"400",id:"diagram"});
 if(markup==="wrong")root.localName="iframe";
 if(markup==="large")root.setAttribute("viewBox","0 0 16000 8000");
 if(markup==="invalid-size")root.setAttribute("viewBox","0 0 Infinity 400");
 if(markup==="unsafe"){
  root.setAttribute("onload","alert(1)");
  root.append(new Element("script"),new Element("image",{href:"https://outside.example/pixel"}),new Element("foreignObject"),new Element("a",{href:"https://outside.example/"}));
  const css=new Element("style");css.textContent="@import 'https://outside.example/style.css';";root.append(css);
  const escaped=new Element("style");escaped.textContent=String.raw`.node{fill:u\72l(\2f pixel)}`;root.append(escaped);
  root.append(new Element("rect",{style:"fill:url(https://outside.example/image)",onclick:"alert(1)",fill:"#fff"}));
  root.append(new Element("path",{id:"local"}),new Element("use",{href:"#local"}),new Element("use",{"xlink:href":"javascript:alert(1)"}));
 }
 if(markup==="identifiers"){
  root.append(new Element("line",{id:"actor0"}),new Element("line",{id:"actor0"}),new Element("marker",{id:"marker"}));
  root.append(new Element("path",{"marker-end":"url(#marker)","aria-labelledby":"diagram actor0"}),new Element("use",{href:"#marker"}),new Element("use",{href:"#outside"}));
  const css=new Element("style");css.textContent="#diagram #actor0 {fill:#fff;marker-end:url(#marker);}";root.append(css);
 }
 return root;
}
const calls={initialize:[],parse:[],render:[]},behavior={parse:async()=>({diagramType:"flowchart"}),render:async()=>({svg:"valid"})};
const mermaid={initialize(config){calls.initialize.push(config);},parse(source){calls.parse.push(source);return behavior.parse(source);},render(id,source,container){calls.render.push({id,source,container});return behavior.render(id,source,container);}};
const sandbox={mermaid,Promise,Set,Number,String};
const source=fs.readFileSync(process.argv[1],"utf8").replace(/^import mermaid from "mermaid";\n/,"").replace("export function mountSpecificationDiagram", "function mountSpecificationDiagram");
vm.runInNewContext(source+"\nthis.mount=mountSpecificationDiagram;",sandbox);
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function fixture(text="flowchart TD\nA-->B"){
 const input=new Element("pre");input.textContent=text;input.dataset.specDiagramId="architecture-main";
 const preview=new Element(),feedback=new Element(),body=new Element(),theme=new Element();theme.dataset.theme="light";
 const observers=[];
 class Observer{constructor(callback){this.callback=callback;observers.push(this);}observe(target,options){this.target=target;this.options=options;}disconnect(){this.disconnected=true;}}
 class Parser{parseFromString(markup){return{documentElement:svg(markup),querySelector(){return null;}};}}
 const document={body,defaultView:{DOMParser:Parser,MutationObserver:Observer},createElement:()=>new Element(),importNode:node=>node};
 const selectors=new Map([["[data-spec-mermaid][data-spec-diagram-id]",input],["[data-spec-preview]",preview],["[data-spec-feedback]",feedback]]);
 const el={isConnected:true,ownerDocument:document,closest:()=>theme,querySelector:selector=>selectors.get(selector)};
 const controller=sandbox.mount(el);
 return{controller,el,input,preview,feedback,body,theme,observers};
}
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for renderer lifecycle tests")
class SpecificationDiagramTests(unittest.TestCase):
    def run_renderer(self, source):
        result = subprocess.run([shutil.which("node"), "-e", FIXTURE + "\n(async()=>{\n" + source +
                                 "\n})().catch(error=>{console.error(error);process.exitCode=1;});",
                                str(ROOT / "elixir/assets/specification-diagram.js")],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_destroyed_hook_evicts_failed_import_without_removing_a_newer_load(self):
        source = r'''
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const dashboard=fs.readFileSync(process.argv[1],"utf8");
const start=dashboard.indexOf("  const specificationRenderers = new Map();");
const end=dashboard.indexOf("  window.SymphonyHooks =",start);
assert(start>=0 && end>start);
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
const loads=[],pending=[deferred(),deferred()],mounted=[];
const sandbox={load(url){loads.push(url);return pending[loads.length-1].promise;}};
vm.runInNewContext(dashboard.slice(start,end).replace("import(url)","load(url)")+"\nthis.hook=SpecificationDiagram;this.cache=specificationRenderers;",sandbox);
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function fixture(){const label={textContent:"Opening diagram preview…"};return{label,el:{isConnected:true,dataset:{specRenderer:"/assets/local-renderer.js"},querySelector(){return label;}}};}
(async()=>{
 const stopped=fixture();sandbox.hook.mounted.call(stopped);sandbox.hook.destroyed.call(stopped);
 pending[0].reject(new Error("Temporary asset failure"));await tick();
 assert.equal(stopped.label.textContent,"Opening diagram preview…");assert.equal(sandbox.cache.size,0);
 const next=fixture();sandbox.hook.mounted.call(next);assert.equal(loads.length,2);
 pending[1].resolve({mountSpecificationDiagram(el){mounted.push(el);return{update(){},destroy(){}};}});await tick();
 assert.equal(mounted.length,1);assert.equal(mounted[0],next.el);assert(next.renderer);sandbox.hook.destroyed.call(next);
 const obsolete=deferred(),replacement=Promise.resolve({});sandbox.cache.set("/assets/local-renderer.js",obsolete.promise);
 const old=fixture();sandbox.hook.mounted.call(old);sandbox.hook.destroyed.call(old);
 sandbox.cache.set("/assets/local-renderer.js",replacement);obsolete.reject(new Error("Superseded asset failure"));await tick();
 assert.equal(sandbox.cache.get("/assets/local-renderer.js"),replacement);assert.equal(old.label.textContent,"Opening diagram preview…");
})().catch(error=>{console.error(error);process.exitCode=1;});
'''
        result = subprocess.run([shutil.which("node"), "-e", source,
                                 str(ROOT / "elixir/priv/static/dashboard.js")],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_strict_render_preserves_source_and_responsive_preview(self):
        self.run_renderer('''
const f=fixture();await tick();
assert.equal(calls.parse.length,1);assert.equal(calls.render.length,1);
const config=calls.initialize[0];assert.equal(config.securityLevel,"strict");assert.equal(config.startOnLoad,false);
assert.equal(config.htmlLabels,false);assert.equal(config.flowchart.htmlLabels,false);assert.equal(config.suppressErrorRendering,true);
assert.equal(config.maxTextSize,60000);assert.equal(config.maxEdges,500);assert(config.secure.includes("securityLevel"));
assert.equal(f.input.textContent,"flowchart TD\\nA-->B");assert.equal(f.feedback.textContent,"Diagram ready");
const output=f.preview.children[0];assert.equal(output.getAttribute("width"),"800");assert.equal(output.getAttribute("height"),"400");
assert.equal(output.getAttribute("viewBox"),"0 0 800 400");assert.equal(output.getAttribute("xmlns"),namespace);
assert.equal(output.style.width,"auto");assert.equal(output.style.maxWidth,"100%");assert.equal(f.body.children.length,0);
await f.controller.update();assert.equal(calls.render.length,1);f.controller.destroy();
''')

    def test_unchanged_updates_restore_feedback_without_replacing_cached_svg(self):
        self.run_renderer('''
const f=fixture();await tick();const svg=f.preview.children[0];
f.feedback.textContent="Opening diagram preview…";await f.controller.update();
assert.equal(f.feedback.textContent,"Diagram ready");assert.equal(f.preview.children[0],svg);assert.equal(calls.parse.length,1);assert.equal(calls.render.length,1);f.controller.destroy();
behavior.parse=async()=>{throw{hash:{loc:{first_line:4}}};};const g=fixture();await tick();
g.feedback.textContent="Opening diagram preview…";await g.controller.update();
assert.equal(g.feedback.textContent,"Check Mermaid syntax near line 4.");assert.equal(calls.parse.length,2);assert.equal(calls.render.length,1);g.controller.destroy();
behavior.parse=async()=>({diagramType:"flowchart"});const delayed=deferred();behavior.render=()=>delayed.promise;
const h=fixture();await tick();h.feedback.textContent="Opening diagram preview…";await h.controller.update();
assert.equal(h.feedback.textContent,"Rendering diagram…");assert.equal(calls.render.length,2);
delayed.resolve({svg:"valid"});await tick();assert.equal(h.feedback.textContent,"Diagram ready");h.controller.destroy();
''')

    def test_svg_sizes_are_finite_intrinsic_and_bounded_without_upscaling(self):
        self.run_renderer('''
behavior.render=async()=>({svg:"large"});const f=fixture();await tick();
const svg=f.preview.children[0];assert.equal(svg.getAttribute("width"),"4096");assert.equal(svg.getAttribute("height"),"2048");
assert.equal(svg.style.width,"auto");assert.equal(svg.style.height,"auto");assert.equal(svg.style.maxWidth,"100%");f.controller.destroy();
behavior.render=async()=>({svg:"invalid-size"});const g=fixture();await tick();
assert.equal(g.preview.children.length,0);assert(g.feedback.textContent.includes("preview unavailable"));g.controller.destroy();
''')

    def test_external_resources_and_configuration_never_reach_mermaid(self):
        self.run_renderer('''
for(const text of ["%%{init: {securityLevel: 'loose'}}%%\\nflowchart TD\\nA-->B","---\\nconfig: {}\\n---\\nflowchart TD\\nA-->B",
"flowchart TD\\nA[<img src='/pixel'>]","flowchart TD\\nA@{img: '/pixel'}","flowchart TD\\nclick A call callback()",
"sequenceDiagram\\nlink A: Read@https://outside.example/","flowchart TD\\nA[//outside.example/pixel]","flowchart TD\\nstyle A fill:url(/pixel)",
"flowchart TD; click A call callback()","flowchart TD\\nclassDef default fill:red;} body {display:none;}",
String.raw`flowchart TD; classDef default fill:u\\72l(\\2f pixel)`]){
 const f=fixture(text);await tick();assert.equal(calls.parse.length,0,text);assert.equal(calls.render.length,0,text);
 assert(f.feedback.textContent.includes("local shapes and text"));assert.equal(f.input.textContent,text);f.controller.destroy();
}
''')

    def test_empty_and_oversized_source_are_not_parsed(self):
        self.run_renderer('''
const empty=fixture("  ");await tick();assert.equal(empty.preview.dataset.specState,"empty");empty.controller.destroy();
const large=fixture("a".repeat(60001));await tick();assert(large.feedback.textContent.includes("60,000"));large.controller.destroy();
assert.equal(calls.parse.length,0);assert.equal(calls.render.length,0);
''')

    def test_standard_uml_stereotypes_relations_and_local_styles_are_renderable(self):
        self.run_renderer('''
for(const source of ["classDiagram\\nclass Service {\\n<<interface>>\\n+send()\\n}\\nClient --> Service",
"classDiagram\\nBase <|-- Child", "erDiagram\\nUser ||--o{ Choice : saves",
"flowchart TD\\nA-->B\\nclassDef default fill:#eef,stroke:#556", "classDiagram\\nclass Link {\\n+url() string\\n}"]){
 const f=fixture(source);await tick();assert.equal(f.feedback.textContent,"Diagram ready",source);f.controller.destroy();
}
assert.equal(calls.render.length,5);
''')

    def test_svg_filter_removes_active_and_external_content_and_keeps_local_references(self):
        self.run_renderer('''
behavior.render=async()=>({svg:"unsafe"});const f=fixture();await tick();
const output=f.preview.children[0];assert.equal(output.getAttribute("onload"),null);
assert.equal(output.children.filter(child=>["script","image","foreignObject","a","style"].includes(child.localName)).length,0);
const rect=output.children.find(child=>child.localName==="rect");assert.equal(rect.getAttribute("onclick"),null);assert.equal(rect.getAttribute("style"),null);assert.equal(rect.getAttribute("fill"),"#fff");
assert.equal(output.children.find(child=>child.localName==="use").getAttribute("href"),"#"+output.children.find(child=>child.localName==="path").getAttribute("id"));
assert(output.children.every(child=>child.getAttribute("xlink:href")===null));assert.equal(f.body.children.length,0);f.controller.destroy();
''')

    def test_each_svg_scopes_duplicate_native_ids_and_preserves_its_references(self):
        self.run_renderer('''
behavior.render=async()=>({svg:"identifiers"});const f=fixture();const g=fixture();await tick();
const all=[];
for(const root of [f.preview.children[0],g.preview.children[0]]){
 const nodes=[root,...root.querySelectorAll("*")];all.push(...nodes.map(node=>node.getAttribute("id")).filter(Boolean));
 const marker=nodes.find(node=>node.localName==="marker").getAttribute("id");
 const path=nodes.find(node=>node.localName==="path");assert.equal(path.getAttribute("marker-end"),"url(#"+marker+")");
 assert.equal(path.getAttribute("aria-labelledby"),root.getAttribute("id")+" "+nodes.find(node=>node.localName==="line").getAttribute("id"));
 const uses=nodes.filter(node=>node.localName==="use");assert.equal(uses[0].getAttribute("href"),"#"+marker);assert.equal(uses[1].getAttribute("href"),null);
 const css=nodes.find(node=>node.localName==="style").textContent;assert(css.includes("#"+root.getAttribute("id")));assert(css.includes("fill:#fff"));assert(css.includes("url(#"+marker+")"));
}
assert.equal(new Set(all).size,all.length);f.controller.destroy();g.controller.destroy();
''')

    def test_syntax_failure_is_plain_feedback_and_next_source_remains_renderable(self):
        self.run_renderer('''
behavior.parse=async()=>{throw{message:"<script>bad</script>",hash:{loc:{first_line:3}}};};
const f=fixture();await tick();assert.equal(f.feedback.textContent,"Check Mermaid syntax near line 3.");assert.equal(calls.render.length,0);
behavior.parse=async()=>({diagramType:"flowchart"});f.input.textContent="flowchart TD\\nA-->C";
await f.controller.update();assert.equal(f.feedback.textContent,"Diagram ready");assert.equal(f.body.children.length,0);f.controller.destroy();
''')

    def test_replaced_source_and_destroyed_hook_cannot_publish_delayed_svg(self):
        self.run_renderer('''
const delayed=deferred();behavior.render=()=>delayed.promise;const f=fixture();await tick();
f.input.textContent="flowchart TD\\nA-->C";const update=f.controller.update();
behavior.render=async()=>({svg:"valid"});delayed.resolve({svg:"wrong"});await update;
assert.equal(f.feedback.textContent,"Diagram ready");assert.equal(calls.render.length,2);assert.equal(f.preview.children.length,1);f.controller.destroy();
const stopped=deferred();behavior.render=()=>stopped.promise;const g=fixture();await tick();
g.controller.destroy();stopped.resolve({svg:"unsafe"});await tick();assert.equal(g.preview.children.length,0);assert.equal(g.body.children.length,0);
assert(g.observers[0].disconnected);
''')

    def test_theme_change_redraws_only_current_diagram_and_unique_ids(self):
        self.run_renderer('''
const f=fixture();await tick();f.theme.dataset.theme="dark";f.observers[0].callback();await tick();
assert.equal(calls.initialize.at(-1).theme,"dark");assert.equal(calls.render.length,2);
assert.notEqual(calls.render[0].id,calls.render[1].id);assert.equal(f.feedback.textContent,"Diagram ready");f.controller.destroy();
''')

    def test_render_failure_and_invalid_svg_leave_no_temporary_dom(self):
        self.run_renderer('''
behavior.render=async()=>{throw new Error("render failed");};const f=fixture();await tick();
assert.equal(f.preview.children.length,0);assert.equal(f.body.children.length,0);f.controller.destroy();
behavior.render=async()=>({svg:"wrong"});const g=fixture();await tick();
assert.equal(g.preview.children.length,0);assert.equal(g.body.children.length,0);assert(g.feedback.textContent.includes("preview unavailable"));g.controller.destroy();
''')
