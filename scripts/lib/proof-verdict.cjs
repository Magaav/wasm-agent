// Required integration proofs need process success, one terminal verdict, and non-dropped counts.
const prefixes={sqlite:'sqlite worker isolation ok',peer:'peer run admission ok',foreground:'foreground cancel ok',orchestration:'orchestration integrated ok',whatsapp:'whatsapp subagent e2e ok',cursor:'whatsapp cursor ok',children:'subagents integration ok',jobs:'subagent integration ok',policy:'isolated policy ok'};
function validate(kind,status,output,minimum){
 if(!Object.hasOwn(prefixes,kind))throw Error('unknown proof');
 if(status!==0)throw Error('proof exit '+status);
 if(!Number.isSafeInteger(minimum)||minimum<1)throw Error('invalid minimum');
 const lines=String(output).split(/\r?\n/),verdicts=lines.filter(line=>line.startsWith(prefixes[kind]+' ('));
 if(verdicts.length!==1)throw Error('missing or duplicate terminal verdict');
 const line=verdicts[0].replace(/\bskips\b/g,'skipped');if(!line.endsWith(')'))throw Error('malformed verdict');
 function count(label,required){
  const found=line.match(new RegExp('(?:\\(|, |; )(\\d+) '+label+'(?:[,; )]|$)','g'))||[];
  if(found.length!==1){if(!required&&!line.includes(label))return 0;throw Error('missing or malformed '+label);}
  const number=Number(found[0].match(/\d+/)[0]);if(!Number.isSafeInteger(number))throw Error('invalid '+label);return number;
 }
 const checks=count('checks',true),failed=count('failed',false),skipped=count('skipped',false);
 if(checks<minimum)throw Error(`check count dropped: ${checks} < ${minimum}`);
 if(failed||failed+skipped>checks)throw Error('failed or contradictory counts');
 if(lines.some(line=>/^\s*(?:FAIL(?:[:\s]|$)|ALL FAIL(?:[:\s]|$)|DEPENDENCY_MISSING)/.test(line)))throw Error('failure evidence');
 const skipNames=lines.filter(line=>/^\s*SKIP(?:[:\s])/.test(line)).map(line=>line.trim().replace(/^SKIP[:\s]+/,''));
 if(skipNames.length!==skipped||skipNames.some(name=>!name)||new Set(skipNames).size!==skipped)throw Error('missing or contradictory skip evidence');
 return {checks,skipped};
}
module.exports={validate};
if(require.main===module){try{const [kind,status,minimum]=process.argv.slice(2);console.log(validate(kind,/^-?\d+$/.test(status||'')?Number(status):NaN,require('node:fs').readFileSync(0,'utf8'),Number(minimum)).skipped);}catch(error){console.error('proof verdict refused: '+error.message);process.exitCode=1;}}
