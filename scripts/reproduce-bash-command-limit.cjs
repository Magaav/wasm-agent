// Native Windows launch probe; preserves requested scripts and exact results in a private fixture.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-command-limit-'));
const shell=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
const results=[];
for(const bytes of [7900,8200,8300,10000]) {
 const end='\necho REACHED\n'; const command='#'+ 'x'.repeat(bytes-end.length-1)+end;
 const file=path.join(root,`${bytes}.sh`);fs.writeFileSync(file,command);
 for(const mode of ['command','file']) {
  const r=spawnSync(shell,mode==='command'?['-c',command]:[file],{encoding:'utf8',timeout:10000});
  results.push({bytes,mode,status:r.status,error:r.error?.message,stdout:r.stdout,stderr:r.stderr,path:file});
 }
}
fs.writeFileSync(path.join(root,'results.json'),JSON.stringify(results,null,2));
console.log(JSON.stringify({root,results},null,2));
