// Isolated UI copies only; each causal mutant must fail its existing actual browser assertion.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'../..'),binary=path.resolve(process.argv[2]);
const results=[];
for(const [name,from,to,expected] of [
 ['main-epoch','epoch===conversationEpoch','true','late native main response cannot cross conversation epoch'],
 ['main-owner','credential===session','true','late native main response cannot cross owner credential'],
 ['main-node','node===activeNode','true','late native main response cannot cross active node']
]) {
 const stage=fs.mkdtempSync(path.join(os.tmpdir(),'wa-review-native-mutant-'));
 fs.cpSync(path.join(repo,'ui'),stage,{recursive:true});
 const file=path.join(stage,'app.js'),text=fs.readFileSync(file,'utf8'),start=text.indexOf('async function syncNativeSession('),end=text.indexOf('// Projection addresses',start);
 const fragment=text.slice(start,end);assert.ok(fragment.includes(from));
 fs.writeFileSync(file,text.slice(0,start)+fragment.replace(from,to)+text.slice(end));
 const run=spawnSync(process.execPath,['scripts/test-native-child-browser.cjs',binary,'--ui-root',stage],{cwd:repo,encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:16000000});
 const output=(run.stdout||'')+(run.stderr||'');fs.writeFileSync(path.join(__dirname,name+'.log'),output);
 const receipt=output.match(/evidence: ([^\r\n]+)/);assert.ok(receipt,output);
 const raw=JSON.parse(fs.readFileSync(receipt[1]));
 assert.ok(raw.cleanup.fixture_home_removed&&raw.cleanup.ownedPids.every(p=>p.exited&&p.job.no_breakaway&&p.job.drained&&p.job.accounting.active_processes===0));
 results.push({name,exit:run.status,expected,actualError:raw.error,assertionFailed:run.status===1&&output.includes(expected),receipt:receipt[1],stagedSha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')});
 assert.ok(path.resolve(stage).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(stage).startsWith('wa-review-native-mutant-'));fs.rmSync(stage,{recursive:true,force:true});
}
fs.writeFileSync(path.join(__dirname,'guard-mutations.json'),JSON.stringify(results,null,2)+'\n');
assert.ok(results.every(r=>r.assertionFailed),'causal mutant failed outside expected assertion');
console.log('3 causal native view fence removals fail the relevant assertions; production bytes untouched');
