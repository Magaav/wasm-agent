// Each mutation is confined to a private copied UI/Lua root; shipped bytes are untouched.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'../..'),binary=path.resolve(process.argv[2]),results=[];
const controls=[
 ['disable-main-terminal',"if(nativeJournalUnavailable(error))try","if(false && nativeJournalUnavailable(error))try",'unavailable terminal journal existing main and pane show durable answer'],
 ['disable-pane-terminal',"if(nativeJournalUnavailable({message:journalError.replace('Live journal unavailable: ','')}) && terminal.settled)","if(false && nativeJournalUnavailable({message:journalError.replace('Live journal unavailable: ','')}) && terminal.settled)",'unavailable terminal journal existing main and pane show durable answer'],
 ['replace-known-raw','container.append(...staged.childNodes);','container.replaceChildren(...staged.childNodes);','terminal fallback preserves original raw DOM and folds'],
 ['malformed-to-zero','local value=args.after','local value=tonumber(args.after) or 0','malformed cursor named refusal "garbage"']
];
for(const [name,from,to,expected] of controls){
 const stage=fs.mkdtempSync(path.join(os.tmpdir(),'wa-review-correction-mutant-'));
 try{
  let args=['review/native-ui-successor/probe.cjs',binary],changed;
  if(name==='malformed-to-zero'){
   fs.cpSync(path.join(repo,'lua'),path.join(stage,'lua'),{recursive:true});changed=path.join(stage,'lua/core/subagents.lua');args.push('--lua-root',stage);
  }else{fs.cpSync(path.join(repo,'ui'),path.join(stage,'ui'),{recursive:true});changed=path.join(stage,'ui/app.js');args.push('--ui-root',path.join(stage,'ui'));}
  const text=fs.readFileSync(changed,'utf8');assert.ok(text.includes(from),name+' anchor');fs.writeFileSync(changed,text.replace(from,to));
  const r=spawnSync(process.execPath,args,{cwd:repo,encoding:'utf8',windowsHide:true,timeout:180000,maxBuffer:16000000});
  const output=(r.stdout||'')+(r.stderr||'');fs.writeFileSync(path.join(__dirname,name+'.log'),output);
  const receipt=output.match(/evidence: ([^\r\n]+)/);assert.ok(receipt,output);
  const proof=JSON.parse(fs.readFileSync(receipt[1]));
  assert.ok(proof.cleanup.fixture_home_removed&&proof.cleanup.ownedPids.every(p=>p.exited&&p.job.creation_proven&&p.job.in_job&&p.job.kill_on_close&&p.job.no_breakaway&&p.job.drained&&p.job.accounting.active_processes===0));
  const intended=r.status===1&&proof.review?.failures.includes(expected);
  results.push({name,exit:r.status,expected,intended,failures:proof.review?.failures,error:proof.error,receipt:receipt[1],mutantHash:crypto.createHash('sha256').update(fs.readFileSync(changed)).digest('hex')});
  fs.writeFileSync(path.join(__dirname,'causal-controls.json'),JSON.stringify(results,null,2)+'\n');
  assert.ok(intended,'mutant failed outside claimed case: '+name+' '+proof.error);
 }finally{assert.ok(path.resolve(stage).startsWith(path.resolve(os.tmpdir())+path.sep)&&path.basename(stage).startsWith('wa-review-correction-mutant-'));fs.rmSync(stage,{recursive:true,force:true});}
}
console.log('4 independent causal controls failed their intended connected cases; product source unchanged');
