// Focused browser probe: a steer that carries a picture is accepted, and the appended steered turn
// draws that picture through the same attachment renderer an ordinary sent turn uses - compared to
// the CONTROL this page's own ordinary send produced, with the shared fingerprint helper.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),out=path.resolve(process.argv[2]);
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sources=()=>Object.fromEntries(['ui/app.js','ui/components.js','ui/style.css','scripts/probe-steered-image-render.js','scripts/wa-probe-support.js','scripts/agent-benchmark-ui-observe.mjs','scripts/test-steered-image-render.cjs'].map(file=>[file,hash(path.join(repo,file))]));
if(process.argv.includes('--post')){
  const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));
  assert(r.ok&&r.checks>=25&&r.skipped===0);
  assert.deepEqual(r.sources,sources());
  assert.equal(r.screenshot_sha256,hash(out+'/screenshot.png'));
  assert.equal(r.dom_sha256,hash(out+'/dom.html'));
  console.log(JSON.stringify({ok:true,checks:r.checks,skipped:0,retained_hashes:true}));
  process.exit(0);
}
assert(!fs.existsSync(out),'fresh evidence required');
const result=spawnSync(process.execPath,[repo+'/scripts/agent-benchmark-ui-observe.mjs','--probe',repo+'/scripts/probe-steered-image-render.js','--out',out],{cwd:repo,encoding:'utf8',timeout:150000,maxBuffer:8388608,windowsHide:true});
fs.mkdirSync(out,{recursive:true});
for(const stream of ['stdout','stderr'])fs.writeFileSync(out+'/'+stream,result[stream]||'');
assert.equal(result.status,0,result.stdout+result.stderr);
const view=JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
assert(view.ok&&view.probeStatus==='pass',result.stdout+result.stderr);
const proof=JSON.parse(view.probeText);
assert(proof.ok&&proof.checks>=25&&proof.skipped===0,view.probeText);
const receipt={ok:true,...proof,sources:sources(),screenshot_sha256:hash(out+'/screenshot.png'),dom_sha256:hash(out+'/dom.html')};
fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt,null,2));
console.log(JSON.stringify({ok:true,checks:proof.checks,skipped:0,steering_posts:proof.steering_posts,steering_images:proof.steering_images,steered_drawn:proof.steered_drawn,many_drawn:proof.many_drawn,evidence:out}));
