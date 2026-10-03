const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {spawn,spawnSync}=require('node:child_process'),{once}=require('node:events');
const binary=path.resolve(process.argv[2]),expectBypass=process.argv[3]==='--expect-bypass',source=path.resolve(__dirname,'..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-target-alias-'));
const children=[];const git=(...args)=>{const r=spawnSync('git',['--git-dir',path.join(root,'git'),...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
git('init','--bare');const tree=git('mktree'),commit=git('-c','user.name=Fixture','-c','user.email=fixture@invalid','commit-tree',tree,'-m','private alias');
git('update-ref','refs/heads/main',commit);git('symbolic-ref','refs/heads/alias','refs/heads/main');
assert.equal(git('rev-parse','refs/heads/alias'),git('rev-parse','refs/heads/main'));
if(process.platform==='win32')assert.equal(git('rev-parse','refs/heads/Main'),git('rev-parse','refs/heads/main'));
function start(name,ref){const env={...process.env};for(const k of Object.keys(env))if(/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(k))delete env[k];
 Object.assign(env,{WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:source,WA_SCRIPT:path.join(source,'scripts/test-native-target-alias.lua'),WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',WA_ALIAS_ROOT:root,WA_ALIAS_NAME:name,WA_ALIAS_REF:ref});
 const log=fs.openSync(path.join(root,name+'.log'),'w'),p=spawn(binary,['--db',path.join(root,name+'.db')],{cwd:source,env,stdio:['ignore',log,log],windowsHide:true});fs.closeSync(log);children.push(p);return p;}
async function ready(name){for(let i=0;i<150;i++){try{return JSON.parse(fs.readFileSync(path.join(root,name+'.json')));}catch{}await new Promise(r=>setTimeout(r,50));}throw Error('owner readiness missing: '+name);}
(async()=>{try{
 start('upper','refs/heads/Main');const first=await ready('upper');assert.equal(first.hold.ok,true);
 start('lower','refs/heads/main');const second=await ready('lower');start('symbolic','refs/heads/alias');const symbolic=await ready('symbolic');
 if(expectBypass){assert.equal(second.hold.ok,true);assert.equal(symbolic.hold.ok,true);assert.notEqual(first.hold.receipt.key,second.hold.receipt.key);}
 else {assert.equal(first.hold.receipt.exclusion_scope,'git-common-directory');for(const result of [second,symbolic]){assert.equal(result.hold.ok,false);assert.equal(result.hold.error,'target_lease_held_or_unavailable');assert.equal(result.inspection.admissible,false);assert.equal(result.inspection.conflicts[0].reason,'target_owned');}}
 const report={kind:'actual-native-common-directory-alias-test',expect_bypass:expectBypass,root,binary_sha256:crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),actual_symbolic_alias:true,actual_windows_case_alias:process.platform==='win32',first,second,symbolic};
 fs.writeFileSync(path.join(root,'report.json'),JSON.stringify(report,null,2)+'\n');
 fs.writeFileSync(path.join(root,'release'),'done');await Promise.all(children.map(p=>p.exitCode===null?once(p,'exit'):Promise.resolve()));
 for(const child of children)assert.equal(child.exitCode,0);
 console.log(`native target alias ${expectBypass?'baseline bypass reproduced':'exclusion ok'} (12 checks, 0 skipped; two live owners, actual Git aliases)`);
 }catch(error){console.error(error.stack);process.exitCode=1;}finally{for(const child of children)if(child.exitCode===null&&child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}console.log('evidence: '+root);}})();
