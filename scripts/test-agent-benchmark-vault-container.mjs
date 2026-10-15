// Actual two-container, synthetic-only isolation proof using exact cached images.
// No pull/build, bind mounts, host credentials, Docker socket or solver inference.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {createGeneration, record, requiredRecords, dockerResource, seal, verifyBundle, cleanupDocker, cleanup} from './agent-benchmark-results.mjs';
import {realDockerAdapter} from './agent-benchmark-docker.mjs';
import {readModelRouteJournal} from './agent-benchmark-model-route.mjs';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [out, imageId] = process.argv.slice(2);
assert(out && path.isAbsolute(out) && !fs.existsSync(out) && /^sha256:[a-f0-9]{64}$/.test(imageId), 'fresh evidence and exact cached image required');
fs.mkdirSync(out, {recursive: true}); const root = path.join(out, 'g'); createGeneration(root, 'vault-container-proof');
const records = path.join(root, 'records'); let checks = 0;
const check = (v, m) => { assert(v, m); checks++; };
const cli = args => {
  const r = cp.spawnSync('docker', args, {encoding: 'utf8', timeout: 15000, maxBuffer: 8 * 1024 * 1024});
  fs.appendFileSync(path.join(records, 'inspect-cli.jsonl'), JSON.stringify({args, code: r.status, stdout: r.stdout, stderr: r.stderr, error: r.error?.code ?? null}) + '\n');
  assert(r.status === 0 && !r.error, 'Docker readback failed'); return r.stdout;
};
const arms = ['pi', 'wasm-current', 'node-v1', 'rust-v2'].map(arm => ({arm, handle: crypto.randomBytes(32).toString('hex'),
  maxRequests: 2, maxPromptTotal: 1000, maxOutputTotal: 1000, maxMilliseconds: 30000}));
const sources = Object.fromEntries(['scripts/agent-benchmark-model-route.mjs', 'vault/wa_vault.py', 'scripts/fixtures/benchmark-vault.py']
  .map(p => [path.basename(p), fs.readFileSync(path.join(repo, p), 'utf8')]));
const packed = zlib.gzipSync(Buffer.from(JSON.stringify(sources))).toString('base64');
// Runs only trusted transport/vault and fake provider. No secret is installed in
// the client command/env/image; synthetic store exists only in trusted /tmp.
const service = `(async()=>{
 const fs=require('fs'),http=require('http'),cp=require('child_process'),z=require('zlib');
 const sources=JSON.parse(z.gunzipSync(Buffer.from(${JSON.stringify(packed)},'base64')));
 for(const [name,body] of Object.entries(sources))fs.writeFileSync('/tmp/'+name,body);
 const routeModule=await import('file:///tmp/agent-benchmark-model-route.mjs');
 let received=0;const provider=http.createServer(async(req,res)=>{const chunks=[];for await(const b of req)chunks.push(b);const body=JSON.parse(Buffer.concat(chunks));
  if(req.headers.authorization!=='Bearer BENCHMARK_SYNTHETIC_ACCESS_ONLY'||req.headers.cookie||req.headers.host!=='127.0.0.1:'+provider.address().port)throw Error('vault header fence');
  received++;res.writeHead(200,{'content-type':'text/event-stream'});res.end('data: '+JSON.stringify({type:'response.completed',response:{status:'completed',usage:{input_tokens:100,output_tokens:20,input_tokens_details:{cached_tokens:40},output_tokens_details:{reasoning_tokens:5}}}})+'\\n\\n');});
 await new Promise(r=>provider.listen(0,'127.0.0.1',r));
 const child=cp.spawn('python3',['-B','/tmp/benchmark-vault.py','/tmp/wa_vault.py','/tmp/vault-data','http://127.0.0.1:'+provider.address().port],{env:{PATH:process.env.PATH},stdio:['ignore','pipe','pipe']});
 let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);const closed=new Promise(r=>child.on('close',r));
 let ready;for(let i=0;i<300;i++){try{ready=JSON.parse(stdout.trim().split('\\n')[0]);}catch{}if(ready)break;await new Promise(r=>setTimeout(r,10));}if(!ready)throw Error('actual synthetic vault did not start');
 const route=routeModule.createVaultSubscriptionRoute({vaultUrl:'http://127.0.0.1:'+ready.port,root:'/tmp/route',arms:${JSON.stringify(arms)}});
 await new Promise(r=>route.server.listen(8090,'0.0.0.0',r));
 console.log(JSON.stringify({ready:true,vaultPort:ready.port}));
 process.on('SIGTERM',async()=>{route.dispose();await new Promise(r=>route.server.close(r));child.kill();await closed;provider.closeAllConnections();await new Promise(r=>provider.close(r));
  const captures=Object.fromEntries(fs.readdirSync('/tmp/route').map(n=>[n,fs.readFileSync('/tmp/route/'+n).toString('base64')]));
  console.log(JSON.stringify({complete:true,received,states:route.inspect(),captures,vault_stdout:stdout,vault_stderr:stderr}));process.exit(0);});
})().catch(e=>{console.error(e);process.exit(1);});`;
const base = realDockerAdapter(root, {imageId});
const network = dockerResource(root, 'network', base);
const trustedAdapter = realDockerAdapter(root, {imageId, networkId: network, command: ['node', '-e', service]});
let trusted, client, clientAdapter;
try {
  trusted = dockerResource(root, 'container', trustedAdapter); trustedAdapter.start(trusted);
  let ready;
  for (let i = 0; i < 50; i++) {
    const logs = trustedAdapter.logs(trusted); for (const line of logs.split('\n')) { try { const x = JSON.parse(line); if (x.ready) ready = x; } catch {} }
    if (ready) break; await new Promise(r => setTimeout(r, 100));
  }
  check(ready?.ready, 'actual trusted vault/relay/fake provider ready');
  const trustedInspect = JSON.parse(cli(['inspect', trusted]))[0];
  const ip = trustedInspect.NetworkSettings.Networks[network]?.IPAddress
    || Object.values(trustedInspect.NetworkSettings.Networks)[0]?.IPAddress;
  assert(ip, 'exact private trusted address');
  const clientProgram = `(async()=>{const fs=require('fs'),assert=require('assert/strict');let checks=0;const check=(v,m)=>{assert(v,m);checks++;};
   check(!Object.values(process.env).some(v=>v.includes('BENCHMARK_SYNTHETIC')),'no credential env');
   for(const p of ['/tmp/vault-data/vault.json','/data/vault.json','/var/run/docker.sock'])check(!fs.existsSync(p),'no shared vault store/socket');
   const proc=fs.readdirSync('/proc').filter(n=>/^\\d+$/.test(n)&&Number(n)!==process.pid).map(n=>{try{return fs.readFileSync('/proc/'+n+'/cmdline','utf8');}catch{return '';}}).join(' ');
   check(!proc.includes('benchmark-vault.py')&&!proc.includes('SYNTHETIC_ACCESS_ONLY'),'no trusted PID namespace');
   try{await fetch('http://${ip}:'+${ready.vaultPort}+'/status',{signal:AbortSignal.timeout(1000)});assert.fail('private vault exposed');}catch(e){if(e.code==='ERR_ASSERTION')throw e;checks++;}
   for(const a of ${JSON.stringify(arms)}){const response=await fetch('http://${ip}:8090/arms/'+a.handle+'/openai-sub/codex/responses',{method:'POST',headers:{authorization:'Bearer CLIENT_PLACEHOLDER',cookie:'must-not-forward',host:'evil.invalid'},body:JSON.stringify({model:'gpt-6.1-sol',reasoning:{effort:'low'},stream:true,input:[{role:'user',content:'deterministic probe'}]})});
    const text=await response.text();check(response.status===200&&text.includes('response.completed')&&!text.includes('SYNTHETIC_ACCESS_ONLY'),'four-arm synthetic response only');}
   check((await fetch('http://${ip}:8090/login/openai-sub',{method:'POST',body:'{}'})).status===404,'no credential mutation door');
   console.log(JSON.stringify({ok:true,checks,paid_solver_calls:0}));})().catch(e=>{console.error(e);process.exit(1);});`;
  clientAdapter = realDockerAdapter(root, {imageId, networkId: network, command: ['node', '-e', clientProgram]});
  client = dockerResource(root, 'container', clientAdapter); clientAdapter.start(client);
  for (let n = 0; n < 50 && clientAdapter.inspect(client).running; n++) await new Promise(r => setTimeout(r, 100));
  clientAdapter.drain(client);
  const clientInspect = JSON.parse(cli(['inspect', client]))[0];
  check(clientInspect.State.ExitCode === 0, 'isolated client completed normally');
  const clientResult = JSON.parse(clientAdapter.logs(client).split('\n').find(line => line.startsWith('{')));
  check(clientResult.ok && clientResult.checks === 11, 'isolated client checks counted');
  trustedAdapter.stop(trusted);
  const logs = trustedAdapter.logs(trusted);
  const snapshot = logs.split('\n').map(line => { try { return JSON.parse(line); } catch { return null; } }).find(x => x?.complete);
  check(snapshot?.received === 4, 'exactly four fake provider requests through actual vault');
  const retained = path.join(records, 'route'); fs.mkdirSync(retained);
  for (const [name, value] of Object.entries(snapshot.captures)) { assert(/^[a-zA-Z0-9._-]+$/.test(name)); fs.writeFileSync(path.join(retained, name), Buffer.from(value, 'base64')); }
  check(readModelRouteJournal(retained).complete_provider_usage, 'all raw container attempt captures verified after drain');
  check(readModelRouteJournal(retained).prompt_total === 400, 'four-arm fake usage without double counting');
  for (const x of [trustedInspect, clientInspect]) {
    check(x.Image === imageId && x.Mounts.every(m => m.Type === 'tmpfs') && !x.HostConfig.Privileged
      && !['host', 'container'].some(p => x.HostConfig.PidMode.startsWith(p)) && !x.HostConfig.Binds?.length
      && x.HostConfig.ReadonlyRootfs && x.HostConfig.CapDrop.includes('ALL'), 'no shared mounts/host PID/privilege; read-only exact image');
  }
  check(JSON.parse(cli(['network', 'inspect', network]))[0].Internal === true, 'generation-private internal network');
  fs.writeFileSync(path.join(records, 'receipt.json'), JSON.stringify({ok: true, checks, client_checks: clientResult.checks, skipped: 0,
    imageId, trusted, client, network, isolation: 'two unprivileged containers, private PID/mount namespaces, no shared store/admin/socket; trusted vault loopback only',
    actual_cost: null, paid_solver_calls: 0, actual_provider_acceptance: false}, null, 2));
  for (const kind of requiredRecords) record(root, kind, {kind, scope: 'synthetic transport/container proof, NOT solver comparison', receipt: 'receipt.json', real_solver_calls: 0});
  seal(root); const bundle = verifyBundle(root); assert(bundle.lossless);
  const removed = cleanupDocker(root, base); check(removed.length === 3, 'exact generation resources removed after seal/verify');
  const cleaned = cleanup(root); assert(cleaned.ok);
  assert(JSON.parse(cliAfter(['image', 'inspect', imageId]))[0].Id === imageId, 'shared image retained');
  fs.writeFileSync(path.join(out, 'receipt.json'), JSON.stringify({ok: true, checks, client_checks: clientResult.checks, skipped: 0, bundle, removed, cleanup: cleaned, imageId, shared_image_preserved: true}, null, 2));
  console.log(JSON.stringify({ok: true, checks, client_checks: clientResult.checks, skipped: 0, evidence: out}));
} catch (error) {
  // Preserve failed generations. Cancel only known running, exactly-owned resources;
  // uncertain Docker effects are not replayed or swept.
  for (const [id, a] of [[client, clientAdapter], [trusted, trustedAdapter]]) {
    if (id && a?.inspect(id).running) a.stop(id);
  }
  throw error;
}
function cliAfter(args) {
  const r = cp.spawnSync('docker', args, {encoding: 'utf8', timeout: 15000});
  fs.appendFileSync(path.join(out, 'post-cleanup.jsonl'), JSON.stringify({args, code: r.status, stdout: r.stdout, stderr: r.stderr}) + '\n');
  assert.equal(r.status, 0); return r.stdout;
}
