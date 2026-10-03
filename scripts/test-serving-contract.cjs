// Private source/embedded restart contract attacks, retaining every raw log.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]);
const out=path.resolve(process.argv[3]||fs.mkdtempSync(path.join(os.tmpdir(),'wa-serving-contract-')));fs.mkdirSync(out,{recursive:true});
const original=fs.readFileSync(path.join(root,'scripts/test-provider-serving.lua'),'utf8');
const prefix=original.slice(0,original.indexOf('local mode='));
const script=prefix+fs.readFileSync(path.join(root,'scripts/test-serving-contract.lua'),'utf8');
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
for(const embedded of [false,true]) {
  const home=path.join(out,embedded?'embedded':'source');fs.mkdirSync(home,{recursive:true});
  const fixture=path.join(home,'fixture.lua');fs.writeFileSync(fixture,script);
  for(const mode of ['first','restart']) {
    const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:fixture,SERVING_TEST_MODE:mode};if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
    const r=spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:out,env,encoding:'utf8',timeout:60000,windowsHide:true});
    fs.writeFileSync(path.join(home,mode+'.log'),r.stdout+'\nSTDERR\n'+r.stderr);
    assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/checks, 0 skips, 0 paid calls/);process.stdout.write(`${embedded?'embedded':'source'} ${mode}\n${r.stdout}`);
  }
}
console.log('Serving contract source + embedded attacks + corrupt restart passed; 0 skips, 0 paid calls; '+out);
