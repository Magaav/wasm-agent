// Machine-readable nested-suite evidence. Missing, malformed, stale or dropped counts fail closed.
const fs=require('node:fs');
function validate(value,suite,status,minimumChecks) {
  if(status!==0)throw Error('nested suite exit '+status);
  if(!value||value.suite!==suite)throw Error('missing or wrong suite identity');
  for(const key of ['checks','failed','skipped'])if(!Number.isSafeInteger(value[key])||value[key]<0)throw Error('invalid count: '+key);
  if(value.checks<minimumChecks)throw Error(`check count dropped: ${value.checks} < ${minimumChecks}`);
  if(value.failed+value.skipped>value.checks)throw Error('contradictory counts');
  if(value.ok!==true||value.failed!==0)throw Error('nested suite failed');
  if(!Array.isArray(value.skipped_names)||value.skipped_names.length!==value.skipped)throw Error('missing skip evidence');
  return value.skipped;
}
module.exports={validate};
if(require.main===module){
  try{
    const [file,suite,status,minimum]=process.argv.slice(2);
    const result=validate(JSON.parse(fs.readFileSync(file,'utf8')),suite,Number(status),Number(minimum));
    if(!Number.isSafeInteger(Number(minimum))||Number(minimum)<1)throw Error('invalid minimum checks');
    console.log(result);
  }catch(error){console.error('nested suite verdict refused: '+error.message);process.exitCode=1;}
}
