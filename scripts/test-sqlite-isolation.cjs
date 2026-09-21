// Real HTTP workers + real SQLite, with a test-only Lua handler in a copied source tree.
// One worker's uncommitted row must be invisible to another; rollback cannot erase a peer commit.
// No model, messaging, operator home or installed source is used.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),http=require('node:http');
const assert=require('node:assert/strict'),{spawn}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),wa=path.resolve(process.argv[2]||path.join(repo,'rust/target/release/wa'+(process.platform==='win32'?'.exe':'')));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-sqlite-workers-')),source=path.join(root,'source');
fs.cpSync(path.join(repo,'lua'),path.join(source,'lua'),{recursive:true});
fs.appendFileSync(path.join(source,'lua/core/server.lua'),`
-- Fixture-only override. Never installed or copied to the user's node.
local function tx_exec(sql)
  local value=json.decode(host.sql_exec(sql,"[]"))
  if value.error then error(value.error) end
  return value
end
local function tx_query(sql)
  local value=json.decode(host.sql_query(sql,"[]"))
  if value.error then error(value.error) end
  return value
end
tx_exec("CREATE TABLE IF NOT EXISTS tx_probe(k TEXT PRIMARY KEY)")
local tx_root=host.paths().config
local function tx_wait(name)
  local deadline=host.monotonic_ms()+8000
  while not host.read_file(tx_root.."/"..name) do
    if host.monotonic_ms()>deadline then error("fixture barrier timeout: "..name) end
    host.sleep(10)
  end
end
function wa_reply(body, session, node)
  local request=json.decode(body)
  if request.text=="warm" then host.sleep(250);return json.encode({ok=true}) end
  if request.text=="hold-and-rollback" then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO tx_probe(k) VALUES('A')")
    assert(host.write_file(tx_root.."/A-open","yes"))
    tx_wait("B-read")
    tx_exec("ROLLBACK")
    assert(host.write_file(tx_root.."/A-rolled","yes"))
    return json.encode({rolled_back=true})
  end
  if request.text=="read-and-commit" then
    local rows=tx_query("SELECT count(*) AS n FROM tx_probe WHERE k='A'")
    local visible=(rows[1] or {}).n
    assert(host.write_file(tx_root.."/B-read","yes"))
    tx_wait("A-rolled")
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO tx_probe(k) VALUES('B')")
    tx_exec("COMMIT")
    return json.encode({saw_uncommitted=visible})
  end
  if request.text=="fail-in-transaction" then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO tx_probe(k) VALUES('C')")
    error("intentional fixture transaction failure")
  end
  if request.text=="commit-after-error" then
    tx_exec("BEGIN IMMEDIATE")
    tx_exec("INSERT INTO tx_probe(k) VALUES('D')")
    tx_exec("COMMIT")
    return json.encode({rows=tx_query("SELECT k FROM tx_probe ORDER BY k")})
  end
  if request.text=="read-final" then return json.encode({rows=tx_query("SELECT k FROM tx_probe ORDER BY k")}) end
  error("unknown fixture action")
end
`);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let child,log,checks=0;
(async()=>{try{
 const reserved=http.createServer();await new Promise(r=>reserved.listen(0,'127.0.0.1',r));const port=reserved.address().port;await new Promise(r=>reserved.close(r));
 const system=/^(PATH|PATHEXT|SYSTEMROOT|WINDIR|SYSTEMDRIVE|COMSPEC|TEMP|TMP)$/i;
 const env={...Object.fromEntries(Object.entries(process.env).filter(([key])=>system.test(key))),HOME:root,USERPROFILE:root,LOCALAPPDATA:path.join(root,'LocalAppData'),APPDATA:path.join(root,'AppData'),
  WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:source,WASM_AGENT_RENDEZVOUS:'',WASM_AGENT_RELAY:'',WASM_AGENT_MANAGED:'0',WASM_AGENT_LLM_BASE_URL:'http://127.0.0.1:1',WASM_AGENT_LLM_API_KEY:'fixture-only',WASM_AGENT_LLM_MODEL:'fixture'};
 log=fs.openSync(path.join(root,'node.log'),'a');
 child=spawn(wa,['--db',path.join(root,'.wasm-agent/memory.db'),'serve','--port',String(port),'--client-port','0','--ui',path.join(repo,'ui')],{env,stdio:['ignore',log,log],windowsHide:true});
 child.on('error',e=>console.error(e));const base='http://127.0.0.1:'+port;
 async function until(fn,label){const end=Date.now()+12000;while(Date.now()<end){if(await fn())return;await sleep(20);}throw Error('deadline: '+label);}
 await until(async()=>{try{return(await fetch(base+'/health',{signal:AbortSignal.timeout(500)})).ok;}catch{return false;}},'node ready');
 async function chat(thread,text,allowError=false){const r=await fetch(base+'/chat',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({thread,text}),signal:AbortSignal.timeout(12000)});const value=await r.json();if(!allowError){assert.equal(r.status,200,JSON.stringify(value));assert.ok(!value.error,JSON.stringify(value));}return value;}
 await Promise.all([chat('tx-A','warm'),chat('tx-B','warm')]);checks++;
 const a=chat('tx-A','hold-and-rollback');
 await until(()=>fs.existsSync(path.join(root,'.wasm-agent/A-open')),'A transaction opened');
 const b=chat('tx-B','read-and-commit');
 const [ra,rb]=await Promise.all([a,b]);
 assert.equal(rb.saw_uncommitted,0,'another interpreter must NEVER see an uncommitted row');checks++;
 assert.equal(ra.rolled_back,true);checks++;
 const final=await chat('tx-B','read-final');assert.deepEqual(final.rows,[{k:'B'}],'A rollback must not erase B commit or retain A row');checks++;
 const failed=await chat('tx-A','fail-in-transaction',true);assert.match(failed.error,/intentional fixture transaction failure/);checks++;
 const after=await chat('tx-B','commit-after-error');assert.deepEqual(after.rows,[{k:'B'},{k:'D'}],'Lua error must rollback C and release its write lock');checks++;
 fs.writeFileSync(path.join(root,'verdict.json'),JSON.stringify({suite:'sqlite-worker-isolation',checks,failed:0,skipped:0,ok:true}));
 console.log(`sqlite worker isolation ok (${checks} checks, 0 skipped; real workers, no inference)\nevidence: ${root}`);
}catch(error){fs.writeFileSync(path.join(root,'verdict.json'),JSON.stringify({suite:'sqlite-worker-isolation',checks,failed:1,skipped:0,ok:false,error:String(error)}));console.error(error.stack);console.error('evidence: '+root);process.exitCode=1;
}finally{if(child&&child.exitCode===null){child.kill();await Promise.race([new Promise(r=>child.once('exit',r)),sleep(3000)]);}if(log!==undefined)fs.closeSync(log);}})();
