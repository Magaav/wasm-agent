// Retained Live Children card proof: three stable lines and the footer's own stats renderer.
//
// Same shape as the other staged-browser suites in this directory: run the probe in a real browser
// over a COPY of this checkout's ui/, refuse anything but a clean probe pass, and keep a receipt
// whose hashes prove the evidence belongs to these sources. `--post` re-reads that receipt, so a
// green line cannot survive an edit to the files it describes.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),out=process.argv[2]?path.resolve(process.argv[2]):fs.mkdtempSync(path.join(os.tmpdir(),'wa-live-children-cards-'));
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const sources=()=>Object.fromEntries(['ui/app.js','ui/components.js','ui/style.css','scripts/probe-live-children-cards.js','scripts/test-live-children-cards.cjs'].map(p=>[p,hash(path.join(repo,p))]));
if(process.argv.includes('--post')){
  const r=JSON.parse(fs.readFileSync(out+'/receipt.json'));
  assert(r.ok&&r.skipped===0&&r.checks>=29);
  assert.deepEqual(r.sources,sources(),'the receipt must describe the sources that are here now');
  assert.equal(r.screenshot_sha256,hash(out+'/screenshot.png'));
  assert.equal(r.dom_sha256,hash(out+'/dom.html'));
  console.log(JSON.stringify({ok:true,checks:r.checks,skipped:0,evidence_verified:true}));
  process.exit(0);
}
assert(!fs.existsSync(out+'/receipt.json'),'fresh evidence required: '+out);
const r=spawnSync(process.execPath,[repo+'/scripts/agent-benchmark-ui-observe.mjs','--probe',repo+'/scripts/probe-live-children-cards.js','--out',out],{cwd:repo,encoding:'utf8',windowsHide:true,timeout:150000});
fs.mkdirSync(out,{recursive:true});
fs.writeFileSync(out+'/stdout.log',r.stdout||'');
fs.writeFileSync(out+'/stderr.log',r.stderr||'');
assert.equal(r.status,0,r.stdout+r.stderr);
assert(!r.error&&!r.signal);
const verdict=JSON.parse(r.stdout.trim().split(/\r?\n/).at(-1));
assert(verdict.ok&&verdict.probeStatus==='pass','probe must pass, saw: '+JSON.stringify(verdict));
const proof=JSON.parse(verdict.probeText);
assert(proof.checks>=29&&proof.skipped===0,'29 checks, none skipped: '+JSON.stringify(proof));
fs.writeFileSync(out+'/receipt.json',JSON.stringify({ok:true,...proof,sources:sources(),
  screenshot_sha256:hash(out+'/screenshot.png'),dom_sha256:hash(out+'/dom.html')},null,2));
console.log(JSON.stringify({ok:true,checks:proof.checks,skipped:0,evidence:out}));
