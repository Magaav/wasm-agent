// Private native CLI reconciliation boundaries. Labelled owner HTTP + verifier mocks,
// not a production install certificate; live/actual installer tests are separate.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawn,spawnSync}=require('node:child_process');
const binary=path.resolve(process.argv[2]||''),out=path.resolve(process.argv[3]||'');assert(process.argv[2]&&process.argv[3],'binary and fresh evidence required');assert(!fs.existsSync(out));fs.mkdirSync(out,{recursive:true});
const repo=path.join(out,'source'),home=path.join(out,'home'),install=path.join(out,'install');for(const dir of [repo,home,install])fs.mkdirSync(dir);
fs.mkdirSync(repo+'/scripts');fs.writeFileSync(repo+'/scripts/deploy.sh','fixture never execute installer\n');
let valid=true;
const fixture=`import fs from 'node:fs';const [mode,root,install,intent,binding,evidence]=process.argv.slice(2);if(mode!=='verify')throw Error('fixture verify only');const request=JSON.parse(fs.readFileSync(intent));const owner=JSON.parse(fs.readFileSync(binding));if(process.env.REJECT_PROOF==='1'){console.error('private verifier refused');process.exit(1);}console.log(JSON.stringify({ok:true,request_id:request.id,expected_sha:request.expected_sha,owner:owner.owner,parent:owner.parent,at:new Date().toISOString(),labelled_mock:true}));`;
fs.writeFileSync(repo+'/scripts/sentinel-install-proof.mjs',fixture);
function git(args){const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
git(['init','-b','main']);git(['config','core.longpaths','true']);git(['config','user.email','fixture@invalid']);git(['config','user.name','fixture']);git(['add','.']);git(['-c','core.hooksPath=/dev/null','commit','-m','private']);git(['remote','add','origin',repo]);git(['fetch','origin']);
const sha=git(['rev-parse','HEAD']);fs.writeFileSync(install+'/runtime-worktree.txt',repo+'\n');
const state=home+'/.wasm-agent/sentinel',id='private-reconcile',dir=state+'/deploy-protocol/'+id;fs.mkdirSync(dir,{recursive:true});
const intent={id,verb:'deploy',expected_sha:sha,owner:'owner',session:'parent',queued_at:Math.floor(Date.now()/1000)};
const effect={id,expected_sha:sha,tree:git(['rev-parse','HEAD^{tree}']),owner:'owner',parent:'parent',source:repo,script:repo+'/scripts/deploy.sh',script_sha256:crypto.createHash('sha256').update(fs.readFileSync(repo+'/scripts/deploy.sh')).digest('hex'),target_pid:17,target_created:'fixture-generation',watcher_pid:19,at:intent.queued_at,phase:'admitted'};
const cursor={slot:9,next_at:Number.MAX_SAFE_INTEGER,last_event:'original-failed'};
fs.mkdirSync(dir+'/returns');fs.writeFileSync(dir+'/returns/original-failed.json',JSON.stringify({phase:'failed',detail:'original immutable failure'}));
for(const [name,value] of [['intent.json',intent],['effect.json',effect],['result.json',{ok:true}],['state.json',{phase:'failed'}],['observation.json',cursor]])fs.writeFileSync(dir+'/'+name,JSON.stringify(value));
const active=state+'/protocol-effect.json';fs.writeFileSync(active,JSON.stringify(effect));const originalCursor=fs.readFileSync(dir+'/observation.json'),originalReturn=fs.readFileSync(dir+'/returns/original-failed.json');
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
Object.assign(env,{WASM_AGENT_HOME:home,WA_INSTALL_DIR:install,WA_SENTINEL_SUPERVISOR:'none'});
const server=http.createServer((req,res)=>{assert.equal(req.url,'/session/owner?id=parent');res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({session:{id:'parent',user_id:valid?'owner':'wrong'}}));});
let checks=0,sequence=0;
async function cli(extras={}){const command=['protocol','reconcile',id,'--reason','private explicit verification-only recovery'];const p=spawn(binary,command,{cwd:repo,env:{...env,...extras},windowsHide:true});let stdout='',stderr='';p.stdout.on('data',x=>stdout+=x);p.stderr.on('data',x=>stderr+=x);const code=await new Promise((resolve,reject)=>{p.on('error',reject);p.on('close',resolve);});fs.writeFileSync(out+'/'+(++sequence)+'.stdout',stdout);fs.writeFileSync(out+'/'+sequence+'.stderr',stderr);return {code,stdout,stderr};}
function check(value,why){assert(value,why);checks++;}
(async()=>{try{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));env.WASM_AGENT_PORT=String(server.address().port);
 let r=await cli({WASM_AGENT_IN_TURN:'1'});check(r.code!==0&&r.stderr.includes('external_executor'),'in-turn must refuse');check(fs.readFileSync(active,'utf8')===JSON.stringify(effect),'in-turn changed reservation');
 const changed={...effect,target_created:'other'};fs.writeFileSync(active,JSON.stringify(changed));r=await cli();check(r.code!==0&&r.stderr.includes('reservation_mismatch'),'different generation refused');check(fs.readFileSync(active,'utf8')===JSON.stringify(changed),'mismatched reservation changed');fs.writeFileSync(active,JSON.stringify(effect));
 valid=false;r=await cli();check(r.code!==0&&r.stderr.includes('parent_owner_mismatch'),'owner mismatch refused');check(fs.readFileSync(active,'utf8')===JSON.stringify(effect),'owner failure settled');valid=true;
 r=await cli({REJECT_PROOF:'1'});check(r.code!==0&&r.stderr.includes('actual_verification_failed'),'verifier failure refused');check(fs.readFileSync(active,'utf8')===JSON.stringify(effect),'failed verifier settled reservation');
 fs.writeFileSync(repo+'/reject-proof','fixture');git(['add','reject-proof']);git(['-c','core.hooksPath=/dev/null','commit','-m','reject-control']); // actual source drift refuses before mock verification
 r=await cli();check(r.code!==0&&r.stderr.includes('exact expected'),'source drift refused');check(fs.readFileSync(active,'utf8')===JSON.stringify(effect),'source refusal settled');
 git(['reset','--hard',sha]);git(['fetch','origin']);
 r=await cli();check(r.code===0,r.stderr);const proof=JSON.parse(r.stdout);check(proof.ok&&proof.reservation==='verified'&&proof.effect_replayed===false,'positive CLI verdict');check(JSON.parse(fs.readFileSync(active)).phase==='verified','reservation did not settle');
 check(fs.readFileSync(dir+'/observation.json').equals(originalCursor)&&fs.readFileSync(dir+'/returns/original-failed.json').equals(originalReturn),'original terminal evidence changed');
 check(!fs.existsSync(state+'/requests')||fs.readdirSync(state+'/requests').length===0,'reconcile queued an effect');
 r=await cli();check(r.code===0&&JSON.parse(r.stdout).effect_replayed===false,'repeat verification failed');
 const generations=fs.readdirSync(dir+'/reconciliations');check(generations.length>=3,'original recovery evidence missing');
 const receipt={ok:true,checks,skipped:0,labelled_mocks:['owner HTTP','verifier response'],live_effects:false,evidence:out};fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}})().catch(error=>{console.error(error);process.exitCode=1;});
