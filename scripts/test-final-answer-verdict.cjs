// Execute the actual production helper with deterministic process receipts, no copied parser.
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=fs.readFileSync('scripts/test-final-answer-suite.mjs','utf8');
const helper=source.slice(source.indexOf('function run('),source.indexOf("run('verdict-contract'"));
let receipt;
const context={spawnSync:()=>receipt,fs:{writeFileSync(){}},path:{join:(...v)=>v.join('/')},out:'private',root:'private',base:{},process:{stdout:{write(){}}}};
vm.createContext(context);vm.runInContext(helper+'\nthis.actualRun=run;',context);
const terminal='OWN terminal';
const cases=[
 ['missing',{status:0,stdout:'other'},false],
 ['duplicate',{status:0,stdout:terminal+'\n'+terminal},false],
 ['malformed',{status:0,stdout:terminal+' extra'},false],
 ['nonzero',{status:1,stdout:terminal},false],
 ['signal',{status:0,signal:'SIGTERM',stdout:terminal},false],
 ['error',{status:0,error:{message:'launch failed'},stdout:terminal},false],
 ['nested-good',{status:0,stdout:'PASS unrelated nested suite\n'+terminal},true],
 ['position',{status:0,stdout:terminal+'\ntrailing other'},false]
];
for(const [name,value,accepted] of cases){
 receipt=value;let success=true;try{context.actualRun(name,'fixture',[],{},terminal);}catch{success=false;}
 assert.equal(success,accepted,name);
}
console.log('PASS final-answer verdict contract (8 checks, 0 skips)');
