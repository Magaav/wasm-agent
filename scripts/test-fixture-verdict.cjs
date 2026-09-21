const assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const {verdict}=require('./lib/test-verdict.cjs');
const cases=[
  ['js',0,'ALL PASS\n',true],['js',0,'ALL PASS\r\n',true],
  ['js',1,'ALL PASS\n',false],['js',null,'ALL PASS\n',false],
  ['js',0,'',false],['js',0,'ALL PASS but something failed\n',false],
  ['js',0,'FAIL lost evidence\nALL PASS\n',false],
  ['lua',0,'session contract ok\n',true],['lua',0,'true\n',true],
  ['lua',1,'session contract ok\n',false],['lua',0,'probably ok but not done\n',false],
  ['lua',0,'FAIL dropped assertion\nsession contract ok\n',false],
  ['unknown',0,'ALL PASS\n',false],
];
let checks=0;
for(const [kind,code,output,expected] of cases){assert.equal(verdict(kind,code,output).ok,expected);checks++;}
for(const code of [0,1]){
  const fixture=spawnSync(process.execPath,['-e',`console.log('ALL PASS');process.exit(${code})`],{encoding:'utf8'});
  const checked=spawnSync(process.execPath,[path.join(__dirname,'lib/test-verdict.cjs'),'js',String(fixture.status)],{input:fixture.stdout,encoding:'utf8'});
  assert.equal(checked.status,code);checks++;
}
console.log(`fixture verdict ok (${checks} checks, 0 skipped; real exit-after-verdict mutation)`);
