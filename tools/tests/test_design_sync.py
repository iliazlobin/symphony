"""Observe the shipped Design storage hook across conflicts and lost replies."""
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm");
const stored = new Map();
const sandbox = {window: {}, AbortController, setTimeout, clearTimeout, Date, URL,
 localStorage: {setItem(key,value) {stored.set(key,value);},getItem(key){return stored.get(key) ?? null;}}};
vm.runInNewContext(fs.readFileSync(process.argv[1],"utf8"),sandbox);
const copy = value => JSON.parse(JSON.stringify(value));
const scene = n => ({version:2,project:"github:example/demo",document_id:"design-one",revision:n,boards:{brief:{elements:[{id:"note",text:String(n)}]}}});
const state = (draft, revision=0, reviewed=null) => ({draft, storage_revision:revision, reviewed});
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
 const calls=[], labels=[];
 const hook = {el:{dataset:{designProject:"github:example/demo"},addEventListener(){},querySelector(){return null;}},
 editor:{validate(value,project){return value?.project===project && value.version===2 ? value : null;}},
 status(value){labels.push(value);},pushEvent(event,args,reply){calls.push({event,args,reply});},flush(){},save(){},canvas:{canSave(){return true;},document(){return sync.serverDraft;}}};
 const sync = new sandbox.window.SymphonyDesignSync(hook);
 const answer = (index,data) => calls[index].reply({ok:true,data});
 return {sync,hook,calls,labels,answer};
}
function historicalFixture() {
 const f=fixture(), selections=[], nodes=new Map();
 const element = () => ({hidden:true,textContent:"",children:[],style:{},
   replaceChildren(){this.children=[];this.textContent="";},append(item){this.children.push(item);},focus(){}});
 for(const selector of ["[data-design-review-panel]","[data-design-confirm-review]","[data-design-review-description]","[data-design-change-list]","[data-design-review-label]"]) nodes.set(selector,element());
 const close=element(); nodes.get("[data-design-review-panel]").querySelector=()=>close;
 f.hook.el.querySelector=selector=>nodes.get(selector) || null;
 f.hook.el.ownerDocument={activeElement:close,createElement:element};
 f.hook.select=section=>selections.push(section);
 const historical=scene(1); historical.boards.data={elements:[
   {isDeleted:false,customData:{symphony:{id:"event",role:"node"}}},
   {isDeleted:false,originalText:"Event",customData:{symphony:{id:"event",role:"title"}}},
   {isDeleted:false,originalText:"id: uuid",customData:{symphony:{id:"event",role:"body"}}}
 ]};
 const sourceURL=(item="event")=>"http://localhost:8861/projects/demo/?view=design&design_ref="+"a".repeat(64)+"&design_section=data&design_item="+item+"&design_task=github%3Aexample%2Fdemo%3A25";
 sandbox.window.location={href:sourceURL()};
 return {...f,nodes,selections,historical,sourceURL};
}
'''


@unittest.skipUnless(shutil.which("node"), "Node is required for storage hook tests")
class DesignSyncTests(unittest.TestCase):
    def run_hook(self, source):
        result = subprocess.run([shutil.which("node"), "-e", FIXTURE +
                                 "\n(async()=>{\n" + source + "\n})().catch(error=>{console.error(error);process.exitCode=1;});",
                                 str(ROOT / "elixir/priv/static/design-sync.js")],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_open_uses_project_authority_and_ignores_json_key_order(self):
        self.run_hook('''
const f=fixture(), local=scene(2), reordered={boards:local.boards,revision:2,document_id:local.document_id,project:local.project,version:2};
const open=f.sync.open(local); f.answer(0,state(reordered,7));
assert.deepEqual(copy(await open),local); assert(f.sync.canWrite()); assert.equal(f.sync.revision,7);
f.sync.save(local); await tick(); assert.equal(f.calls.length,1); f.sync.destroy();
''')

    def test_missing_or_invalid_callbacks_are_unconfirmed_for_each_request_contract(self):
        self.run_hook('''
for(const event of ["design-load","design-save","design-review","design-reviewed"]){
 for(const reply of [undefined,null,[],{}, {ok:"true",data:{}}, {ok:true}, {ok:true,data:null}, {ok:true,data:{}}, {ok:false}, {ok:false,error:{}}]){
  const f=fixture(), request=f.sync.request(event); f.calls[0].reply(reply);
  assert.deepEqual(copy(await request),{ok:false,error:"design_request_unconfirmed"}); f.sync.destroy();
 }
}
const f=fixture(), request=f.sync.request("prepare-design-task"); f.calls[0].reply({ok:true});
assert.deepEqual(copy(await request),{ok:true}); f.sync.destroy();
''')

    def test_historical_reference_denial_or_missing_reply_stays_retryable_after_sign_in(self):
        self.run_hook('''
for(const denied of [{ok:false,error:"unauthorized"},undefined,{ok:true},{ok:true,data:{}}]){
 const f=historicalFixture(), local=scene(9), open=f.sync.open(local);
 f.calls[0].reply({ok:false,error:"unauthorized"}); assert.deepEqual(copy(await open),local);
 const reference=f.sync.sourceReference(); f.calls[1].reply(denied); await reference;
 assert.equal(f.sync.sourceKey,null); assert.equal(f.selections.length,0);
 assert(f.nodes.get("[data-design-review-panel]").hidden); assert(!f.sync.canWrite());
 assert(f.labels.at(-1).includes(denied?.error==="unauthorized" ? "Sign in" : "not confirmed"));
 // The same mounted hook can retry the historical URL after operator access returns.
 const reopened=f.sync.open(local); f.answer(2,state(local,7)); await reopened;
 assert(f.sync.canWrite()); const retry=f.sync.sourceReference();
 f.answer(3,{scene:f.historical,reviewed_at:"2026-10-04T10:00:00Z"}); await retry;
 assert.deepEqual(f.selections,["data"]); assert(!f.nodes.get("[data-design-review-panel]").hidden);
 assert(f.nodes.get("[data-design-confirm-review]").hidden);
 assert.deepEqual(f.nodes.get("[data-design-change-list]").children.map(row=>row.textContent),["Event","id: uuid"]);
 assert.deepEqual(copy(f.sync.serverDraft),local); assert.equal(f.sync.revision,7);
 const back=f.nodes.get("[data-design-review-label]").children[0];
 assert(back.href.startsWith("/projects/demo/?")); assert(back.href.includes("task=github%3Aexample%2Fdemo%3A25"));
 assert(!back.href.includes("design_ref"));
 const before=f.calls.length; await f.sync.sourceReference(); assert.equal(f.calls.length,before); f.sync.destroy();
}
''')

    def test_late_source_reply_cannot_replace_a_newer_retry_or_cancelled_reference(self):
        self.run_hook('''
const f=historicalFixture(), first=f.sync.sourceReference();
sandbox.window.location.href=f.sourceURL("other"); const second=f.sync.sourceReference();
sandbox.window.location.href=f.sourceURL(); const retry=f.sync.sourceReference();
f.answer(0,{scene:f.historical,reviewed_at:"old"}); await first;
assert.equal(f.selections.length,0); assert(f.nodes.get("[data-design-review-panel]").hidden);
f.calls[1].reply(undefined); await second; assert(f.sync.sourceKey.endsWith("event/github:example/demo:25"));
sandbox.window.location.href="http://localhost:8861/projects/demo/?view=design"; await f.sync.sourceReference();
f.answer(2,{scene:f.historical,reviewed_at:"cancelled"}); await retry;
assert.equal(f.sync.sourceKey,null); assert.equal(f.selections.length,0);
assert(f.nodes.get("[data-design-review-panel]").hidden); f.sync.destroy();
''')

    def test_invalid_historical_section_never_dereferences_inherited_or_malformed_boards(self):
        self.run_hook('''
for(const section of ["constructor","__proto__","outside","data"]){
 const f=historicalFixture(), local=scene(9), open=f.sync.open(local);
 f.answer(0,state(local,7)); await open;
 const url=new URL(f.sourceURL()); url.searchParams.set("design_section",section);
 sandbox.window.location.href=url.href;
 if(section==="data") f.historical.boards.data={elements:{}};
 const reference=f.sync.sourceReference(); f.answer(1,{scene:f.historical,reviewed_at:"old"}); await reference;
 assert.equal(f.sync.sourceKey,null); assert.equal(f.selections.length,0);
 assert(f.nodes.get("[data-design-review-panel]").hidden);
 assert.deepEqual(copy(f.sync.serverDraft),local); assert.equal(f.sync.revision,7);
 // A corrected URL remains retryable in the same hook.
 sandbox.window.location.href=f.sourceURL();
 const reviewed=historicalFixture().historical, retry=f.sync.sourceReference();
 f.answer(2,{scene:reviewed,reviewed_at:"current"}); await retry;
 assert.deepEqual(f.selections,["data"]); assert(!f.nodes.get("[data-design-review-panel]").hidden);
 f.sync.destroy();
}
''')

    def test_browser_draft_never_imports_or_overwrites_without_choice(self):
        self.run_hook('''
const f=fixture(), local=scene(3), open=f.sync.open(local); f.answer(0,state(null));
assert.deepEqual(copy(await open),local); assert(!f.sync.canWrite());
f.sync.save(local); assert.equal(f.calls.length,1);
f.hook.save=()=>f.sync.save(local); f.sync.importDraft(); assert.equal(f.calls.length,2);
assert.equal(f.calls[1].args.storage_revision,0); f.answer(1,state(local,1)); await tick(); f.sync.destroy();
const g=fixture(), conflict=g.sync.open(local); g.answer(0,state(scene(4),9)); await conflict;
assert(g.sync.conflict); assert(!g.sync.canWrite()); g.sync.save(local); assert.equal(g.calls.length,1); g.sync.destroy();
''')

    def test_save_serializes_and_coalesces_edits_with_acknowledged_revision(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(null)); await open;
f.sync.save(scene(1)); f.sync.save(scene(2)); f.sync.save(scene(3)); assert.equal(f.calls.length,2);
f.answer(1,state(scene(1),1)); await tick(); assert.equal(f.calls.length,3);
assert.equal(f.calls[2].args.storage_revision,1); assert.equal(f.calls[2].args.scene.revision,3);
f.answer(2,state(scene(3),2)); await tick(); assert(!f.sync.busy); assert.equal(f.sync.revision,2); f.sync.destroy();
''')

    def test_conflict_or_unconfirmed_write_never_retries_or_advances_revision(self):
        self.run_hook('''
for(const error of ["stale_design_revision","design_request_unconfirmed"]){
 const f=fixture(), open=f.sync.open(null); f.answer(0,state(null)); await open;
 f.sync.save(scene(1)); f.sync.save(scene(2)); f.calls[1].reply({ok:false,error}); await tick();
 assert.equal(f.calls.length,2); assert.equal(f.sync.revision,0); assert(!f.sync.canWrite()); assert.equal(f.sync.pending,null);
 f.sync.save(scene(3)); assert.equal(f.calls.length,2); f.sync.destroy();
}
''')

    def test_review_requires_saved_version_and_reads_immutable_baseline(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(null)); await open;
f.sync.save(scene(1)); assert.equal(f.calls.length,2);
f.answer(1,state(scene(1),1)); await tick(); const review=f.sync.review(); await tick();
assert.equal(f.calls[2].event,"design-review"); assert.equal(f.calls[2].args.storage_revision,1);
f.answer(2,state(scene(1),2,{ref:"a".repeat(64)})); await tick();
assert.equal(f.calls[3].event,"design-reviewed"); f.answer(3,{scene:scene(1)}); await review;
assert.deepEqual(copy(f.sync.baseline),scene(1)); f.sync.destroy();
''')

    def test_explicit_review_saves_normalized_visible_scene_and_waits_for_ack(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(scene(1),1)); await open;
f.hook.canvas.document=()=>scene(2); f.hook.save=()=>f.sync.save(f.hook.canvas.document());
const review=f.sync.review(); assert.equal(f.calls[1].event,"design-save");
f.answer(1,state(scene(2),2)); await tick(); assert.equal(f.calls[2].event,"design-review");
f.answer(2,state(scene(2),3,{ref:"a".repeat(64)})); await tick(); f.answer(3,{scene:scene(2)}); await review; f.sync.destroy();
''')

    def test_destroyed_hook_ignores_delayed_save_reply(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(null)); await open;
f.sync.save(scene(1)); f.sync.destroy(); const before=f.labels.length;
f.answer(1,state(scene(1),1)); await tick(); assert.equal(f.labels.length,before); assert.equal(f.sync.revision,0);
''')

    def test_drawing_becoming_invalid_during_save_cannot_review_or_prepare_task(self):
        self.run_hook('''
for (const action of ["review", "plan"]) {
  const f=fixture(), open=f.sync.open(null); f.answer(0,state(scene(1),1)); await open;
  f.sync.reviewed={ref:"a".repeat(64)};
  f.hook.canvas.document=()=>scene(2); f.hook.save=()=>f.sync.save(f.hook.canvas.document());
  const operation=action==="review" ? f.sync.review() : f.sync.plan("brief","note");
  assert.equal(f.calls[1].event,"design-save");
  f.hook.canvas.canSave=()=>false; f.answer(1,state(scene(2),2)); await operation;
  assert.equal(f.calls.length,2); assert(f.labels.at(-1).includes("current drawing")); f.sync.destroy();
}
''')

    def test_invalid_project_scene_never_mounts_or_enables_writes(self):
        self.run_hook('''
const f=fixture(), local=scene(2), open=f.sync.open(local);
f.answer(0,state({...scene(3),project:"github:other/project"},7));
assert.deepEqual(copy(await open),local); assert(!f.sync.canWrite()); assert.equal(f.sync.revision,0);
f.sync.save(local); assert.equal(f.calls.length,1); f.sync.destroy();
''')

    def test_unsaveable_visible_scene_cannot_review_or_plan_older_draft(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(null)); await open;
f.sync.reviewed={ref:"a".repeat(64)}; f.hook.canvas.canSave=()=>false;
f.sync.showReview(); await f.sync.review(); await f.sync.plan("brief","note");
assert.equal(f.calls.length,1); assert(f.labels.at(-1).includes("unsaved drawing")); f.sync.destroy();
''')

    def test_failed_browser_save_cannot_review_or_plan_stale_project_scene(self):
        self.run_hook('''
const f=fixture(), open=f.sync.open(null); f.answer(0,state(scene(1),1)); await open;
f.sync.reviewed={ref:"a".repeat(64)}; f.hook.canvas.document=()=>scene(2);
await f.sync.review(); await f.sync.plan("brief","note");
assert.equal(f.calls.length,1); assert(f.labels.at(-1).includes("current drawing")); f.sync.destroy();
''')


if __name__ == "__main__":
    unittest.main()
