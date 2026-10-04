const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..');
const out=fs.mkdtempSync(path.join(os.tmpdir(),'wa-coordinator-steps-'));
try {
  const args=['scripts/agent-benchmark-ui-observe.mjs','--ui','ui','--probe','scripts/probe-coordinator-steps.js','--out',out];
  if(process.platform==='win32') {
    const roots=[process.env.PROGRAMFILES,process.env['PROGRAMFILES(X86)'],process.env.LOCALAPPDATA].filter(Boolean);
    if(!roots.some(root=>fs.existsSync(path.join(root,'Google/Chrome/Application/chrome.exe')))) {
      const edge=roots.map(root=>path.join(root,'Microsoft/Edge/Application/msedge.exe')).find(file=>fs.existsSync(file));
      if(edge)args.push('--chrome',edge);
    }
  }
  const run=spawnSync(process.execPath,args,
    {cwd:repo,encoding:'utf8',windowsHide:true,timeout:120000,maxBuffer:4*1024*1024});
  assert.equal(run.status,0,run.stdout+run.stderr);
  const observed=JSON.parse(run.stdout.trim());
  assert.equal(observed.probeStatus,'pass');
  const proof=JSON.parse(observed.probeText);
  assert.ok(proof.checks>=38);
  assert.equal(proof.skipped,0);
  console.log(JSON.stringify({checks:proof.checks,skipped:0,evidence:proof.evidence}));
  console.log('coordinator steps ok ('+proof.checks+' checks, 0 skipped)');
} finally {
  // The observer owns and removes its staging directory and browser profile.
  // Preserve the small DOM/screenshot/log artifacts for independent review.
  console.log('evidence: '+out);
}
