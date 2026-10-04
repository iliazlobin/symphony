"""Native-scene migration and the reviewed semantic-edit boundary, without a DOM."""
import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";
const {createSceneModel, SECTION_IDS, FIELD_SECTIONS, FIELD_TITLES, SCENE_LIMITS} = await import(pathToFileURL(process.argv[1]).href);
const copy = value => JSON.parse(JSON.stringify(value));
let counter = 0;
// Rendering uses the official converter in the app. This deterministic injected
// converter supplies text metrics and native defaults for pure contract checks.
function convert(skeletons) {
  return skeletons.map(skeleton => {
    const lines = (skeleton.text || "").split("\n"), font = skeleton.fontSize || 16;
    const points = skeleton.points || [], xs = points.map(point => point[0]), ys = points.map(point => point[1]);
    return {id: "native-" + ++counter, type: skeleton.type, x: 0, y: 0, angle: 0,
      width: 100, height: 100, groupIds: [], seed: 123, version: 1, versionNonce: 456,
      isDeleted: false, boundElements: null, updated: 1, strokeColor: "#343a40", ...copy(skeleton),
      ...(skeleton.type === "text" ? {text: skeleton.text || "", originalText: skeleton.originalText ?? skeleton.text ?? "", width: Math.max(...lines.map(line => line.length)) * font * 0.55, height: Math.max(1, lines.length) * font * 1.25} : {}),
      ...(skeleton.type === "arrow" || skeleton.type === "line" ? {startBinding: null, endBinding: null,
        width: points.length ? Math.max(...xs) - Math.min(...xs) : 100,
        height: points.length ? Math.max(...ys) - Math.min(...ys) : 0} : {})};
  });
}
const model = createSceneModel(convert), project = "github:example/events-concierge";
const meta = element => element.customData?.symphony;
function suggest(canvas, section, changes, extra = {}) {
  return {version: 1, project, section, base_document: canvas.document_id, base_revision: canvas.revision, changes, ...extra};
}
function legacy() {
  const boards = Object.fromEntries(SECTION_IDS.map(section => [section, {nodes: [], edges: [], strokes: [], viewport: {x: 28, y: 28, scale: 1}}]));
  for (const [field, section] of Object.entries(FIELD_SECTIONS)) boards[section].nodes.push({id: "note-" + field, kind: "note", field, title: FIELD_TITLES[field], text: "Original " + field, x: boards[section].nodes.length * 350, y: 0, width: 320});
  return {version: 1, project, document_id: "design-original", revision: 7, boards};
}
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for scene contract tests")
class DesignSceneTests(unittest.TestCase):
    def run_scene(self, script):
        result = subprocess.run(
            [shutil.which("node"), "--input-type=module", "-e", FIXTURE + script,
             str(ROOT / "elixir/assets/design-scene.js")],
            capture_output=True, text=True, check=False, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_migration_keeps_full_notes_bindings_strokes_and_camera_without_editing_source(self):
        self.run_scene(r'''
const old = legacy();
old.boards.data.nodes.push({id:"entity-user",kind:"entity",title:"User\nidentity",text:"id: UUID\n" + "中🙂".repeat(1500),x:-500,y:420,width:240},
 {id:"entity-event",kind:"entity",title:"Event",text:"id: UUID",x:350,y:470});
old.boards.data.edges.push({id:"edge-saved",from:"entity-user",to:"entity-event",label:"many → many"});
old.boards.data.strokes.push({id:"stroke-one",points:[[-100,220],[-80,230],[-60,210]]});
old.boards.data.viewport = {x:-500,y:300,scale:0.5};
const before = copy(old), native = model.migrate(old, project);
assert(native); assert.deepEqual(old,before); assert.equal(native.version,2);
assert.equal(native.document_id,old.document_id); assert.equal(native.revision,7);
const board = model.projection(native,"data"), user=board.nodes.find(node=>node.id==="entity-user");
assert.equal(user.title,"User\nidentity"); assert.equal(user.text,old.boards.data.nodes[1].text);
assert.deepEqual(board.edges,old.boards.data.edges);
const elements=native.boards.data.elements, shape=elements.find(e=>meta(e)?.role==="node"&&meta(e).id==="entity-user");
const arrow=elements.find(e=>meta(e)?.role==="edge"), label=elements.find(e=>meta(e)?.role==="edge-label");
assert.equal(arrow.startBinding.elementId,shape.id); assert.equal(label.containerId,arrow.id);
assert(arrow.boundElements.some(item=>item.id===label.id)); assert(shape.boundElements.some(item=>item.id===arrow.id));
const stroke=elements.find(e=>e.type==="freedraw");
assert.deepEqual(stroke.points.map(point=>[point[0]+stroke.x,point[1]+stroke.y]),old.boards.data.strokes[0].points);
assert.deepEqual(native.boards.data.appState,{scrollX:-1000,scrollY:600,zoom:{value:0.5}});
for(const [field,section] of Object.entries(FIELD_SECTIONS)) assert.equal(model.fields(native)[field],old.boards[section].nodes.find(node=>node.field===field).text);
assert.deepEqual(model.migrate(native,project),native);
assert.equal(model.migrate(old,"other-project"),null);
old.boards.data.edges[0].to="missing"; assert.equal(model.migrate(old,project),null);
''')

    def test_native_validation_bounds_content_without_losing_styles_or_tombstones(self):
        self.run_scene(r'''
const source=model.empty(project), data=source.boards.data.elements;
data[0].customData.operatorStyle={note:"Keep custom metadata"}; data[0].strokeStyle="dashed";
assert.deepEqual(model.validate(source,project),source);
for(const change of [d=>d.project="other",d=>d.revision=Number.MAX_SAFE_INTEGER+1,
 d=>d.boards.data.elements[0].x=Infinity,d=>d.boards.data.elements[0].strokeWidth=NaN,
 d=>d.boards.data.elements.push(copy(d.boards.data.elements[0])),
 d=>d.boards.data.elements[1].originalText="x".repeat(SCENE_LIMITS.text+1),
 d=>d.boards.data.elements[0].boundElements=[{id:"missing",type:"arrow"}],
 d=>d.boards.data.appState.zoom.value=0,
 d=>d.boards.data.elements[0].customData.symphony.extra="unknown",
 d=>d.boards.data.elements[0].link={unexpected:true},
 d=>d.boards.data.elements[1].font={unexpected:true},
 d=>d.boards.data.elements[1].fontSize="large",
 d=>d.boards.data.elements[1].fontFamily={},
 d=>d.boards.data.elements[0].locked="false",
 d=>d.boards.data.elements[0].versionNonce=0.2,
 d=>d.boards.data.elements[0].roundness={type:3,value:"round"},
 d=>d.boards.data.elements[0].type="embeddable",
 d=>d.boards.data.elements[0].customData.blob="x".repeat(SCENE_LIMITS.bytes)]) {
 const candidate=copy(source); change(candidate); const previous=structuredClone(candidate);assert.equal(model.validate(candidate,project),null);assert.deepEqual(candidate,previous,"invalid restoration data remains recoverable");
}
const bounded=copy(source), template=copy(data[0]); delete template.customData;
while(bounded.boards.data.elements.length<=SCENE_LIMITS.elements) bounded.boards.data.elements.push({...template,id:"limit-"+bounded.boards.data.elements.length});
assert.equal(model.validate(bounded,project),null);
const withNodes=model.add(model.add(source,"data","entity"),"data","entity"), nodes=model.projection(withNodes,"data").nodes.filter(n=>!n.field);
const linked=model.proposal(withNodes,suggest(withNodes,"data",[{op:"add_edge",edge:{from:nodes[0].id,to:nodes[1].id,label:"uses"}}]));
for(const e of linked.boards.data.elements) if(meta(e)?.id===nodes[0].id) e.isDeleted=true;
assert(model.validate(linked,project),"retained native tombstones and their bindings are valid");
assert.equal(model.projection(linked,"data").edges.length,0);
''')

    def test_native_path_restoration_refuses_malformed_data_without_losing_in_progress_sketches(self):
        self.run_scene(r'''
const source=model.empty(project), baseline=copy(source);
function drawing(type, values={}) {return {id:"native-path",type,x:10,y:20,width:80,height:40,angle:0,points:[[0,0],[80,40]],simulatePressure:true,...values};}
for(const type of ["line","arrow","freedraw"]) {
 for(const points of [undefined,null,{},"path",[[0,"bad"]],[[0,0,1]],[[0,Infinity]],Array.from({length:SCENE_LIMITS.points+1},()=>[0,0])]) {
  const candidate=copy(source);candidate.boards.brief.elements.push(drawing(type,{points}));const before=structuredClone(candidate);
  assert.equal(model.validate(candidate,project),null,"malformed native "+type+" points cannot reach restore");
  assert.deepEqual(candidate,before,"raw path remains available for recovery");
 }
 for(const points of [[],[[0,0]],[[0,0],[80,40]]]) {
  const candidate=copy(source);candidate.boards.brief.elements.push(drawing(type,{points}));
  assert.deepEqual(model.validate(candidate,project),candidate,"in-progress "+type+" remains valid");
 }
}
const elbow=drawing("arrow",{elbowed:true,points:[[0,0],[80,0],[80,40]],fixedSegments:[{index:1,start:[0,0],end:[80,0]}]});
for(const fixedSegments of [undefined,null,[],elbow.fixedSegments]) {
 const candidate=copy(source);candidate.boards.brief.elements.push({...elbow,fixedSegments});
 assert(model.validate(candidate,project),"valid native elbow segments and optional history data remain supported");
}
for(const fixedSegments of [{bad:true},"segments",[null],[{}],[{index:1,start:[0,0],end:[80,"bad"]}],
 [{index:1.5,start:[0,0],end:[80,0]}],[{index:-1,start:[0,0],end:[80,0]}],
 [{index:SCENE_LIMITS.points+1,start:[0,0],end:[80,0]}],Array.from({length:SCENE_LIMITS.points+1},()=>({index:1,start:[0,0],end:[80,0]}))]) {
 const candidate=copy(source);candidate.boards.brief.elements.push({...elbow,fixedSegments});const before=structuredClone(candidate);
 assert.equal(model.validate(candidate,project),null);assert.deepEqual(candidate,before,"malformed elbow data stays recoverable");
}
for(const values of [{simulatePressure:false},{simulatePressure:false,pressures:{}},{simulatePressure:false,pressures:[NaN]}]) {
 const candidate=copy(source);candidate.boards.brief.elements.push(drawing("freedraw",values));assert.equal(model.validate(candidate,project),null);
}
const pressure=copy(source);pressure.boards.brief.elements.push(drawing("freedraw",{simulatePressure:false,pressures:[.2,.8]}));
assert.deepEqual(model.validate(pressure,project),pressure,"real pen pressure is preserved");
assert.deepEqual(source,baseline);
''')

    def test_native_deletion_clears_fields_and_duplication_keeps_independent_semantics(self):
        self.run_scene(r'''
const source=model.empty(project,{entities:"Original entities"}), board=source.boards.data;
const originals=copy(board.elements), duplicate=copy(originals);
for(const e of duplicate) {e.id="copy-"+e.id;e.groupIds=["duplicate-group"];e.x+=500;}
board.elements.push(...duplicate); assert.equal(model.validate(source,project),null);
board.elements=model.normalizeElements(board.elements,"data"); assert(model.validate(source,project));
const projection=model.projection(source,"data"); assert.equal(projection.nodes.length,2);
assert.equal(projection.nodes.filter(n=>n.field).length,1); assert.notEqual(projection.nodes[0].id,projection.nodes[1].id);
assert.equal(projection.nodes[1].text,"Original entities");
const individual=copy(board.elements.find(e=>meta(e)?.role==="body")); individual.id="copied-individual"; individual.groupIds=[];
board.elements.push(individual); board.elements=model.normalizeElements(board.elements,"data");
assert.equal(meta(board.elements.at(-1)),undefined); assert(model.validate(source,project));
for(const e of board.elements) if(meta(e)?.id==="note-entities") e.isDeleted=true;
board.elements=model.normalizeElements(board.elements,"data");
assert.equal(model.fields(source).entities,""); assert.equal(model.projection(source,"data").nodes.length,1);
const cleared=model.withFields(source,{entities:""}); assert.equal(model.projection(cleared,"data").nodes.length,1,"empty fields do not recreate deleted cards");
const restored=model.withFields(source,{entities:"Explicit human content"}); assert.equal(model.fields(restored).entities,"Explicit human content");
const wrong=copy(originals); for(const e of wrong) e.id="wrong-"+e.id;
source.boards.architecture.elements.push(...model.normalizeElements(wrong,"architecture"));
assert(model.validate(source,project)); assert.equal(model.projection(source,"architecture").nodes.find(n=>n.id==="note-entities").field,undefined);
''')

    def test_recreated_outline_fields_keep_the_initial_layout_and_do_not_move_surviving_notes(self):
        self.run_scene(r'''
const source=model.empty(project,{components:"Original components",flows:"Original flow"});
const initial=copy(model.projection(source,"architecture").nodes);
for(const element of source.boards.architecture.elements) element.isDeleted=true;
const before=copy(source), values={components:"Web client\nBackend\nData store",flows:"User → Web client → Backend → Data store"};
const restored=model.withFields(source,values);assert(restored);assert.deepEqual(source,before);
const outlines=model.projection(restored,"architecture").nodes.filter(node=>node.field);
assert.equal(outlines.length,2);assert.equal(model.fields(restored).components,values.components);assert.equal(model.fields(restored).flows,values.flows);
for(const note of outlines) {const old=initial.find(node=>node.field===note.field);assert.equal(note.x,old.x);assert.equal(note.y,old.y);}
assert(outlines[0].x+outlines[0].width<=outlines[1].x,"recreated outlines do not cover one another");
const illustrative=model.example(restored);assert(illustrative);
assert.deepEqual(model.projection(illustrative,"architecture").nodes.filter(node=>node.field),outlines);
assert.equal(model.fields(illustrative).components,values.components);assert.equal(model.fields(illustrative).flows,values.flows);

const partial=model.empty(project,{components:"Manually placed components"}), elements=partial.boards.architecture.elements;
for(const element of elements) if(meta(element)?.id==="note-components") {element.x+=800;element.y+=180;}
for(const element of elements) if(meta(element)?.id==="note-flows") element.isDeleted=true;
const survivor=copy(elements.filter(element=>meta(element)?.id==="note-components"));
const replacement=model.withFields(partial,{flows:"Explicit recreated flow"});assert(replacement);
assert.deepEqual(replacement.boards.architecture.elements.filter(element=>meta(element)?.id==="note-components"),survivor,"surviving note keeps manual geometry and content");
assert.equal(model.projection(replacement,"architecture").nodes.find(node=>node.field==="flows").x,370);
''')

    def test_proposals_are_atomic_stale_safe_and_preserve_native_user_content(self):
        self.run_scene(r'''
let source=model.empty(project,{brief:"User scope"}), original=copy(source);
const free=convert([{type:"ellipse",id:"untyped-drawing",x:650,y:300,width:140,height:100,strokeStyle:"dotted",customData:{owner:"human"}}])[0];
source.boards.brief.elements.push(free); original=copy(source);
const update=suggest(source,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Proposed scope"}},
 {op:"add_node",node:{id:"component-api",kind:"component",title:"API",text:"Owns requests",x:420,y:0}},
 {op:"add_edge",edge:{id:"edge-api",from:"note-brief",to:"component-api",label:"explores"}}]);
const preview=model.proposal(source,update); assert(preview); assert.deepEqual(source,original);
assert.equal(model.fields(preview).brief,"Proposed scope"); assert.equal(preview.revision,source.revision+1);
assert.deepEqual(preview.boards.brief.elements.find(e=>e.id===free.id),free);
assert.equal(model.proposal(preview,update),null);
assert.equal(model.proposal(source,{...update,base_document:"different-document"}),null);
assert.equal(model.proposal(source,{...update,project:"other"}),null);
assert.equal(model.proposal(source,suggest(source,"brief",[{op:"update_node",id:"note-brief",patch:{text:"No partial write"}},{op:"add_edge",edge:{from:"note-brief",to:"missing",label:"invalid"}}])),null);
assert.deepEqual(source,original);
const node=model.projection(preview,"brief").nodes.find(n=>n.id==="component-api"), shape=preview.boards.brief.elements.find(e=>meta(e)?.id===node.id&&meta(e)?.role==="node");
shape.strokeStyle="dashed";shape.strokeWidth=3;shape.customData.extraStyle="retain";
const changed=model.proposal(preview,suggest(preview,"brief",[{op:"update_node",id:node.id,patch:{x:700,y:200,title:"Updated API"}}]));
const changedShape=changed.boards.brief.elements.find(e=>e.id===shape.id);
assert.equal(changedShape.strokeStyle,"dashed");assert.equal(changedShape.strokeWidth,3);assert.equal(changedShape.customData.extraStyle,"retain");
assert.equal(changedShape.version,shape.version+1);assert.notEqual(changedShape.versionNonce,shape.versionNonce,"native Undo detects moved shapes through nonce changes");
const oldArrow=preview.boards.brief.elements.find(e=>meta(e)?.role==="edge"), newArrow=changed.boards.brief.elements.find(e=>e.id===oldArrow.id);
assert.notEqual(newArrow.versionNonce,oldArrow.versionNonce);assert.equal(newArrow.version,oldArrow.version+1);
assert.equal(newArrow.x+newArrow.points.at(-1)[0],oldArrow.x+oldArrow.points.at(-1)[0]+280);
assert.equal(newArrow.y+newArrow.points.at(-1)[1],oldArrow.y+oldArrow.points.at(-1)[1]+200);
const removed=model.proposal(changed,suggest(changed,"brief",[{op:"remove_node",id:node.id}]));
assert(removed);assert.equal(model.projection(removed,"brief").edges.length,0);
assert(removed.boards.brief.elements.some(e=>e.id===shape.id&&e.isDeleted),"deletions retain native Undo evidence");
assert.notEqual(removed.boards.brief.elements.find(e=>e.id===shape.id).versionNonce,changedShape.versionNonce);
assert.deepEqual(changed.boards.brief.elements.find(e=>e.id===free.id),free,"unrelated native annotations keep their style and history metadata");
assert.deepEqual(model.validate(original,project),original,"restoring a prior native snapshot keeps all content");
''')

    def test_native_bound_text_adoption_uses_only_empty_semantic_bodies_and_preserves_full_content(self):
        self.run_scene(r'''
const source=model.empty(project), board=source.boards.brief;
const shape=board.elements.find(e=>meta(e)?.role==="node"), blank=board.elements.find(e=>meta(e)?.role==="body");
const value="User-authored full evidence\n"+"中🙂".repeat(1800);
const typed=convert([{type:"text",id:"typed-native-body",x:shape.x+15,y:shape.y+55,text:value,originalText:value,containerId:shape.id,
 strokeColor:"#c2255c",fontSize:17,customData:{operator:"retain"}}])[0];
shape.boundElements=[{id:typed.id,type:"text"}];board.elements.push(typed);
const unrelated=convert([{type:"text",id:"loose-annotation",x:800,y:400,text:"Keep this separate"}])[0];board.elements.push(unrelated);
const before=copy(source), normalized=model.normalizeElements(board.elements,"brief");
assert.deepEqual(source,before,"normalization does not mutate its external native source");
const duringEdit=model.normalizeElements(board.elements,"brief",{adoptBoundText:false});
assert.equal(meta(duringEdit.find(e=>e.id===typed.id)),undefined);assert(!duringEdit.find(e=>e.id===blank.id).isDeleted);
source.boards.brief.elements=normalized;assert(model.validate(source,project));
assert.equal(model.fields(source).brief,value);
const adopted=normalized.find(e=>e.id===typed.id), previous=normalized.find(e=>e.id===blank.id);
assert.deepEqual(meta(adopted),{id:"note-brief",role:"body"});assert.deepEqual(adopted.groupIds,shape.groupIds);
assert.equal(adopted.originalText,value);assert.equal(adopted.strokeColor,"#c2255c");assert.equal(adopted.customData.operator,"retain");
assert.equal(adopted.containerId,shape.id);assert(previous.isDeleted);assert.equal(previous.originalText,"");
assert.notEqual(previous.versionNonce,blank.versionNonce);assert.notEqual(adopted.versionNonce,typed.versionNonce);
assert.deepEqual(normalized.find(e=>e.id===unrelated.id),unrelated);
assert.deepEqual(model.normalizeElements(normalized,"brief"),normalized,"adoption is idempotent");
assert.equal(model.proposal(source,suggest(source,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Truncated rewrite"}}])),null);

const occupied=model.empty(project,{brief:"Existing nonblank model content"}), target=occupied.boards.brief.elements.find(e=>meta(e)?.role==="node");
const alternate=convert([{type:"text",id:"alternate-native",x:0,y:60,text:"Other native text",containerId:target.id}])[0];
target.boundElements=[{id:alternate.id,type:"text"}];occupied.boards.brief.elements.push(alternate);
const safe=model.normalizeElements(occupied.boards.brief.elements,"brief");occupied.boards.brief.elements=safe;
assert.equal(model.fields(occupied).brief,"Existing nonblank model content");assert.equal(meta(safe.find(e=>e.id===alternate.id)),undefined);

for(const mismatch of ["no-reciprocal-binding","different-container","two-bound-texts","empty-native-text"]) {
 const candidate=model.empty(project), board=candidate.boards.brief, node=board.elements.find(e=>meta(e)?.role==="node");
 const text=convert([{type:"text",id:"candidate",x:0,y:50,text:mismatch==="empty-native-text"?"":"Proposed text",containerId:mismatch==="different-container"?null:node.id}])[0];
 board.elements.push(text);node.boundElements=mismatch==="no-reciprocal-binding"?null:[{id:text.id,type:"text"}];
 if(mismatch==="two-bound-texts") {const second={...copy(text),id:"candidate-two"};board.elements.push(second);node.boundElements.push({id:second.id,type:"text"});}
 board.elements=model.normalizeElements(board.elements,"brief");assert.equal(model.fields(candidate).brief,"");
 assert.equal(meta(board.elements.find(e=>e.id===text.id)),undefined);assert(!board.elements.find(e=>meta(e)?.role==="body").isDeleted);
}
''')

    def test_text_commit_fits_its_native_group_and_connectors_without_reflowing_unrelated_drawings(self):
        self.run_scene(r'''
let source=model.add(model.add(model.empty(project),"data","entity",{title:"Event",text:"id: UUID",x:440,y:20}),"data","entity",{title:"Venue",text:"id: UUID",x:900,y:20});
const nodes=model.projection(source,"data").nodes.filter(n=>!n.field);
source=model.proposal(source,suggest(source,"data",[{op:"add_edge",edge:{from:nodes[0].id,to:nodes[1].id,label:"at"}}]));
const board=source.boards.data, shape=board.elements.find(e=>meta(e)?.role==="node"&&meta(e).id===nodes[0].id);
const body=board.elements.find(e=>meta(e)?.role==="body"&&meta(e).id===nodes[0].id), title=board.elements.find(e=>meta(e)?.role==="title"&&meta(e).id===nodes[0].id);
const arrow=board.elements.find(e=>meta(e)?.role==="edge"), label=board.elements.find(e=>meta(e)?.role==="edge-label");
const unrelated=convert([{type:"rectangle",id:"unrelated-manual",x:-200,y:900,width:80,height:30,strokeColor:"#c2255c",roughness:2}])[0];board.elements.push(unrelated);
body.originalText="id: UUID\nname: string\ntime: timestamp\nsource: URL\nlocation: point\nstatus: enum";body.text=body.originalText;body.height=150;
body.strokeColor="#c2255c";const input=copy(board.elements), originalShape=copy(shape), originalArrow=copy(arrow), originalLabel=copy(label);
const ordinary=model.normalizeElements(input,"data");assert.equal(ordinary.find(e=>e.id===shape.id).height,originalShape.height,"selection and dragging do not reflow native content");
const fitted=model.normalizeElements(input,"data",{fitTextId:body.id});assert.deepEqual(input,board.elements,"fit leaves external scene untouched");
board.elements=fitted;assert(model.validate(source,project));
const nextShape=fitted.find(e=>e.id===shape.id), nextBody=fitted.find(e=>e.id===body.id), nextArrow=fitted.find(e=>e.id===arrow.id), nextLabel=fitted.find(e=>e.id===label.id);
assert.equal(nextBody.originalText,body.originalText);assert.equal(nextBody.strokeColor,"#c2255c");
assert(nextShape.y+nextShape.height>=nextBody.y+nextBody.height+14,"committed body fits within its container");
assert(nextShape.height>originalShape.height);assert.notEqual(nextShape.versionNonce,originalShape.versionNonce);
assert.equal(nextArrow.y,originalArrow.y+(nextShape.height-originalShape.height)/2,"native bound start anchor follows container growth");
assert.notEqual(nextArrow.versionNonce,originalArrow.versionNonce);assert(nextLabel.y>originalLabel.y);
assert.deepEqual(fitted.find(e=>e.id===unrelated.id),unrelated);
assert.deepEqual(model.normalizeElements(fitted,"data",{fitTextId:body.id}),fitted,"fit is idempotent after text commit");

const bound=model.empty(project), boundBoard=bound.boards.brief, boundShape=boundBoard.elements.find(e=>meta(e)?.role==="node"), boundTitle=boundBoard.elements.find(e=>meta(e)?.role==="title");
const typed=convert([{type:"text",id:"typed-long-body",x:boundShape.x+12,y:boundShape.y+10,text:"line one\nline two\nline three\nline four\nline five\nline six",containerId:boundShape.id,fontSize:16,strokeColor:"#1971c2"}])[0];
boundShape.boundElements=[{id:typed.id,type:"text"}];boundBoard.elements.push(typed);const nativeBefore=copy(boundBoard.elements);
boundBoard.elements=model.normalizeElements(nativeBefore,"brief",{adoptBoundText:true,fitTextId:typed.id});assert(model.validate(bound,project));
const fittedTitle=boundBoard.elements.find(e=>e.id===boundTitle.id), fittedBody=boundBoard.elements.find(e=>e.id===typed.id), fittedContainer=boundBoard.elements.find(e=>e.id===boundShape.id);
assert.equal(fittedBody.y,typed.y,"native bound-body placement remains authoritative");
assert(fittedTitle.y+fittedTitle.height+12<=fittedContainer.y,"bound body gets an unobscured external title");
assert(fittedContainer.y+fittedContainer.height>=fittedBody.y+fittedBody.height+14);assert.equal(fittedBody.originalText,typed.originalText);
assert.equal(fittedBody.containerId,boundShape.id);assert.equal(fittedBody.strokeColor,"#1971c2");
assert.deepEqual(model.normalizeElements(boundBoard.elements,"brief",{fitTextId:typed.id}),boundBoard.elements);
''')

    def test_long_notes_and_hostile_proposals_cannot_overwrite_partial_context(self):
        self.run_scene(r'''
const source=model.empty(project,{brief:"Long evidence " + "x".repeat(2500)}), before=copy(source);
assert.equal(model.proposal(source,suggest(source,"brief",[{op:"update_node",id:"note-brief",patch:{text:"Partial rewrite"}}])),null);
assert.equal(model.proposal(source,suggest(source,"brief",[{op:"remove_node",id:"note-brief"}])),null);
assert(model.proposal(source,suggest(source,"brief",[{op:"update_node",id:"note-brief",patch:{title:"Refined title"}}])));
for(const changes of [[{op:"update_node",id:"note-brief",patch:{html:"bad"}}],
 [{op:"add_node",node:{kind:"entity",title:"x",text:"中".repeat(2000)}}],
 [{op:"add_node",node:{kind:"entity",title:"x",text:"x",field:"brief"}}],
 [{op:"update_node",id:"note-brief",patch:{title:"x"}},{op:"remove_node",id:"note-brief"}],
 [{op:"add_node",node:{id:'x" onclick="bad',kind:"note",title:"x",text:"x"}}],
 [{op:"update_node",id:"note-brief",patch:{x:10001}}]]) assert.equal(model.proposal(source,suggest(source,"brief",changes)),null);
const literal='<img src=x onerror=alert(1)>', native=model.add(source,"brief","note",{title:literal,text:literal});
assert.equal(model.projection(native,"brief").nodes.at(-1).text,literal);
assert.deepEqual(source,before);
''')

    def test_native_arrows_between_semantic_nodes_become_stable_reviewable_connectors(self):
        self.run_scene(r'''
const source=model.add(model.add(model.empty(project),"data","entity"),"data","entity"), board=source.boards.data;
const shapes=board.elements.filter(e=>meta(e)?.role==="node"&&meta(e)?.kind==="entity");
const arrow=convert([{type:"arrow",id:"human-arrow",x:450,y:100,points:[[0,0],[50,25],[120,100]],strokeColor:"#c2255c",strokeStyle:"dashed",customData:{operator:"retain"}}])[0];
arrow.startBinding={elementId:shapes[0].id,focus:0.2,gap:3};arrow.endBinding={elementId:shapes[1].id,focus:-0.4,gap:4};
const label=convert([{type:"text",id:"human-label",x:470,y:125,text:"1 → many",originalText:"1 → many",containerId:arrow.id,fontSize:15,customData:{annotation:"retain"}}])[0];
arrow.boundElements=[{id:label.id,type:"text"}];board.elements.push(arrow,label);
const input=board.elements, before=copy(input), during=model.normalizeElements(input,"data",{adoptBoundText:false});
assert.equal(meta(during.find(e=>e.id===arrow.id)),undefined);assert.equal(meta(during.find(e=>e.id===label.id)),undefined);
board.elements=model.normalizeElements(input,"data");assert.deepEqual(input,before,"external input stays unchanged");
assert(model.validate(source,project));const projected=model.projection(source,"data").edges;
assert.equal(projected.length,1);assert.equal(projected[0].from,meta(shapes[0]).id);assert.equal(projected[0].to,meta(shapes[1]).id);assert.equal(projected[0].label,"1 → many");
const adopted=board.elements.find(e=>e.id===arrow.id), adoptedLabel=board.elements.find(e=>e.id===label.id);
assert.equal(adopted.strokeColor,arrow.strokeColor);assert.equal(adopted.strokeStyle,arrow.strokeStyle);assert.deepEqual(adopted.points,arrow.points);
assert.deepEqual(adopted.startBinding,arrow.startBinding);assert.deepEqual(adopted.endBinding,arrow.endBinding);assert.equal(adopted.customData.operator,"retain");
assert.equal(adoptedLabel.originalText,label.originalText);assert.equal(adoptedLabel.fontSize,15);assert.equal(adoptedLabel.customData.annotation,"retain");
assert.equal(meta(adoptedLabel).id,meta(adopted).id);assert.equal(adoptedLabel.containerId,adopted.id);
assert.deepEqual(model.normalizeElements(board.elements,"data"),board.elements,"semantic IDs remain stable after adoption");
const moved=model.proposal(source,suggest(source,"data",[{op:"update_node",id:meta(shapes[0]).id,patch:{x:700}}]));assert(moved);
assert.deepEqual(moved.boards.data.elements.find(e=>e.id===arrow.id).points.slice(1,-1).map(p=>[p[0]+moved.boards.data.elements.find(e=>e.id===arrow.id).x,p[1]+moved.boards.data.elements.find(e=>e.id===arrow.id).y]),arrow.points.slice(1,-1).map(p=>[p[0]+arrow.x,p[1]+arrow.y]),"native arrow middle vertices retain their world positions");

for(const kind of ["no-end","same-node","line","ambiguous-label","foreign-metadata"]) {
 const candidate=copy(source), elements=candidate.boards.data.elements, extra=copy(arrow);extra.id="extra-"+kind;extra.boundElements=null;delete extra.customData.symphony;
 if(kind==="no-end")extra.endBinding=null;if(kind==="same-node")extra.endBinding=extra.startBinding;if(kind==="line")extra.type="line";
 if(kind==="foreign-metadata")extra.customData.symphony={id:"custom-identity",role:"unrecognized"};
 if(kind==="ambiguous-label") {extra.boundElements=[];for(let i=0;i<2;i++){const text={...copy(label),id:"ambiguous-"+i,containerId:extra.id};elements.push(text);extra.boundElements.push({id:text.id,type:"text"});}}
 elements.push(extra);const normalized=model.normalizeElements(elements,"data"), result=normalized.find(e=>e.id===extra.id);
 assert.deepEqual(result.customData,extra.customData,"unqualified native content keeps its own metadata");
}
const long=copy(source), nativeLabel=long.boards.data.elements.find(e=>e.id===label.id);nativeLabel.originalText="Full relationship evidence " + "中".repeat(3000);nativeLabel.text=nativeLabel.originalText;
assert(model.validate(long,project));assert.equal(model.projection(long,"data").edges[0].label,nativeLabel.originalText);
assert.equal(model.proposal(long,suggest(long,"data",[{op:"remove_edge",id:projected[0].id}])),null,"bounded agent context cannot remove a long native label");
''')

    def test_fingerprint_ignores_editor_bookkeeping_but_observes_content_and_examples_preserve_drawings(self):
        self.run_scene(r'''
const source=model.empty(project), before=model.fingerprint(source.boards.brief.elements), edited=copy(source.boards.brief.elements);
for(const e of edited){e.version++;e.versionNonce++;e.updated++;e.index="new-index";}
assert.equal(model.fingerprint(edited),before);
edited[0].strokeColor="#ff0000";assert.notEqual(model.fingerprint(edited),before);
const reordered=copy(source.boards.brief.elements).reverse();assert.notEqual(model.fingerprint(reordered),before);
const drawn=convert([{type:"line",id:"human-line",x:100,y:100,points:[[0,0],[100,40]]}])[0];source.boards.data.elements.push(drawn);
const data=copy(source.boards.data), illustrative=model.example(source);
assert(illustrative);assert.deepEqual(illustrative.boards.data,data);
assert.equal(model.projection(illustrative,"architecture").nodes.filter(n=>!n.field).length,3);
assert.equal(model.projection(illustrative,"architecture").edges.length,2);
const elements=illustrative.boards.architecture.elements;
for(const arrow of elements.filter(e=>meta(e)?.role==="edge")) {
 const from=elements.find(e=>e.id===arrow.startBinding.elementId),to=elements.find(e=>e.id===arrow.endBinding.elementId);
 const label=elements.find(e=>e.containerId===arrow.id);
 assert(to.x-from.x-from.width>=160,"new example reserves a readable connector gap");
 assert(label.x>=from.x+from.width&&label.x+label.width<=to.x,"relationship label does not cover example components");
}
for(const node of elements.filter(e=>meta(e)?.role==="node"&&!meta(e).field)) {
 for(const text of elements.filter(e=>e.type==="text"&&meta(e)?.id===meta(node).id)) {
  assert(text.x>=node.x&&text.x+text.width<=node.x+node.width);
  assert(text.y>=node.y&&text.y+text.height<=node.y+node.height,"native example text fits its container");
 }
}
assert.equal(model.example(illustrative),null);
''')


if __name__ == "__main__":
    unittest.main()
