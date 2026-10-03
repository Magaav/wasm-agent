const assert=require('node:assert/strict');
module.exports=function executeLongCommand(run){
 const result=run('test-bash-long-command.lua');
 assert.equal(result.status,0,`long-command exit: ${result.stderr}`);
 const count=Number(result.stdout.match(/bash long command ok \((\d+) checks\)/)?.[1]);
 assert(count>=10,`long-command count floor 10: ${result.stdout}`);
 return count;
};
