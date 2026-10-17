// Real unpaired service/owner provisioning/Node CLI process negatives, synthetic state only.
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import net from 'node:net';
import {connectorRequest} from './mcp-whatsapp.mjs';
const binary=resolve(process.argv[2]);const root=mkdtempSync(join(tmpdir(),'wa-operator-unpaired-'));
const state=join(root,'state'),owners=join(root,'owners'),account='100@s.whatsapp.net';
const run=(action,args=[])=>spawnSync(binary,[action,'--state',state,...args],{encoding:'utf8',timeout:10000});
let service;try{
 assert.equal(run('init',['--account',account,'--all-chats']).status,0);
 assert.notEqual(run('operator-enable',['--chats',account]).status,0,'no default write provisioning');
 assert.equal(run('operator-enable',['--chats',account,'--approve-operator-management']).status,0);
 assert.notEqual(run('operator-enable',['--chats',account,'--approve-operator-management']).status,0,'no silent rotation');
 const socket=net.createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;await new Promise(r=>socket.close(r));
 service=spawn(binary,['serve','--state',state,'--owners',owners,'--listen',`127.0.0.1:${port}`],{stdio:['ignore','pipe','pipe']});let logs='';service.stdout.on('data',b=>logs+=b);service.stderr.on('data',b=>logs+=b);
 const binding={backend:'linked_device',account,generation:1,allowed_conversations:[account],connector_url:`http://127.0.0.1:${port}/`,token_file:join(state,'api.token')};
 let status;for(let n=0;n<80;n++){try{status=await connectorRequest(binding,'status');break;}catch{if(service.exitCode!==null)throw Error('synthetic service exited');await new Promise(r=>setTimeout(r,50));}}
 assert.equal(status?.connection,'needs_pairing');assert.equal(status.config.requested_on,false);assert.equal(status.operator_unknown_sends_all_generations,0);
 assert.equal((await connectorRequest(binding,'operator/prepare',{conversation_id:account,body:'not sent'})).error,'operator_capability_required');
 const config=join(root,'authority.json'),request=join(root,'request.json');
 writeFileSync(config,JSON.stringify({kind:'whatsapp-operator-v1',account,generation:1,conversations:[account],connector_url:binding.connector_url,dispatch_token_file:join(state,'operator-dispatch.token')}),{mode:0o600});
 writeFileSync(request,JSON.stringify({conversation_id:account,body:'unpaired never sends'}),{mode:0o600});
 const cli=spawnSync(process.execPath,[resolve('scripts/whatsapp-operator.mjs'),'prepare','--authority-file',config,'--request-file',request],{encoding:'utf8',timeout:10000});assert.notEqual(cli.status,0);assert.equal(JSON.parse(cli.stdout).error,'operator_identity_unproven');
 assert.equal(logs,'','no protocol/credential logging');for(const name of ['api.token','operator-dispatch.token','operator-approval.token'])assert.equal((cli.stdout+cli.stderr+logs).includes(readFileSync(join(state,name),'utf8')),false);
 console.log('operator real unpaired owner/CLI/HTTP process negatives passed; zero real login/sends');
}finally{if(service&&service.exitCode===null)await new Promise(r=>{service.once('close',r);service.kill();});rmSync(root,{recursive:true,force:true});}
