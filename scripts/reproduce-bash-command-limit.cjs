// Native Windows launch probe; preserves requested scripts and exact results in a private fixture.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-command-limit-'));
const shell=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
const results=[];
for(const bytes of [7900,8200,8300,10000]) {
 const end='\necho REACHED\n'; const command='#'+ 'x'.repeat(bytes-end.length-1)+end;
 const file=path.join(root,`${bytes}.sh`);fs.writeFileSync(file,command);
 for(const mode of ['command','file']) {
  const r=require('./lib/fixture-operation.cjs')(root,shell,mode==='command'?['-c',command]:[file]);
  results.push({bytes,mode,status:r.status,error:r.error?.message,stdout:r.stdout,stderr:r.stderr,path:file});
 }
}
fs.writeFileSync(path.join(root,'results.json'),JSON.stringify(results,null,2));
console.log(JSON.stringify({root,results},null,2));
// Successful synchronous shells have closed pipes and exited; uncertain launches retain root.
if(results.every(r=>r.status!==null && !r.error)) retainAndRemove(root);
function retainAndRemove(owned) {
 const crypto=require('node:crypto');const assert=require('node:assert/strict');
 const absolute=path.resolve(owned);assert(path.isAbsolute(owned));
 assert.equal(path.dirname(absolute),fs.realpathSync(os.tmpdir()));
 assert.equal(fs.realpathSync(absolute),absolute,'fixture root must not be junction');
 const files=[];function walk(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);assert(!fs.lstatSync(p).isSymbolicLink(),'no links in cleanup tree');assert.equal(fs.realpathSync(p),p,'no junction in cleanup tree');if(e.isDirectory())walk(p);else files.push(p);}}walk(absolute);
 const git=spawnSync('git',['rev-parse','--git-common-dir'],{encoding:'utf8',cwd:__dirname});assert.equal(git.status,0);
 const destination=path.resolve(__dirname,git.stdout.trim(),'fixture-evidence',path.basename(absolute));fs.mkdirSync(destination,{recursive:true});
 const mapping=[];for(const p of files){const bytes=fs.readFileSync(p),sha=crypto.createHash('sha256').update(bytes).digest('hex'),target=path.join(destination,path.relative(absolute,p));fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,bytes,{flag:'wx'});assert(fs.readFileSync(target).equals(bytes));mapping.push({original:p,retained:target,sha256:sha});}
 fs.writeFileSync(path.join(destination,'retention-map.json'),JSON.stringify(mapping,null,2),{flag:'wx'});
 console.log('retained evidence: '+destination);fs.rmSync(absolute,{recursive:true});
}
