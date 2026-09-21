const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawnSync}=require('node:child_process');
const {validate}=require('./lib/suite-verdict.cjs');
const good={suite:'fixture',checks:25,failed:0,skipped:1,skipped_names:['platform environment inspection'],ok:true};
let checks=0;
assert.equal(validate(good,'fixture',0,25),1);checks++;
for(const [value,status] of [[good,1],[{...good,checks:24},0],[{...good,suite:'other'},0],[{...good,failed:1},0],[{...good,skipped:-1},0],[{...good,skipped:26},0],[{...good,skipped_names:[]},0],[{...good,ok:false},0]]){
  assert.throws(()=>validate(value,'fixture',status,25));checks++;
}
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-suite-verdict-'));
const file=path.join(root,'verdict.json');
for(const content of [null,'{broken',JSON.stringify(good)]){
  if(content!==null)fs.writeFileSync(file,content);
  const r=spawnSync(process.execPath,[path.join(__dirname,'lib/suite-verdict.cjs'),file,'fixture','0','25'],{encoding:'utf8'});
  assert.equal(r.status,content===JSON.stringify(good)?0:1);checks++;
  if(r.status===0){assert.equal(r.stdout.trim(),'1');checks++;}
}
fs.rmSync(root,{recursive:true});
console.log(`nested suite verdict ok (${checks} checks, 0 skipped; missing evidence/count-drop/skip propagation mutations)`);
