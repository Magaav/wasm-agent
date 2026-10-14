import {test} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import {spawnSync} from 'node:child_process';
import {createGeneration,record,requiredRecords,seal,verifyBundle,cleanup,dockerResource,cleanupDocker} from './agent-benchmark-results.mjs';import {realDockerAdapter} from './agent-benchmark-docker.mjs';
const out=process.env.WA_BENCHMARK_DOCKER_ROOT;assert(out&&path.isAbsolute(out));fs.mkdirSync(out);
test('actual hermetic Docker container/network/volume drain, seal and exact cleanup without shared-image deletion',()=>{
 const root=path.join(out,'g');createGeneration(root,'docker-model-free');for(const k of requiredRecords)record(root,k,{id:k,measurement:'model-free Docker proof',benchmark_solver_inference:0});
 const pinned=spawnSync('docker',['image','inspect','node:22-bookworm'],{encoding:'utf8',timeout:15000});assert.equal(pinned.status,0,pinned.stderr);const imageId=JSON.parse(pinned.stdout)[0].Id;
 const a=realDockerAdapter(root,{imageId,command:['node','-e','console.log("hermetic process");setInterval(()=>{},1000)']});
 const container=dockerResource(root,'container',a),network=dockerResource(root,'network',a),volume=dockerResource(root,'volume',a);
 a.start(container);assert.equal(a.inspect(container).running,true);assert.throws(()=>seal(root),/live/);assert.throws(()=>cleanup(root),/sealed/);
 a.stop(container);assert.equal(a.inspect(container).running,false);seal(root);const bundle=verifyBundle(root);assert.equal(bundle.lossless,true);
 const r=cleanupDocker(root,a);assert.equal(r.length,3);for(const id of [container,network,volume])assert.equal(a.inspect(id).absent,true);
 assert.equal(cleanup(root).ok,true);const retained=spawnSync('docker',['image','inspect',imageId],{encoding:'utf8',timeout:15000});assert.equal(retained.status,0,'shared cached image must remain');
 fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({ok:true,bundle,removed:[container,network,volume],imageId,shared_image_preserved:true,real_solver_calls:0,real_provider_calls:0},null,2));
});
