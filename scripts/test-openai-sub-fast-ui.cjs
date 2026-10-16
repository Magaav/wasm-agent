const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.argv[2]);fs.mkdirSync(out);
const hash=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');const runs=[];
function observe(name,ui,pass,expectedFailure=/explicit ON CAS/){
 const r=spawnSync(process.execPath,[root+'/scripts/agent-benchmark-ui-observe.mjs','--ui',ui,'--probe',root+'/scripts/probe-openai-sub-fast.js','--out',out+'/'+name],{cwd:root,encoding:'utf8',windowsHide:true,timeout:150000});
 fs.writeFileSync(out+'/'+name+'.stdout',r.stdout||'');fs.writeFileSync(out+'/'+name+'.stderr',r.stderr||'');
 const value=JSON.parse(r.stdout.trim().split(/\r?\n/).at(-1));runs.push({name,exit:r.status,...value,screenshot_sha256:hash(value.screenshot)});
 fs.writeFileSync(out+'/receipt.json',JSON.stringify({runs,sources:Object.fromEntries(['ui/app.js','ui/index.html','ui/style.css','ui/components.js','ui/test-fixtures.js','ui/render.wasm','scripts/probe-openai-sub-fast.js'].map(p=>[p,hash(root+'/'+p)]))},null,2));
 assert.equal(r.status,pass?0:1,r.stdout+r.stderr);assert.equal(value.probeStatus,pass?'pass':'fail');console.log(name+': '+value.probeText);
 if(!pass)assert.match(value.probeText,expectedFailure);
}
observe('positive',root+'/ui',true);
const mutant=out+'/mutant';fs.cpSync(root+'/ui',mutant,{recursive:true});const file=mutant+'/app.js';const source=fs.readFileSync(file,'utf8');assert(source.includes("fastToggle.addEventListener('change',saveFastMode);"));fs.writeFileSync(file,source.replace("fastToggle.addEventListener('change',saveFastMode);",''));observe('negative',mutant,false);
const oldLabel=out+'/old-label';fs.cpSync(root+'/ui',oldLabel,{recursive:true});const index=oldLabel+'/index.html';const html=fs.readFileSync(index,'utf8');assert(html.includes('<span>Fast mode for subagents</span>'));fs.writeFileSync(index,html.replace('<span>Fast mode for subagents</span>','<span>Include coding task owners</span>'));observe('old-label-negative',oldLabel,false,/exact subagent Fast label/);
console.log('Evidence: '+out);
