// Zero network/model calls: real Lua HTTP boundary receives owned deterministic envelopes.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'wa-serving-'));
const clean=Object.fromEntries(Object.entries(process.env).filter(([k])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|SERVING_TEST_)/i.test(k)));
try {
  for(const embedded of [false,true]) {
    const home=path.join(work,embedded?'embedded':'source');fs.mkdirSync(home);
    for(const mode of ['first','restart']) {
      const env={...clean,WASM_AGENT_HOME:home,WA_SCRIPT:path.join(root,'scripts/test-provider-serving.lua'),SERVING_TEST_MODE:mode};
      if(!embedded)env.WASM_AGENT_LUA_ROOT=root;
      const result=spawnSync(binary,['--db',path.join(home,'private.db')],{cwd:work,env,encoding:'utf8',timeout:60000,windowsHide:true});
      process.stdout.write(`${embedded?'embedded':'source'} ${mode}\n${result.stdout}`);
      assert.equal(result.status,0,result.stderr);
      assert.match(result.stdout,/checks, 0 skips, 0 paid calls/);
    }
  }
  console.log('4 private process runs passed; source + compiled embedding + persisted restart; 0 skips');
} finally {fs.rmSync(work,{recursive:true,force:true});}
