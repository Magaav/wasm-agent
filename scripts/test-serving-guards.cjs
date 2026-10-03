// Causal removals at owned runtime seams; product source/binary remain immutable.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-serving-guards-')));fs.mkdirSync(out,{recursive:true});
const original=fs.readFileSync(path.join(root,'scripts/test-provider-serving.lua'),'utf8');
const prefix=original.slice(0,original.indexOf('local mode=')),contract=fs.readFileSync(path.join(root,'scripts/test-serving-contract.lua'),'utf8');
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
const variants=[
 ['outcome',prefix+`host.http=function() calls=calls+1;return json.encode({status=500,body=outcome.body}) end\n`+contract,/real structured monthly seam block/],
 ['validation',prefix+`p.serving=function(model,provider)
 local rows=json.decode(host.sql_query('SELECT state,reason,model,generation FROM provider_serving WHERE binding=?',json.encode({p.serving_binding()})))
 return rows[1] or {state='unknown'}
end\n`+contract,/invalid persisted eligibility fails closed/],
 ['response-model',prefix+`local native_http=host.http
host.http=function(...) local value=json.decode(native_http(...));if value.status==200 then local payload=json.decode(value.body);payload.model='fixture';value.body=json.encode(payload) end return json.encode(value) end\n`+contract,/wrong model cannot certify serving/],
 ['cas',prefix+`local native_exec=host.sql_exec
host.sql_exec=function(statement,values)
 if statement:find("SET state='observed_serving'",1,true) then
  statement=statement:gsub(' AND generation=%? AND state=%? AND reason=%? AND model=%?','')
  local params=json.decode(values);values=json.encode({params[1],params[2]})
 end
 return native_exec(statement,values)
end\n`+contract,/stale correctly modeled success cannot clear newer block/],
 ['tuple',prefix+contract.replace("local o=real_dofile('lua/core/orchestrator.lua')",`local o=real_dofile('lua/core/orchestrator.lua')
o.serving_eligible=function(destination,model,provider)
 local value=first.serving_identity and second.serving
 if value and value.state=='blocked' then return false,'provider_monthly_quota' end
 return true,'unknown'
end`),/foreign second-phase node_id cannot block requested route/],
 ['placement',original.replace("local o=real_dofile('lua/core/orchestrator.lua')","local o=real_dofile('lua/core/orchestrator.lua');o.serving_eligible=function() return true,'unknown' end"),/monthly blocked healthy peer skipped/]
];
for(const embedded of [false,true])for(const [guard,lua,expected] of variants){
 const name=(embedded?'embedded':'source')+'-'+guard,home=path.join(out,name);fs.mkdirSync(home,{recursive:true});
 const fixture=path.join(home,'fixture.lua');fs.writeFileSync(fixture,lua);const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:fixture};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
 const result=spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:out,env,encoding:'utf8',timeout:60000,windowsHide:true});
 fs.writeFileSync(path.join(home,'raw.log'),result.stdout+'\nSTDERR\n'+result.stderr);
 assert.notEqual(result.status,0,name+' must fail');assert.match(result.stderr,expected,name+' must fail at causal assertion');console.log(name+' rejected at '+expected.source);
}
console.log('12 causal guard removals rejected in source and embedded; 0 skips, 0 paid calls; '+out);
