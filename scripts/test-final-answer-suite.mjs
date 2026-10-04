import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const exe=process.argv[2];
if(!exe)throw Error('wa executable required');
const root=process.cwd();
const out=path.resolve(process.argv[3]||'.final-answer-test');
fs.mkdirSync(out,{recursive:true});
function run(name,program,args,env={}) {
 const result=spawnSync(program,args,{cwd:root,env:{...process.env,...env},encoding:'utf8',timeout:120000});
 const log=(result.stdout||'')+(result.stderr||'');fs.writeFileSync(path.join(out,name+'.log'),log);
 process.stdout.write(log);
 if(result.status!==0||/lua error:/.test(log))throw Error(name+' failed: '+result.status);
 return log;
}
const env={WASM_AGENT_HOME:path.join(out,'home'),WASM_AGENT_LUA_ROOT:root,WA_FINAL_EVENTS:path.join(out,'events.json')};
for(const [name,script] of [['wire','test-final-answer.lua'],['loop','test-final-answer-loop.lua']]) {
 const log=run(name,exe,['--db',path.join(out,name+'-'+Date.now()+'.db')],{...env,WA_SCRIPT:path.join(root,'scripts',script)});
 if(!log.includes(name==='wire'?'9 checks':'55 checks'))throw Error('missing '+name+' verdict');
}
run('pi',process.execPath,['scripts/test-openai-sub.cjs']);
run('browser',process.execPath,['scripts/test-final-answer-browser.mjs',path.join(out,'events.json'),path.join(out,'browser')]);
console.log('PASS final-answer normal suite: wire9, loop55, Pi fixture, shared browser; 0 skips');
