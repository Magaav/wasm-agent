// Independent review fixture; no product edits. Inputs are immutable exported source and its binary.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawnSync}=require('node:child_process');
const [root,binary,out]=process.argv.slice(2);const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-review-serving-'));
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
const original=fs.readFileSync(path.join(root,'scripts/test-provider-serving.lua'),'utf8');
const prefix=original.slice(0,original.indexOf('local mode='));
const attacks=prefix+`
assert(not pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}))
assert(p.serving('fixture').state=='blocked')
local binding=p.serving_binding()
local env_before=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_LLM_BASE_URL' then return 'http://127.0.0.1:1/private-mock/' end return env_before(k) end
print('EXPLOIT equivalent normalized endpoint changes binding: '..p.serving('fixture').state)
assert(p.serving('fixture').state=='unknown')
host.getenv=env_before
host.sql_exec("UPDATE provider_serving SET state='corrupted' WHERE binding=?",json.encode({binding}))
print('EXPLOIT corrupted persisted state eligibility: '..tostring(p.unservable('fixture')))
assert(p.unservable('fixture')==nil)
outcome={status=200,body=json.encode({model='wrong-model',choices={{message={content='wrong model answer'},finish_reason='stop'}}})}
local previous_http=host.http
host.http=function(...) host.sql_exec("UPDATE provider_serving SET state='blocked' WHERE binding=?",json.encode({binding}));return previous_http(...) end
assert(pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}))
assert(p.serving('fixture').state=='observed_serving')
print('EXPLOIT wrong response model recorded as bound serving success')
local real_dofile=dofile
local status={serving={state='blocked',binding='different-account',model='different-model',node_id='different-node'}}
dofile=function(path)
 if path=='lua/core/nodes.lua' then return {remote_call=function() return status end} end
 return real_dofile(path)
end
local o=real_dofile('lua/core/orchestrator.lua')
assert(o.serving_eligible('authenticated-peer','fixture')==false)
print('EXPLOIT unrelated peer account/model/node serving metadata blocks placement')
status={};assert(o.serving_eligible('authenticated-peer','fixture')==true)
print('ok absent peer metadata stays compatible unknown')
`;
function run(name,lua,embedded=false){const home=path.join(work,name);fs.mkdirSync(home);const script=path.join(home,'fixture.lua');fs.writeFileSync(script,lua);const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:script};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;const r=spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:work,env,encoding:'utf8',timeout:60000});fs.writeFileSync(path.join(out,name+'.log'),r.stdout+'\nSTDERR\n'+r.stderr);return {name,status:r.status,signal:r.signal};}
const results=[run('attacks-source',attacks),run('attacks-embedded',attacks,true)];
// Causal guard removal at the fixture boundary; immutable product source stays unchanged.
results.push(run('causal-outcome-removal',original.replace('host.http=function() calls=calls+1; return json.encode(outcome) end',"host.http=function() calls=calls+1; local v=json.decode(json.encode(outcome)); if v.status==429 then v.status=500 end; return json.encode(v) end")));
results.push(run('causal-eligibility-removal',original.replace("local o=real_dofile('lua/core/orchestrator.lua')","local o=real_dofile('lua/core/orchestrator.lua');o.serving_eligible=function() return true,'unknown' end")));
fs.writeFileSync(path.join(out,'attack-results.json'),JSON.stringify({work,results},null,2));console.log(JSON.stringify(results));
if(results[0].status!==0||results[1].status!==0||results[2].status===0||results[3].status===0)process.exitCode=1;
