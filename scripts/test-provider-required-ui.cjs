// Required UI suite, one explicit invocation, private environment and staged UI only.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),assert=require('node:assert/strict'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),binary=path.resolve(process.argv[2]||'rust/target/debug/wa.exe'),out=fs.mkdtempSync(path.join(os.tmpdir(),'wa-provider-required-ui-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!/^(WA_|WASM_AGENT_|OPENAI_|OPENCODE_|PI_)/i.test(key)));
async function freePort(){const server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));return port;}
async function main(){const port=await freePort(),client=await freePort();console.log('Evidence: '+out);
 const child=spawn('powershell',['-NoProfile','-ExecutionPolicy','Bypass','-File',root+'/scripts/test-ui.ps1','-WaExe',binary,'-UiDirectory',root+'/ui','-Port',String(port),'-ClientPort',String(client),'-KeepEvidence'],{cwd:root,env,windowsHide:true,stdio:['ignore','pipe','pipe']});
 const stdout=fs.createWriteStream(out+'/stdout'),stderr=fs.createWriteStream(out+'/stderr');child.stdout.pipe(stdout);child.stderr.pipe(stderr);
 child.stdout.on('data',b=>process.stdout.write(b));child.stderr.on('data',b=>process.stderr.write(b));
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal}));});
 fs.writeFileSync(out+'/receipt.json',JSON.stringify({...result,binary,port,client,full_release_gate:false}));assert.equal(result.code,0,'required UI suite failed; inspect retained evidence');}
main().catch(error=>{console.error(error);process.exitCode=1;});
