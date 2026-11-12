// Actual Pi1.2 Responses serializer, deterministic loopback fixture only.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';
assert(process.env.WA_BENCHMARK_MODEL_FREE==='1','paid Pi fixture not admitted');const base=process.env.WA_PI_ROUTE;assert(/^http:\/\/127\.0\.0\.1:\d+\/arms\/[a-f0-9]{64}\/openai-sub$/.test(base),'loopback model route required');
const root=process.env.WA_PI_PACKAGE_ROOT;const manifest=JSON.parse(fs.readFileSync(path.join(root,'package.json')));assert(manifest.name==='@earendil-works/pi-ai'&&manifest.version==='1.2.0','Pi AI pin');
const {getModel}=await import(pathToFileURL(path.join(root,'dist/compat.js')));const {streamSimple}=await import(pathToFileURL(path.join(root,'dist/api/openai-codex-responses.js')));
const declared=getModel('openai-codex','gpt-6.1-sol');assert(declared&&declared.id==='gpt-6.1-sol','exact Pi catalogue model required');const model={...declared,baseUrl:base};
const payload=Buffer.from(JSON.stringify({'https://api.openai.com/auth':{chatgpt_account_id:'MODEL_FREE_ACCOUNT'}})).toString('base64url');const fakeKey='e30.'+payload+'.model-free';
const stream=streamSimple(model,{systemPrompt:'Deterministic serializer fixture; no autonomous task.',messages:[{role:'user',content:'Return the mock fixture text.',timestamp:Date.now()}]}, {apiKey:fakeKey,reasoning:'low',transport:'sse',maxRetries:0,timeoutMs:10000});
const events=[];for await(const event of stream)events.push(event);const result=await stream.result();assert(result.stopReason!=='error'&&result.stopReason!=='aborted',result.errorMessage);assert(result.content.some(x=>x.type==='text'&&x.text==='mock verified final'),'Pi decodes terminal content');
fs.writeFileSync(process.env.WA_PI_RESULT,JSON.stringify({ok:true,checks:2,events,result,paid_solver_calls:0},null,2));console.log(JSON.stringify({ok:true,checks:2,paid_solver_calls:0}));
