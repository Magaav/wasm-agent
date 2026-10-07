// Private CLI boundary fixtures, not a live SCM installation/recovery test.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const assert = require('node:assert/strict'), {spawnSync} = require('node:child_process');
const sha256=file=>require('node:crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if(process.argv[2]==='--post') {
  const binary=path.resolve(process.argv[3]),root=path.resolve(process.argv[4]);
  const receipt=JSON.parse(fs.readFileSync(path.join(root,'receipt.json'),'utf8'));
  assert(receipt.ok && receipt.checks===46 && receipt.skipped===0 && receipt.scm_effects===0);
  assert.equal(receipt.binary_sha256,sha256(binary));
  for(const [name,hash] of Object.entries(receipt.log_sha256)) assert.equal(sha256(path.join(root,name)),hash);
  console.log(JSON.stringify({ok:true,checks:receipt.checks,skipped:0,scm_effects:0,evidence_verified:true}));
  process.exit(0);
}
if (process.platform !== 'win32') {
  console.log(JSON.stringify({ok:true,checks:0,skipped:1,reason:'native Windows SCM fixture',scm_effects:0}));
  process.exit(0);
}
const binary = path.resolve(process.argv[2] || 'rust/target/debug/wa-sentinel.exe');
assert(fs.statSync(binary).isFile(), 'source-built sentinel required');
const root = process.argv[3] ? path.resolve(process.argv[3]) : fs.mkdtempSync(path.join(os.tmpdir(),'wa-service-cli-'));
if (process.argv[3]) {assert(!fs.existsSync(root),'fresh evidence directory required');fs.mkdirSync(root,{recursive:true});}
let checks=0;
function check(value,reason) {assert(value,reason);checks++;}
const home=path.join(root,'home'),install=path.join(root,'install'),cwd=path.join(root,'source');
for(const dir of [home,install,cwd]) fs.mkdirSync(dir);
const exe=path.join(install,'wa-sentinel.exe');fs.copyFileSync(binary,exe);
const name='wa-fixture-'+require('node:crypto').randomUUID();
const config=path.join(install,'service.json');
const base={schema:1,name,home,install,cwd,environment:{WA_SENTINEL_SCRIPTS:path.join(install,'scripts')}};
fs.writeFileSync(config,JSON.stringify(base));
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>! /^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|ANTHROPIC_|PI_)/i.test(key)));
Object.assign(env,{WASM_AGENT_HOME:home,WA_INSTALL_DIR:install,WA_INSTANCE_BASE_HOME:home,WA_INSTANCE_OPERATOR_INSTALL:install,
  WA_SENTINEL_SUPERVISOR:'windows:'+name,WASM_AGENT_PORT:'1',WASM_AGENT_CLIENT_PORT:'2'});
let generation=0;
function run(args,selected=exe) {
  const r=spawnSync(selected,args,{cwd,env,encoding:'utf8',timeout:15000,maxBuffer:1024*1024,windowsHide:true});
  const label=String(++generation).padStart(2,'0');
  fs.writeFileSync(path.join(root,label+'.stdout'),r.stdout||'');
  fs.writeFileSync(path.join(root,label+'.stderr'),r.stderr||'');
  check(!r.error && !r.signal,'fixture execution did not settle: '+(r.error?.message||r.signal));
  return r;
}
const valid=run(['service-config-check','--name',name,'--config',config]);
check(valid.status===0,'valid service config refused');
const verdict=JSON.parse(valid.stdout);
check(verdict.ok && verdict.configuration_valid && verdict.scm_started===false && verdict.effects==='none','read-only verdict');
check(!fs.existsSync(path.join(home,'.wasm-agent')),'config check wrote state');
const invalid=[['name',{name:'../other'},'invalid_windows_service_identity'],
  ['schema',{schema:2},'invalid_windows_service_identity'],
  ['relative home',{home:'relative'},'service_path_not_absolute_directory'],
  ['missing cwd',{cwd:path.join(root,'missing')},'service_path_not_absolute_directory'],
  ['secret env',{environment:{OPENAI_API_KEY:'fixture-only'}},'service_environment_refused'],
  ['Lua env',{environment:{WASM_AGENT_LUA_ROOT:cwd}},'service_environment_refused'],
  ['newline env',{environment:{PATH:'C:\\tools\nother'}},'service_environment_refused'],
  ['extra field',{extra:true},'unknown field']];
for(const [label,patch,reason] of invalid) {
  fs.writeFileSync(config,JSON.stringify({...base,...patch}));
  const r=run(['service-config-check','--name',name,'--config',config]);
  check(r.status!==0 && r.stderr.includes(reason),label+' did not fail visibly');
}
fs.writeFileSync(config,' '.repeat(16385));
let refused=run(['service-config-check','--name',name,'--config',config]);
check(refused.status!==0 && refused.stderr.includes('service_config_exceeds_16KiB'),'oversized config refusal');
fs.writeFileSync(config,JSON.stringify(base));
refused=run(['service-config-check','--name','other','--config',config]);
check(refused.status!==0 && refused.stderr.includes('service_config_name_mismatch'),'cross-name config refusal');
const foreign=path.join(root,'foreign.exe');fs.copyFileSync(exe,foreign);
refused=run(['service-config-check','--name',name,'--config',config],foreign);
check(refused.status!==0 && refused.stderr.includes('service_binary_install_mismatch'),'foreign executable refusal');
check(!fs.existsSync(path.join(home,'.wasm-agent')),'negative config checks wrote state');
const state=path.join(home,'.wasm-agent','sentinel');fs.mkdirSync(path.join(state,'requests'),{recursive:true});
const pending=path.join(state,'requests','preserve-original.json'),bytes='{"verb":"wake","reason":"fixture never to be consumed"}\n';
fs.writeFileSync(pending,bytes);
const consoleRun=run(['service','--name',name,'--config',config]);
check(consoleRun.status!==0 && consoleRun.stderr.includes('SCM dispatcher'),'console service did not refuse');
check(!fs.existsSync(path.join(state,'sentinel.pid')) && !fs.existsSync(path.join(state,'supervisor')),'console service started fallback');
check(fs.readFileSync(pending,'utf8')===bytes,'console refusal consumed original queue');
check(fs.readFileSync(path.join(state,'sentinel.log'),'utf8').includes('service-dispatch-failed'),'dispatcher refusal not durable');
const stop=path.join(state,'stop');
for(const verb of ['start','stop','restart']) {
  fs.rmSync(stop,{force:true});
  const r=run([verb]);
  check(r.status!==0 && r.stderr.includes('open exact sentinel service; no fallback'),verb+' missing-service refusal');
  check(!fs.existsSync(stop) && !fs.existsSync(path.join(state,'sentinel.pid')),verb+' changed lifecycle state');
  check(fs.readFileSync(pending,'utf8')===bytes,verb+' changed original queue');
}
fs.writeFileSync(stop,'original intentional stop\n');
refused=run(['start']);
check(refused.status!==0 && fs.readFileSync(stop,'utf8')==='original intentional stop\n','refused start removed stop intent');
const logs=Object.fromEntries(fs.readdirSync(root).filter(name=>/\.(stdout|stderr)$/.test(name)).map(name=>[name,sha256(path.join(root,name))]));
const receipt={ok:true,checks,skipped:0,scm_effects:0,binary_sha256:sha256(binary),log_sha256:logs,scope:'private config/console/absent-service CLI boundaries; live SCM recovery unverified',evidence:root};
fs.writeFileSync(path.join(root,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({...receipt,log_sha256:undefined}));
