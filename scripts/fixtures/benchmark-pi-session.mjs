// Full Pi1.2 coding-agent/tool loop, driven only by deterministic loopback SSE.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';
assert(process.env.WA_BENCHMARK_MODEL_FREE==='1','paid Pi session not admitted');const base=process.env.WA_PI_ROUTE;assert(/^http:\/\/127\.0\.0\.1:\d+\/arms\/[a-f0-9]{64}\/openai-sub$/.test(base),'private mock route required');
const fetchOriginal=globalThis.fetch;globalThis.fetch=(input,options)=>{const url=typeof input==='string'?input:input.url??String(input);assert(url.startsWith(base+'/'),'model-free Pi external network refused');return fetchOriginal(input,options);};
const root=process.env.WA_PI_AGENT_PACKAGE;const pkg=JSON.parse(fs.readFileSync(path.join(root,'package.json')));assert(pkg.version==='1.2.0','Pi version pin');
const sdk=await import(pathToFileURL(path.join(root,'dist/index.js')));
const home=process.env.WASM_AGENT_HOME;const agentDir=path.join(home,'agent');fs.mkdirSync(agentDir,{recursive:true});
const payload=Buffer.from(JSON.stringify({'https://api.openai.com/auth':{chatgpt_account_id:'MODEL_FREE_ACCOUNT'}})).toString('base64url');const fakeAccess='e30.'+payload+'.model-free';
fs.writeFileSync(path.join(agentDir,'auth.json'),JSON.stringify({'openai-codex':{type:'oauth',access:fakeAccess,refresh:'MODEL_FREE_NEVER_REFRESH',expires:Date.now()+3600000}}));
const runtime=await sdk.ModelRuntime.create({authPath:path.join(agentDir,'auth.json'),modelsPath:null,modelsStorePath:path.join(agentDir,'models-store.json'),allowModelNetwork:false,refreshOnCreate:false});
runtime.registerProvider('openai-codex',{baseUrl:base});
const model=runtime.getModel('openai-codex','gpt-6.1-sol');assert(model&&model.id==='gpt-6.1-sol','same exact model');
// Equalize transport, not tools/agent policy. The fixture cannot reach a live host.
const original=runtime.streamSimple.bind(runtime);runtime.streamSimple=(m,c,o)=>original(m,c,{...o,transport:'sse',maxRetries:0});
const {session}=await sdk.createAgentSession({cwd:home,agentDir,modelRuntime:runtime,model,thinkingLevel:'low',sessionManager:sdk.SessionManager.inMemory(home),settingsManager:sdk.SettingsManager.inMemory({})});
const events=[];const unsubscribe=session.subscribe(e=>events.push(e));
try{await session.prompt('Model-free fixture: read '+process.env.WA_PI_INPUT+'; do not perform other work.');const state=session.agent.state;assert(state.messages.some(m=>m.role==='toolResult'&&JSON.stringify(m).includes('private-alpha')),'Pi runs its real read tool');assert(state.messages.some(m=>m.role==='assistant'&&m.content.some(c=>c.type==='text'&&c.text==='mock verified final')),'Pi completes the second mock turn');fs.writeFileSync(process.env.WA_PI_RESULT,JSON.stringify({ok:true,checks:2,events,messages:state.messages,paid_solver_calls:0},null,2));console.log(JSON.stringify({ok:true,checks:2,paid_solver_calls:0}));}
finally{unsubscribe();session.dispose();}
