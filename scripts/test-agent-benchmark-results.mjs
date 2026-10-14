import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {createGeneration,record,disposable,seal,verifyBundle,cleanup,cleanupDocker,dockerResource,reconcileDocker,reconcileFilesystem,registerSnapshotGit,requiredRecords,ownedProcess,containedProcess} from './agent-benchmark-results.mjs';
const evidence=process.env.WA_BENCHMARK_TEST_ROOT;
assert(evidence && path.isAbsolute(evidence),'explicit fresh evidence root required');fs.mkdirSync(evidence);
let n=0;
function fresh() {const root=path.join(evidence,'g'+(++n));createGeneration(root,'g'+n);return root;}
function records(root) {for(const k of requiredRecords)record(root,k,{id:k,raw:'lossless\n😀\u0000',failed_attempts:[],unknown:null});}
test('real lossless gzip bundle preserves bytes and removes only owned disposables after verification',()=>{
 const root=fresh();records(root);const work=disposable(root,'temp-build');fs.writeFileSync(path.join(work,'output'),Buffer.from([0,255,13,10]));
 const receipt=seal(root);assert.equal(receipt.entries,13);assert.equal(verifyBundle(root).sha256,receipt.sha256);
 const c=cleanup(root);assert(c.ok);assert(!fs.existsSync(work));assert(fs.existsSync(path.join(root,'results.json.gz')));assert(!fs.existsSync(path.join(root,'records')));assert.deepEqual(cleanup(root),c);
});
test('archive corruption and missing records refuse before deletion',()=>{
 const missing=fresh();record(missing,'manifest',{});const work=disposable(missing,'build');assert.throws(()=>seal(missing),/missing/);assert(fs.existsSync(work));
 const corrupt=fresh();records(corrupt);const other=disposable(corrupt,'home');seal(corrupt);fs.appendFileSync(path.join(corrupt,'results.json.gz'),'corruption');assert.throws(()=>cleanup(corrupt),/corruption/);assert(fs.existsSync(other));
});
test('junction, symlink and hardlinked files refuse without deleting targets',()=>{
 const root=fresh();records(root);const work=disposable(root,'home');const shared=path.join(evidence,'shared');fs.mkdirSync(shared);fs.writeFileSync(path.join(shared,'keep'),'unrelated');
 fs.symlinkSync(shared,path.join(work,'escape'),process.platform==='win32'?'junction':'dir');assert.throws(()=>seal(root),/symlink|linked/);assert.equal(fs.readFileSync(path.join(shared,'keep'),'utf8'),'unrelated');
 const linked=fresh();records(linked);const dir=disposable(linked,'build');fs.linkSync(path.join(shared,'keep'),path.join(dir,'hardlink'));assert.throws(()=>seal(linked),/linked/);
});
test('unregistered shared directories, changed marker and escape resource refuse',()=>{
 const root=fresh();records(root);disposable(root,'build');fs.mkdirSync(path.join(root,'disposable','foreign'));seal(root);assert.throws(()=>cleanup(root),/unregistered/);
 const changed=fresh();records(changed);const dir=disposable(changed,'build');seal(changed);fs.writeFileSync(path.join(dir,'.benchmark-owned.json'),'{}');assert.throws(()=>cleanup(changed),/ownership/);
 assert.throws(()=>disposable(fresh(),'../escape'),/invalid/);
});
test('live and merely-exited processes cannot authorize cleanup',async()=>{
 const root=fresh();records(root);const work=disposable(root,'home');
 const pending=ownedProcess(root,process.execPath,['-e','setTimeout(()=>{},400)']);
 assert.throws(()=>seal(root),/live|uncertain/);assert.throws(()=>cleanup(root),/sealed/);await pending;assert.throws(()=>seal(root),/uncertain/);assert(fs.existsSync(work));
});
test('crash/unknown deletion phase is not replayed and original record drift refuses',()=>{
 const root=fresh();records(root);const work=disposable(root,'build');seal(root);
 const p=path.join(root,'owner.json'),s=JSON.parse(fs.readFileSync(p));s.phase='cleaning';fs.writeFileSync(p,JSON.stringify(s));assert.throws(()=>cleanup(root),/crash|uncertain/);assert(fs.existsSync(work));const observation=reconcileFilesystem(root);assert.equal(observation.effects_replayed,false);assert.equal(observation.resources[0].ownership,'exact-owned');assert.equal(observation.finished_clean,false);
 const drift=fresh();records(drift);seal(drift);fs.writeFileSync(path.join(drift,'records','traces.json'),'changed');assert.throws(()=>cleanup(drift),/drift/);
});
test('Docker mocked effects require exact owner/drain and journal uncertainty without replay',()=>{
 const root=fresh();records(root);let removed=0,x;
 const adapter={create:labels=>{x={id:'owned',...labels,shared:false,running:false,effects:'settled'};return {id:x.id};},inspect:()=>({...x}),remove:()=>{removed++;return {settled:true};}};
 dockerResource(root,'container',adapter);seal(root);assert.equal(cleanupDocker(root,adapter).length,1);assert.equal(cleanupDocker(root,adapter).length,0);assert.equal(removed,1);
 const other=fresh();records(other);dockerResource(other,'container',adapter);seal(other);
 for(const field of ['shared','running'])assert.throws(()=>cleanupDocker(other,{...adapter,inspect:()=>({...x,[field]:true})}),/refusal/);
 assert.throws(()=>cleanupDocker(other,{...adapter,inspect:()=>({...x,owner_nonce:'foreign'})}),/refusal/);
 assert.throws(()=>cleanupDocker(other,{...adapter,remove:()=>{removed++;return {settled:false};}}),/uncertain/);
 assert.throws(()=>cleanupDocker(other,adapter),/never replay/);assert.equal(removed,2);assert.throws(()=>cleanup(other),/outstanding/);
 const reconciled=reconcileDocker(other,{...adapter,inspect:()=>({id:'owned',absent:true})});assert.equal(reconciled.effects_replayed,false);assert.equal(reconciled.unresolved.length,0);assert.equal(removed,2);
});
test('only generation-owned standalone snapshot Git checkouts can be removed',()=>{
 const root=fresh();records(root);const dir=disposable(root,'checkout');const r=spawnSync('git',['init','-q',dir],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);registerSnapshotGit(root,dir);seal(root);assert.equal(cleanup(root).ok,true);assert(!fs.existsSync(dir));
 const linked=fresh();records(linked);const p=disposable(linked,'linked');fs.writeFileSync(path.join(p,'.git'),'gitdir: '+process.cwd());assert.throws(()=>registerSnapshotGit(linked,p),/worktree/);
 const shared=fresh();records(shared);const q=disposable(shared,'shared');assert.equal(spawnSync('git',['init','-q',q]).status,0);fs.writeFileSync(path.join(q,'.git','objects','info','alternates'),process.cwd());assert.throws(()=>registerSnapshotGit(shared,q),/shared/);
 assert.throws(()=>registerSnapshotGit(shared,process.cwd()),/owned/);
});
test('actual native supervised process tree drains before successful FS cleanup',async()=>{
 const binary=process.env.WA_BENCHMARK_BINARY;assert(binary,'explicit native binary required');
 const root=fresh();records(root);const work=disposable(root,'build');
 const r=await containedProcess(root,binary,process.execPath,['-e',"require('child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});console.log('owned descendant')"],{cwd:work,luaRoot:process.cwd(),timeout_seconds:3});
 assert.equal(r.settled,true);assert.equal(r.output_streams_closed,true);seal(root);assert.equal(cleanup(root).ok,true);assert(!fs.existsSync(work));
});
