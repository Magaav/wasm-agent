// Required UI suite, one explicit invocation, private environment and staged UI only.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawn,execFileSync}=require('node:child_process'),{finished}=require('node:stream/promises');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=fs.mkdtempSync(path.join(os.tmpdir(),'wa-provider-required-ui-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(key)));
async function freePort(){const server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));return port;}
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const git=(...args)=>execFileSync('git',args,{cwd:root,encoding:'utf8'}).trim();
const sourcePaths=['scripts/test-ui.ps1','scripts/test-provider-required-ui.cjs','scripts/test-provider-management-ui.cjs','scripts/probe-provider-management.js','scripts/probe-vault-management.js','lua/core/provider_management.lua','lua/core/provider.lua','lua/core/vault.lua','lua/core/server.lua','rust/wa-host/src/serve.rs','ui/index.html','ui/app.js','ui/components.js','ui/style.css','ui/render.wasm','ui/test-fixtures.js','vault/wa_vault.py','vault/page/app.js','vault/page/index.html','vault/page/embed-go.html','vault/page/embed-go.js','vault/page/embed-go.css','scripts/test-provider-inline-browser.cjs','scripts/test-vault-embed.py','scripts/migrate-go-vault.py'];
function snapshot(){return{commit:git('rev-parse','HEAD'),tree:git('rev-parse','HEAD^{tree}'),status:git('status','--porcelain'),binary_sha256:hash(binary),sources:Object.fromEntries(sourcePaths.map(p=>[p,hash(root+'/'+p)]))};}
async function main(){const port=await freePort(),client=await freePort();console.log('Evidence: '+out);const before=snapshot();assert.equal(before.status,'','final UI suite requires committed clean source');
 const child=spawn('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File',root+'/scripts/test-ui.ps1','-WaExe',binary,'-UiDirectory',root+'/ui','-Port',String(port),'-ClientPort',String(client),'-KeepEvidence'],{cwd:root,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
 const stdout=fs.createWriteStream(out+'/stdout'),stderr=fs.createWriteStream(out+'/stderr');child.stdout.pipe(stdout);child.stderr.pipe(stderr);
 child.stdout.on('data',b=>process.stdout.write(b));child.stderr.on('data',b=>process.stderr.write(b));
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal}));});
 await Promise.all([finished(stdout),finished(stderr)]);
 const after=snapshot(),unchanged=JSON.stringify(before)===JSON.stringify(after);
 const log=fs.readFileSync(out+'/stdout','utf8');
 const uiEvidence=log.match(/evidence retained:\s*(.+)/)?.[1]?.trim() || null;
 fs.writeFileSync(out+'/receipt.json',JSON.stringify({...result,binary,port,client,before,after,source_unchanged:unchanged,ui_evidence:uiEvidence,stdout_sha256:hash(out+'/stdout'),stderr_sha256:hash(out+'/stderr'),required_ui_verified:result.code===0&&unchanged,full_release_gate:false},null,2)+'\n');assert(unchanged,'source or binary changed during UI suite');assert.equal(result.code,0,'required UI suite failed; inspect retained evidence');}
main().catch(error=>{console.error(error);process.exitCode=1;});
