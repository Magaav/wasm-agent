// Force the real reservation/admission window long enough to falsify timer sampling.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-queue-race-')));
fs.mkdirSync(out,{recursive:true});fs.cpSync(path.join(root,'lua'),path.join(out,'lua'),{recursive:true});
const file=path.join(out,'lua/core/orchestrator.lua');
const before=fs.readFileSync(file,'utf8'),needle='local function invoke(destination, args, ctx, api)';assert.ok(before.includes(needle));
fs.writeFileSync(file,before.replace(needle,needle+"\n  if args.prompt=='third' then host.sleep(4000) end -- private delayed admission seam"));
const original=fs.readFileSync(path.join(root,'scripts/test-orchestrator.cjs'),'utf8');
const fixed=original.replace("const root=path.resolve(__dirname,'..');",'const root='+JSON.stringify(root)+';');
const start=fixed.indexOf('  // Reservation is visible as placing'),end=fixed.indexOf('  const steering=',start);assert.ok(start>0&&end>start);
const old=fixed.slice(0,start)+`  await sleep(2500);
  const sampled=await status(third.subagent_id);console.log('timed sample '+JSON.stringify(sampled));
  check(sampled.state==='queued','all-full work remains durably queued');
`+fixed.slice(end);
for(const [name,script,expected] of [['timed-sample',old,1],['settled-observation',fixed,0]]) {
  const runner=path.join(out,name+'.cjs');fs.writeFileSync(runner,script);
  const result=spawnSync(process.execPath,[runner,binary],{cwd:root,env:{...process.env,ORCHESTRATOR_TEST_LUA_ROOT:out},encoding:'utf8',timeout:180000,windowsHide:true});
  fs.writeFileSync(path.join(out,name+'.log'),result.stdout+'\nSTDERR\n'+result.stderr);
  assert.equal(result.status,expected,result.stderr);
  if(expected) {assert.match(result.stdout,/timed sample .*"state":"placing"/);assert.match(result.stderr,/all-full work remains durably queued/);}
  else assert.match(result.stdout,/20 checks, 0 skipped/);
  console.log(name+' exit '+result.status+'; evidence '+out);
}
console.log('F5 causal timer-sampling failure reproduced and settled-observation repair passed; 0 paid calls');
