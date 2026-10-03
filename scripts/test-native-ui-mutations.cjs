// One-effect mutants must fail their claimed assertions; restore every owned source byte.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),target=path.dirname(path.dirname(binary));
const common=spawnSync('git',['rev-parse','--path-format=absolute','--git-common-dir'],{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(common.status,0);
const evidence=path.join(common.stdout.trim(),'wa-native-mutations',crypto.randomUUID());fs.mkdirSync(evidence,{recursive:true});
const report={schema:1,evidence,mutations:[],restored:false};const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function run(name,command,args,expected){const r=spawnSync(command,args,{cwd:repo,env:{...process.env,CARGO_BUILD_JOBS:'2'},encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:16000000});
 const output=(r.stdout||'')+(r.stderr||'');fs.writeFileSync(path.join(evidence,name+'.log'),output);
 assert.ok(r.status!==0&&r.status!==null&&!r.error,'mutant must exit with assertion failure: '+name);
 assert.ok(output.includes(expected),'mutant failed outside relevant assertion: '+name+'\n'+output.slice(-1500));
 report.mutations.push({name,exit:r.status,assertion:expected,log:path.join(evidence,name+'.log')});return output;
}
function build(){const r=spawnSync('cargo',['build','--offline','--manifest-path','rust/Cargo.toml','-p','wa-host','--target-dir',target],{cwd:repo,env:{...process.env,CARGO_BUILD_JOBS:'2'},encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);}
function mutateRust(name,file,from,to,command,args,assertion){const absolute=path.join(repo,file),original=fs.readFileSync(absolute),text=original.toString();assert.ok(text.includes(from),name+' anchor');
 const mutant=Buffer.from(text.replace(from,to));fs.writeFileSync(absolute,mutant);
 try{build();run(name,command,args,assertion);}finally{assert.equal(hash(fs.readFileSync(absolute)),hash(mutant),'foreign edit during owned mutant');fs.writeFileSync(absolute,original);}
}
try{
 for(const name of ['native-tail-page-only','six-pane-overflow']) {
  const stage=fs.mkdtempSync(path.join(os.tmpdir(),'wa-native-mutant-'));fs.cpSync(path.join(repo,'ui'),stage,{recursive:true});
  if(name==='native-tail-page-only'){
   const file=path.join(stage,'app.js'),text=fs.readFileSync(file,'utf8'),start=text.indexOf('async function attachNativeJournal('),end=text.indexOf('async function syncNativeSession(',start);
   const fragment=text.slice(start,end);assert.ok(fragment.includes('if(!page.has_more)break;'));
   fs.writeFileSync(file,text.slice(0,start)+fragment.replace('if(!page.has_more)break;','if(true)break;')+text.slice(end));
  }else{const file=path.join(stage,'style.css'),text=fs.readFileSync(file,'utf8');assert.ok(text.includes('.orchestrator-canvas[data-count="5"]'));
   fs.writeFileSync(file,text.replace(/^\.orchestrator-canvas\[data-count="5"\].*\n/m,''));}
  const output=run(name,process.execPath,['scripts/test-native-child-browser.cjs',binary,'--ui-root',stage],name==='native-tail-page-only'?'native pane consumes all journal pages exactly once':'six genuine native panes contained in viewport grid');
  const receipt=output.match(/evidence: ([^\r\n]+)/);assert.ok(receipt,'mutant cleanup receipt');const proof=JSON.parse(fs.readFileSync(receipt[1]));
  assert.ok(proof.cleanup.fixture_home_removed&&proof.cleanup.ownedPids.every(p=>p.exited&&p.job?.drained&&p.job.accounting.active_processes===0),'mutant process/Job drain');
  assert.ok(path.resolve(stage).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(stage).startsWith('wa-native-mutant-'));fs.rmSync(stage,{recursive:true,force:true});
 }
 mutateRust('native-owner-bypass','rust/wa-host/src/subagents.rs','if owner != task.owner_user {','if false && owner != task.owner_user {',process.execPath,['scripts/test-native-child-browser.cjs',binary],'native refuses foreign owner before evidence');
 mutateRust('native-checkpoint-replay','rust/wa-host/src/subagents/journal.rs','let start = if archive { after } else { after.max(checkpoint) };','let start = after;',
  'cargo',['test','--offline','--manifest-path','rust/Cargo.toml','-p','wa-host','--target-dir',target,'subagents::journal::tests::indexed_pages_preserve_raw_content_and_checkpoint_after_reopen','--','--test-threads=2'],'indexed_pages_preserve_raw_content_and_checkpoint_after_reopen ... FAILED');
 report.restored=true;
}finally{build();fs.writeFileSync(path.join(evidence,'report.json'),JSON.stringify(report,null,2)+'\n');console.log('mutation evidence: '+path.join(evidence,'report.json'));}
assert.equal(report.mutations.length,4);assert.ok(report.restored);console.log('native mutations ok (4 intended assertion failures; source restored)');console.log('ALL PASS');
