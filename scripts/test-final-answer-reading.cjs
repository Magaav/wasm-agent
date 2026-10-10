// Real Chromium reading-position proof; fixture UI only, never the installed page.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),out=process.argv[2];assert(out&&path.isAbsolute(out),'absolute evidence directory required');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files=['ui/app.js','ui/components.js','ui/style.css','scripts/test-final-answer-ui.js','scripts/test-final-answer-reading.cjs','scripts/agent-benchmark-ui-observe.mjs'];
const pins=()=>Object.fromEntries(files.map(f=>[f,hash(path.join(repo,f))]));
if(process.argv.includes('--post')){
 const r=JSON.parse(fs.readFileSync(path.join(out,'receipt.json')));assert(r.ok&&r.skips===0);assert.deepEqual(r.sources,pins());assert.equal(hash(path.join(out,'screenshot.png')),r.screenshot_sha256);assert.equal(hash(path.join(out,'dom.html')),r.dom_sha256);console.log(JSON.stringify({ok:true,source_verified:true,evidence_verified:true,skips:0}));process.exit(0);
}
assert(!fs.existsSync(out),'fresh evidence required');
const r=spawnSync(process.execPath,[path.join(repo,'scripts/agent-benchmark-ui-observe.mjs'),'--ui',path.join(repo,'ui'),'--probe',path.join(repo,'scripts/test-final-answer-ui.js'),'--out',out],{cwd:repo,encoding:'utf8',timeout:150000,windowsHide:true});
fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'runner.stdout'),r.stdout||'');fs.writeFileSync(path.join(out,'runner.stderr'),r.stderr||'');
const verdict=JSON.parse(r.stdout.trim().split(/\r?\n/).at(-1));assert.equal(r.status,0,JSON.stringify(verdict));assert(!r.error&&!r.signal);assert(verdict.ok&&verdict.probeStatus==='pass');
const receipt={ok:true,sources:pins(),screenshot_sha256:hash(path.join(out,'screenshot.png')),dom_sha256:hash(path.join(out,'dom.html')),skips:0};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({ok:true,probeStatus:'pass',skips:0,out}));
