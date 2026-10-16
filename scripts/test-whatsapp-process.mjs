// Real executable + SQLite + HTTP lifecycle, entirely unpaired/private. No WhatsApp network connect.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import net from 'node:net';
import {connectorRequest} from './mcp-whatsapp.mjs';
const binary=resolve(process.argv[2]||'target/wa-whatsapp.exe');
const root=mkdtempSync(join(tmpdir(),'wa-real-unpaired-'));
const state=join(root,'state'),owners=join(root,'owners');
const account='100@s.whatsapp.net',chat='200@s.whatsapp.net';
const run=(command,args=[])=>spawnSync(binary,[command,'--state',state,...args],{encoding:'utf8',timeout:10000});
let child;
async function stop(){if(!child)return;const current=child;child=undefined;if(current.exitCode!==null)return;await new Promise(r=>{current.once('close',r);current.kill();});}
async function start(){
 const reservation=net.createServer();await new Promise(r=>reservation.listen(0,'127.0.0.1',r));const port=reservation.address().port;await new Promise(r=>reservation.close(r));
 child=spawn(binary,['serve','--state',state,'--owners',owners,'--listen',`127.0.0.1:${port}`],{stdio:['ignore','pipe','pipe']});let logs='';child.stdout.on('data',b=>logs+=b);child.stderr.on('data',b=>logs+=b);
 const binding={backend:'linked_device',account,generation:1,allowed_conversations:[chat],connector_url:`http://127.0.0.1:${port}`,token_file:join(state,'api.token')};
 let status;for(let i=0;i<60;i++){if(child.exitCode!==null)throw Error('private service exited: '+logs);try{status=await connectorRequest(binding,'status');break;}catch{await new Promise(r=>setTimeout(r,50));}}
 assert.ok(status?.ok,'private service did not start');assert.equal(status.connection,'needs_pairing');assert.equal(status.config.requested_on,false);assert.equal(status.config.all_chats,true);
 const accountPage=await connectorRequest({...binding,allowed_conversations:[],account_wide:true,operator_account_read:true},'read_snapshot',{account_wide:true,limit:1});assert.equal(accountPage.limit_scope,'total');assert.equal(accountPage.source_state.connection,'needs_pairing');
 assert.equal((await connectorRequest(binding,'read_snapshot',{})).ok,false,'wide reads require explicit request authority');
 assert.equal((await connectorRequest({...binding,generation:2},'status')).ok,false);
 assert.equal((await connectorRequest(binding,'lookup_self')).error,'paired_identity_unproven');
 const second=run('serve',['--owners',owners,'--listen',`127.0.0.1:${port+1}`]);assert.notEqual(second.status,0);assert.match(second.stderr,/account_owner_busy/);
 assert.equal(logs,'','unpaired service must not emit protocol/key/QR logs');return status;
}
try{
 const init=run('init',['--account',account,'--all-chats']);assert.equal(init.status,0,init.stderr);
 assert.equal(JSON.parse(run('status').stdout).config.language,'en');
 const capture=run('pair',['--owners',owners]);assert.notEqual(capture.status,0);assert.match(capture.stderr,/private_interactive_tty_no_capture/);assert.equal(capture.stdout,'');
 await start();await stop();
 assert.equal(run('language',['--language','pt']).status,0);
 const after=await start();assert.equal(after.config.language,'pt');await stop();
 assert.equal(run('activate',['--approve-transcript-posting']).status,1);
 console.log('whatsapp real unpaired process ok (EN/PT persistence, HTTP auth/generation, owner exclusion, non-TTY pairing refusal; zero real pairing/sends)');
}finally{await stop();rmSync(root,{recursive:true});}
