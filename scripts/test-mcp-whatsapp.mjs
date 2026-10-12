// Full MCP → existing app-store driver against a private real CDP/WebSocket peer.
// No live browser, third-party send, paid inference or persistent watcher.
import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';
import {createServer} from 'node:http';import {createHash} from 'node:crypto';import {mkdtempSync,readFileSync} from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {fileURLToPath} from 'node:url';
import {requestMCP} from './mcp-client-core.mjs';
const ACCOUNT='5511999999999@c.us',CHAT='5511888888888@c.us';
function wid(id){return {_serialized:id,toString:()=>id,isGroup:()=>false,isBot:()=>false,isUser:()=>true};}
function frame(text){const bytes=Buffer.from(text);let head;if(bytes.length<126)head=Buffer.from([0x81,bytes.length]);else{head=Buffer.alloc(4);head[0]=0x81;head[1]=126;head.writeUInt16BE(bytes.length,2);}return Buffer.concat([head,bytes]);}
async function fixture(){
 const state={sends:0,reads:0},chats=[ACCOUNT,CHAT].map(id=>({id:wid(id),name:id===ACCOUNT?'Self':'Fixture',unreadCount:2,archive:false,canSend:true,draftMessage:null,urlText:'',urlNumber:'',active:false}));
 const messages=[{id:{_serialized:'false_'+CHAT+'_audio',id:'audio',remote:CHAT,fromMe:false},body:'',t:Math.floor(Date.now()/1000),type:'ptt',mimetype:'audio/ogg; codecs=opus',mediaData:{mediaStage:'RESOLVED'},size:4}];
 const modules={WAWebChatCollection:{ChatCollection:{getModelsArray:()=>chats}},WAWebMsgCollection:{MsgCollection:{getModelsArray:()=>messages}},WAWebUserPrefsMeUser:{getMaybeMePnUser:()=>wid(ACCOUNT),getMaybeMeLidUser:()=>null,isMeAccount:id=>String(id)===ACCOUNT,isSerializedWidMe:id=>String(id)===ACCOUNT},WAWebSendTextMsgChatAction:{sendTextMsgToChat:async(chat,body)=>{state.sends++;messages.push({id:{id:'sent-'+state.sends,remote:String(chat.id),fromMe:true,_serialized:'sent-'+state.sends},body,ack:2,t:Math.floor(Date.now()/1000),type:'chat'});return 'sent-'+state.sends;}},WAWebDownloadManager:{downloadManager:{downloadAndMaybeDecrypt:async()=>Uint8Array.of(1,2,3,4)}}};
 const context=vm.createContext({window:{require:name=>{if(!(name in modules))throw Error('module missing');return modules[name];}},Uint8Array,AbortController,btoa,JSON});
 let endpoint;const sockets=new Set();const server=createServer((req,res)=>{
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify(req.url==='/json/version'?{Browser:'Private Chrome fixture',webSocketDebuggerUrl:endpoint.replace('/page/','/browser/')}:[{id:'private',type:'page',url:'https://web.whatsapp.com/',title:'Private fixture',webSocketDebuggerUrl:endpoint}]));
 });
 server.on('upgrade',(request,socket)=>{
  const accept=createHash('sha1').update(request.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');sockets.add(socket);socket.on('close',()=>sockets.delete(socket));let buffer=Buffer.alloc(0);
  socket.on('data',chunk=>{buffer=Buffer.concat([buffer,chunk]);while(buffer.length>=2){const opcode=buffer[0]&15,masked=!!(buffer[1]&128);let length=buffer[1]&127,at=2;if(length===126){if(buffer.length<4)return;length=buffer.readUInt16BE(2);at=4;}else if(length===127){if(buffer.length<10)return;length=Number(buffer.readBigUInt64BE(2));at=10;}const start=at+(masked?4:0);if(buffer.length<start+length)return;const payload=Buffer.from(buffer.subarray(start,start+length));if(masked)for(let n=0;n<length;n++)payload[n]^=buffer[at+n%4];buffer=buffer.subarray(start+length);if(opcode===8){socket.end(Buffer.from([0x88,0]));return;}if(opcode!==1)continue;const message=JSON.parse(payload.toString());state.reads++;
   Promise.resolve().then(()=>vm.runInContext(message.params.expression,context,{timeout:3000})).then(value=>socket.write(frame(JSON.stringify({id:message.id,result:{result:{type:'string',value}}}))),error=>socket.write(frame(JSON.stringify({id:message.id,result:{exceptionDetails:{text:String(error)}}}))));
  }});
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));endpoint=`ws://127.0.0.1:${server.address().port}/devtools/page/private`;
 return {state,chats,messages,endpoint,async close(){for(const socket of sockets)socket.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}};
}
test('real WhatsApp MCP lifecycle, bound reads/media, draft refusal and verified single send',async()=>{
 const f=await fixture(),cache=mkdtempSync(join(tmpdir(),'mcp-cdp-private-'));process.env.MCP_TEST_APP_HOME=cache;
 const binding={account:ACCOUNT,browser_endpoint:f.endpoint,cache_dir:cache,allowed_conversations:[ACCOUNT,CHAT]};
 const server={transport:'stdio',program:process.execPath,args:[fileURLToPath(new URL('./mcp-whatsapp.mjs',import.meta.url)),'--binding-json',JSON.stringify(binding)],env:{HOME:'MCP_TEST_APP_HOME',LOCALAPPDATA:'MCP_TEST_APP_HOME'},timeout_seconds:12};
 const call=async(tool,args={},bound=binding)=>requestMCP({action:'call',server:{...server,args:[server.args[0],'--binding-json',JSON.stringify(bound)]},tool,arguments:args});
 try{
  const probe=await requestMCP({action:'probe',server});assert.equal(probe.ok,true);assert.equal(f.state.reads,0,'protocol probe never touches the app');
  const self=await call('lookup_self');assert.equal(self.ok,true);assert.equal(self.result.structuredContent.self_id,ACCOUNT);
  const snapshot=await call('read_snapshot',{since:0,limit:10000});assert.equal(snapshot.ok,true,JSON.stringify(snapshot));assert.equal(snapshot.result.structuredContent.messages[0].conversation_id,CHAT);assert.equal(snapshot.result.structuredContent.messages[0].eligibility,undefined,'Jobs, not MCP, chooses eligibility');
  const inspected=await call('inspect_chat',{conversation_id:CHAT});assert.equal(inspected.ok,true,JSON.stringify(inspected));assert.equal(inspected.result.structuredContent.target.unread,2);assert.equal(f.chats[1].unreadCount,2);
  const audio=await call('download_audio',{conversation_id:CHAT,message_id:'false_'+CHAT+'_audio'});assert.equal(audio.ok,true,JSON.stringify(audio));assert.deepEqual([...readFileSync(audio.result.structuredContent.path)],[1,2,3,4]);
  const wrong=await call('read_snapshot',{}, {...binding,account:'5511777777777@c.us'});assert.equal(wrong.ok,false);assert.equal(wrong.result.structuredContent.error,'whatsapp_account_mismatch');
  const sender={...binding,allow_send:true,reservation_key:'private-already-reserved'};
  f.chats[1].draftMessage={text:'human draft'};const refused=await call('send_message',{conversation_id:CHAT,body:'fixture-only body',confirm:true},sender);assert.equal(refused.ok,false);assert.equal(f.state.sends,0);assert.equal(f.chats[1].draftMessage.text,'human draft');
  f.chats[1].draftMessage=null;const sent=await call('send_message',{conversation_id:CHAT,body:'fixture-only body',confirm:true},sender);assert.equal(sent.ok,true,JSON.stringify(sent));assert.equal(sent.result.structuredContent.verified,true);assert.equal(sent.result.structuredContent.message.body,'fixture-only body');assert.equal(sent.result.structuredContent.message.ack,2);assert.equal(f.state.sends,1);assert.equal(f.chats[1].unreadCount,2,'store send never marks read');assert.equal(f.chats[1].active,false,'no chat opening');
 }finally{await f.close();}
});
