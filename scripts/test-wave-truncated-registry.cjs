// A generated repository with more worktrees than the host's bounded exec view can hold, plus a
// changeset larger than that view. Nothing here is committed to the project; the count of
// worktrees is grown until the real `git worktree list --porcelain` exceeds the view budget, so
// the fixture cannot silently become too small to reproduce the defect.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=process.argv[3]?path.resolve(process.argv[3]):fs.mkdtempSync(path.join(os.tmpdir(),'wat-reg-'));
const git=(root,...args)=>{const r=spawnSync('git',args,{cwd:root,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stdout+r.stderr);return r.stdout;};
fs.mkdirSync(out,{recursive:true});const main=out+'/main',home=out+'/home',trees=out+'/w';fs.mkdirSync(home);fs.mkdirSync(trees);
git(out,'init','-q','-b','main',main);
git(main,'config','core.autocrlf','false');git(main,'config','user.name','private fixture');git(main,'config','user.email','fixture@invalid');
fs.mkdirSync(main+'/scripts',{recursive:true});fs.mkdirSync(main+'/lua/core',{recursive:true});
fs.writeFileSync(main+'/scripts/deploy-shipped.json',JSON.stringify({schema:1,directories:['lua/','scripts/'],files:[],globs:[]}));
fs.writeFileSync(main+'/base.txt','baseline\n');
git(main,'add','.');git(main,'commit','-q','-m','private baseline');const base=git(main,'rev-parse','HEAD').trim();
// One changeset far larger than a 24 KiB view, carrying exactly one shipped path.
fs.mkdirSync(main+'/fixture/generated',{recursive:true});
for(let i=0;i<1400;i++)fs.writeFileSync(main+'/fixture/generated/padding-'+String(i).padStart(4,'0')+'.txt','x\n');
fs.writeFileSync(main+'/lua/core/marker.lua','-- fixture marker\n');
git(main,'add','.');git(main,'commit','-q','-m','a changeset larger than the exec view');const tip=git(main,'rev-parse','HEAD').trim();
let listing=git(main,'worktree','list','--porcelain'),made=0;
while(Buffer.byteLength(listing)<26000){git(main,'worktree','add','-q','--detach',`${trees}/${String(made++).padStart(3,'0')}`,tip);listing=git(main,'worktree','list','--porcelain');}
const worktrees=listing.split('\n').filter((line)=>line.startsWith('worktree ')).length;
assert(made>100,`the fixture must really carry many worktrees, made ${made}`);
assert(worktrees>100,`the listing names ${worktrees} worktrees`);
fs.writeFileSync(out+'/fixture.txt',`worktrees=${worktrees} listing_bytes=${Buffer.byteLength(listing)} generated_worktrees=${made}\n`);
const env={...process.env};for(const k of Object.keys(env))if(/^(WA_|WASM_AGENT_|PI_|OPENAI_|OPENCODE_|ANTHROPIC_)/.test(k))delete env[k];
const run=spawnSync(binary,['--db',home+'/memory.db'],{cwd:repo,env:{...env,WASM_AGENT_HOME:home,WASM_AGENT_LUA_ROOT:repo,WA_SCRIPT:repo+'/scripts/test-wave-truncated-registry.lua',WA_FIXTURE_MAIN:main,WA_FIXTURE_TIP:tip,WA_FIXTURE_BASE:base},encoding:'utf8',windowsHide:true,timeout:300000});
fs.writeFileSync(out+'/stdout',run.stdout||'');fs.writeFileSync(out+'/stderr',run.stderr||'');
assert.equal(run.status,0,(run.stdout||'')+(run.stderr||''));
const proof=JSON.parse((run.stdout||'').trim().split('\n').pop());
assert(proof.ok&&proof.checks>=15,'fixture proof '+JSON.stringify(proof));
assert(proof.listing_bytes>26000,'the complete listing is larger than the view');
const receipt={ok:true,checks:proof.checks,worktrees,listing_bytes:proof.listing_bytes,view_bytes:proof.view_bytes,skipped:0,evidence:out};
fs.writeFileSync(out+'/receipt.json',JSON.stringify(receipt));
console.log(JSON.stringify(receipt));
