const assert=require('node:assert/strict'),{validate}=require('./lib/proof-verdict.cjs');
let checks=0;
const good='peer run admission ok (43 checks, 0 skips; mock)';
// Both established suite spellings must carry the same skip accounting.
assert.deepEqual(validate('peer',0,good,43),{checks:43,skipped:0});checks++;
const valid=good.replace('0 skips','0 skipped');
assert.deepEqual(validate('peer',0,valid,43),{checks:43,skipped:0});checks++;
for(const [status,text,min] of [
 [1,valid,43],[0,'',43],[0,valid,44],[0,valid+'\n'+valid,43],
 [0,valid.replace('43 checks','-1 checks'),43],[0,valid.replace('43 checks','many checks'),43],
 [0,valid.replace('0 skipped','1 failed, 0 skipped'),43],[0,valid.replace('0 skipped','1 skipped'),43],
 [0,valid+'\nFAIL: late failure',43],[0,valid+'\nSKIP: uncounted',43],
 [0,valid.replace('0 skipped','44 skipped'),43],[0,valid,NaN],
 [0,valid.slice(0,-1),43],
]){assert.throws(()=>validate('peer',status,text,min));checks++;}
assert.deepEqual(validate('peer',0,'SKIP: unavailable API\n'+valid.replace('0 skipped','1 skipped'),43),{checks:43,skipped:1});checks++;
assert.throws(()=>validate('unknown',0,valid,43));checks++;
assert.deepEqual(validate('children',0,'subagents integration ok (17 checks; local mock model, no paid inference)',17),{checks:17,skipped:0});checks++;
console.log(`proof verdict ok (${checks} mutation checks)\nALL PASS`);
