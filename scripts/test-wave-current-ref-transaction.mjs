// Mechanical proof for a separately proposed opt-in contract. This is NOT a
// native target admission or a production source-authority adapter.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';import {once} from 'node:events';import {DatabaseSync} from 'node:sqlite';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-current-ref-proof-')),repo=path.join(root,'repo');fs.mkdirSync(repo);let checks=0,child;
const git=(...args)=>{const r=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const check=(v,s)=>{assert.ok(v,s);checks++;};
git('init','-q','-b','main');git('config','core.autocrlf','false');git('config','user.name','Private Fixture');git('config','user.email','fixture@invalid');fs.writeFileSync(path.join(repo,'source.txt'),'old\n');git('add','.');git('commit','-qm','private base');const before=git('rev-parse','HEAD');
fs.writeFileSync(path.join(repo,'source.txt'),'new\n');git('add','.');const tree=git('write-tree');git('restore','--source=HEAD','--staged','--worktree','.');const next=git('commit-tree',tree,'-p',before,'-m','private source-only candidate');git('symbolic-ref','refs/heads/source-alias','refs/heads/main');
const legacy=new DatabaseSync(path.join(root,'legacy.sqlite'));legacy.exec('CREATE TABLE claims(key TEXT,principal TEXT,session TEXT,run TEXT,boot TEXT,uncertain INTEGER)');legacy.prepare('INSERT INTO claims VALUES(?,?,?,?,?,?)').run('session:33b4-fixture','old-actor','33b4-fixture','unknown-run','unknown-boot',1);const original=legacy.prepare('SELECT * FROM claims').all();
const publicationFile=path.join(git('rev-parse','--path-format=absolute','--git-common-dir'),'wa-waves','recovery-target-lease.sqlite');fs.mkdirSync(path.dirname(publicationFile),{recursive:true});
const publication=new DatabaseSync(publicationFile);publication.exec('CREATE TABLE lease(id INTEGER PRIMARY KEY);BEGIN IMMEDIATE');
let output='';
async function waitFor(text){for(let n=0;n<500;n++){if(output.includes(text))return;if(child.exitCode!==null)throw Error('Git transaction exited early: '+output);await new Promise(r=>setTimeout(r,10));}throw Error('Git transaction acknowledgement missing: '+text);}
try{
 child=spawn('git',['-C',repo,'update-ref','--stdin'],{stdio:['pipe','pipe','pipe'],windowsHide:true});child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 child.stdin.write(`start\nupdate refs/heads/main ${next} ${before}\nprepare\n`);await waitFor('prepare: ok');
 check(git('rev-parse','main')===before,'prepare retains expected main');
 for(const ref of ['refs/heads/main','refs/heads/source-alias',...(process.platform==='win32'?['refs/heads/Main']:[])]){
  const contender=spawnSync('git',['-C',repo,'update-ref',ref,next,before],{encoding:'utf8',windowsHide:true});check(contender.status!==0&&/lock|locked/.test(contender.stderr),'ordinary Git writer/alias refused while prepared');
 }
 const second=new DatabaseSync(publicationFile);try{assert.throws(()=>second.exec('BEGIN IMMEDIATE'),/locked|busy/);checks++;}finally{second.close();}
 // No old effect is replayed, no old record is retired or reclassified.
 assert.deepEqual(legacy.prepare('SELECT * FROM claims').all(),original);checks++;
 child.stdin.write('commit\n');child.stdin.end();await once(child,'exit');check(child.exitCode===0,'prepared transaction commits once');
 check(git('rev-parse','main')===next,'exact current ref CAS readback');git('read-tree','-u','-m',before,next);
 check(git('status','--porcelain')===''&&fs.readFileSync(path.join(repo,'source.txt'),'utf8')==='new\n','canonical synchronization and content readback');
 assert.deepEqual(legacy.prepare('SELECT * FROM claims').all(),original);checks++;
 fs.writeFileSync(path.join(root,'report.json'),JSON.stringify({kind:'private-proposed-current-ref-exclusion',before,next,tree,checks,skipped:0,git_prepared_exclusion:true,publication_lease_held:true,legacy_originals_preserved:true,global_identity_safety:false,native_target_admission:false,production_authority:false,activation:false,limit:'ordinary Git lock protocol only; arbitrary filesystem/SQL writers and historical effects are not adjudicated'},null,2)+'\n');
 console.log(`current ref transaction proof ok (${checks} checks, 0 skipped; ordinary Git aliases excluded, old unknown claim retained)`);
}catch(e){console.error(e.stack);process.exitCode=1;}finally{if(child&&child.exitCode===null){const exit=once(child,'exit');child.kill();await exit;}publication.exec('ROLLBACK');publication.close();legacy.close();console.log('evidence: '+root);}
