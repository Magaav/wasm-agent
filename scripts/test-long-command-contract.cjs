// Parent contract exercises the same orchestrator used by the normal workspace runner.
const assert=require('node:assert/strict'),execute=require('./long-command-contract.cjs');
function subject(status,stdout){let calls=0;const run=name=>{assert.equal(name,'test-bash-long-command.lua');calls++;return {status,stdout,stderr:'fixture'};};let failed=false;try{execute(run);}catch{failed=true;}assert.equal(calls,1,'orchestrator must actually invoke fixture');return failed;}
assert.equal(subject(0,'bash long command ok (10 checks)'),false,'valid10 accepted');
assert.equal(subject(0,'bash long command ok (9 checks)'),true,'green9 refused');
assert.equal(subject(0,''),true,'silent refused');
assert.equal(subject(1,'bash long command ok (10 checks)'),true,'failed fixture refused');
console.log('long-command parent contract ok (4 cases)');
