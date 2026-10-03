// Causal raw-endpoint binding mutation at the hash boundary, private state only.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]);
const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-binding-negative-'));
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
for(const embedded of [false,true]) {
 const home=path.join(work,embedded?'embedded':'source');fs.mkdirSync(home);
 const original=fs.readFileSync(path.join(root,'scripts/test-provider-serving.lua'),'utf8');
 const script=path.join(home,'negative.lua');
 fs.writeFileSync(script,original.replace("local p=dofile('lua/core/provider.lua')",`local real_hash=host.sha256
host.sha256=function(text)
 local ok,v=pcall(json.decode,text)
 if ok and type(v)=='table' and #v==3 and v[2]=='opencode-go' then
   return real_hash(json.encode({v[1],v[2],host.getenv('WASM_AGENT_LLM_BASE_URL'),v[3]}))
 end
 return real_hash(text)
end
local p=dofile('lua/core/provider.lua')`));
 const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:script};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
 const r=spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:work,env,encoding:'utf8',timeout:60000});
 fs.writeFileSync(path.join(home,'result.log'),r.stdout+'\n'+r.stderr);
 assert.notEqual(r.status,0);assert.match(r.stderr,/endpoint spelling cannot reset account block/);
 console.log(`${embedded?'embedded':'source'} raw-binding mutation rejected; evidence ${home}`);
}
