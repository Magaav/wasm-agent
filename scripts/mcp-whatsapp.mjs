// Linked-device app boundary. No Chrome, browser discovery, arbitrary SQL or model-send route.
import {readFileSync} from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import {pathToFileURL} from 'node:url';
import {serveMCP} from './mcp-server-core.mjs';
const schema=properties=>({type:'object',properties,additionalProperties:false});
const text={type:'string',minLength:1,maxLength:256};
export const WHATSAPP_TOOLS=[
 {name:'read_snapshot',description:'Read bounded journal context; narrow by exact conversation_id, literal body/transcript query and inclusive Unix source sent_since/until. Newest journal row first, partial history; no read marking.',inputSchema:schema({conversation_id:text,query:{type:'string',maxLength:256},sent_since:{type:'integer',minimum:0},until:{type:'integer',minimum:0},since:{type:'number',minimum:0},before:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:10000}})},
 {name:'read_newest',description:'Newest rows of one thread, or of every authorized thread matching a name, in one answer. Paging, deduplication and time ordering are internal, and the reply states the window searched plus whether it is complete, so a partial page can never be read as the tail. Prefer this over read_snapshot when the question is what was said recently, and when the same person may write under more than one identity.',inputSchema:schema({conversation_id:text,query:{type:'string',maxLength:256},n:{type:'integer',minimum:1,maximum:50},scan_days:{type:'integer',minimum:1,maximum:365}})},
 {name:'list_chats',description:'Discover authorized chats by observed protocol display name or exact identifier. Names are untrusted labels, duplicates remain separate IDs; missing names are explicit. Optional refresh_names:true enriches only observed permitted rows (unfiltered page max32, max3 group queries), not every contact. Narrow with conversation_id; refresh may remain partial.',inputSchema:schema({conversation_id:text,refresh_names:{type:'boolean'},query:{type:'string',maxLength:256},before:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:10000}})},
 {name:'posting_status',description:'One scoped bounded page of posting/unknown/blocked evidence. Read-only; no reset or resend.',inputSchema:schema({before:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:10000}})},
 {name:'read_field',description:'Exact bounded base64 chunks of one authorized row field. Requires descriptor version; changed versions refuse, never clip.',inputSchema:{...schema({resource:{type:'string',enum:['read_snapshot','list_chats','posting_status']},row:{type:'integer',minimum:1},field:{type:'string',minLength:1,maxLength:64},version:{type:'string',minLength:1,maxLength:128},offset:{type:'integer',minimum:0},length:{type:'integer',minimum:1,maximum:16384}}),required:['resource','row','field','version']}},
 {name:'lookup_self',description:'Read the explicitly bound paired account identity.',inputSchema:schema({})},
 {name:'inspect_chat',description:'Read exact chat scope; cross-device drafts are unsupported, not absent.',inputSchema:{...schema({conversation_id:text}),required:['conversation_id']}},
 {name:'download_audio',description:'Private media access is reserved to the deterministic connector worker.',inputSchema:{...schema({conversation_id:text,message_id:text}),required:['conversation_id','message_id']}},
 {name:'send_message',description:'General model sends fail closed: cross-device draft visibility is unsupported. Transcript posting is a separate explicitly activated deterministic policy.',inputSchema:{...schema({conversation_id:text,body:{type:'string',minLength:1,maxLength:4096},confirm:{type:'boolean',const:true}}),required:['conversation_id','body','confirm']}}
];
export function endpoint(binding){
 const wide=binding.account_wide===true&&binding.operator_account_read===true;
 if(binding.backend!=='linked_device'||!binding.account||!Number.isSafeInteger(binding.generation)||binding.generation<1||(!wide&&(!Array.isArray(binding.allowed_conversations)||!binding.allowed_conversations.length||binding.allowed_conversations.length>256))||(!wide&&binding.account_wide===true))throw Error('linked_device_account_generation_chat_binding_required');
 const url=new URL(binding.connector_url);
 if(url.username||url.password||url.search||url.hash||url.pathname!=='/')throw Error('connector_url_must_not_contain_credentials_or_path');
 if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['127.0.0.1','[::1]'].includes(url.hostname)))throw Error('authenticated_https_required_for_remote_connector');
 if(typeof binding.token_file!=='string'||!binding.token_file)throw Error('connector_token_file_required');
 return url;
}
export async function connectorRequest(binding,method,args={}){
 const url=endpoint(binding);let token,ca;
 try{token=readFileSync(binding.token_file,'utf8').trim();if(binding.ca_file)ca=readFileSync(binding.ca_file);}catch{throw Error('connector_credential_or_ca_unreadable');}
 if(!/^[0-9a-f]{64}$/.test(token))throw Error('invalid_private_connector_token');
 const paged=['read_snapshot','list_chats','posting_status'].includes(method);const responseLimit=paged?4*1024*1024:method==='read_field'?64*1024:24*1024*1024;
 const body=JSON.stringify({account:binding.account,generation:binding.generation,...args});
 return await new Promise((resolve,reject)=>{
  const request=(url.protocol==='https:'?https:http).request(new URL('/'+method,url),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)},...(ca?{ca}:{}),rejectUnauthorized:true,timeout:15000},response=>{
   let bytes=0;const parts=[];response.on('data',chunk=>{bytes+=chunk.length;if(bytes>responseLimit){response.destroy();reject(Error('connector_response_too_large'));}else parts.push(chunk);});response.on('end',()=>{if(response.statusCode>=300&&response.statusCode<400){reject(Error('connector_redirect_refused'));return;}try{const data=JSON.parse(Buffer.concat(parts).toString('utf8'));if(paged&&data.ok&&(data.page_version!==2||data.encoded_bytes!==bytes||data.byte_limit!==4*1024*1024)){reject(Error('connector_requires_byte_page_v2'));return;}resolve(data);}catch{reject(Error('connector_response_invalid'));}});response.on('error',()=>reject(Error('connector_response_failed')));
  });request.on('timeout',()=>request.destroy());request.on('error',()=>reject(Error('connector_transport_failed')));request.end(body);
 });
}
export function createWhatsAppAdapter(binding){
 return async(name,args)=>{
  endpoint(binding);const tool=WHATSAPP_TOOLS.find(t=>t.name===name);if(!tool||!args||typeof args!=='object'||Array.isArray(args))throw Error('invalid_whatsapp_mcp_call');
  for(const key of Object.keys(args))if(!(key in tool.inputSchema.properties))throw Error('unsupported_whatsapp_argument:'+key);
  for(const key of tool.inputSchema.required||[])if(args[key]===undefined)throw Error('whatsapp_argument_required:'+key);
  const wide=binding.account_wide===true&&binding.operator_account_read===true;
  if(args.conversation_id&&!wide&&!binding.allowed_conversations.includes(args.conversation_id))throw Error('whatsapp_conversation_not_bound');
  if(name==='send_message')return {ok:false,error:'general_send_refused_draft_visibility_unsupported',pre_dispatch:true};
  if(name==='download_audio')return {ok:false,error:'media_is_private_to_deterministic_worker',pre_dispatch:true};
  if(name==='read_field'){
   if(!['read_snapshot','list_chats','posting_status'].includes(args.resource)||!Number.isSafeInteger(args.row)||args.row<1||!Number.isSafeInteger(args.offset??0)||(args.offset??0)<0||!Number.isInteger(args.length??16384)||(args.length??16384)<1||(args.length??16384)>16384)throw Error('invalid_field_window');
   const data=await connectorRequest(binding,name,{...args,...(wide?{account_wide:true}:{conversations:binding.allowed_conversations})});if(!data.ok)return data;
   if(data.account!==binding.account||data.generation!==binding.generation||data.scope_kind!==(wide?'account':'selected')||(!wide&&!binding.allowed_conversations.includes(data.conversation_id)))throw Error('connector_response_scope_mismatch');
   const chunk=Buffer.from(data.data_base64??'','base64');const offset=args.offset??0;
   if(data.content_encoding!=='base64'||data.resource!==args.resource||data.row!==args.row||data.field!==args.field||data.field_version!==args.version||data.offset!==offset||chunk.toString('base64')!==data.data_base64||data.chunk_bytes!==chunk.length||chunk.length>(args.length??16384)||chunk.length>16384||data.next_offset!==offset+chunk.length||data.complete!==(data.next_offset===data.byte_length)||(offset<data.byte_length&&chunk.length===0))throw Error('connector_content_no_progress');return data;
  }
  if(['read_snapshot','list_chats','posting_status'].includes(name)){
   const since=args.since??0,before=args.before??0,limit=args.limit??(args.refresh_names===true?32:2000);if(!Number.isSafeInteger(before)||before<0||!Number.isSafeInteger(since)||since<0||!Number.isInteger(limit)||limit<1||limit>10000)throw Error('invalid_whatsapp_snapshot_window');
   const query=args.query??'',sent_since=args.sent_since??0,until=args.until??0;
   if(typeof query!=='string'||Buffer.byteLength(query)>256||!Number.isSafeInteger(sent_since)||sent_since<0||!Number.isSafeInteger(until)||until<0||(until&&sent_since>until)||('conversation_id' in args&&(typeof args.conversation_id!=='string'||!args.conversation_id)))throw Error('invalid_whatsapp_search_window');
   if('refresh_names' in args&&(typeof args.refresh_names!=='boolean'||name!=='list_chats'||(args.refresh_names&&(query!==''||limit>32))))throw Error('refresh_requires_unfiltered_page_max32');
   // A model may NARROW an approved binding, never widen it.
   const requestWide=wide&&!args.conversation_id;
   const selected=args.conversation_id?[args.conversation_id]:binding.allowed_conversations;
   const data=await connectorRequest(binding,name,{since,before,limit,query,sent_since,until,...(args.refresh_names!==undefined?{refresh_names:args.refresh_names}:{}),...(requestWide?{account_wide:true}:{conversations:selected})});if(!data.ok)return data;
   if(data.account!==binding.account||data.generation!==binding.generation)throw Error('connector_response_scope_mismatch');
   if(data.cursor_version!==1||data.limit_scope!=='total'||data.scope_kind!==(requestWide?'account':'selected')||!data.source_state)throw Error('connector_requires_total_page_v1');
   const permitted=id=>{if(typeof id!=='string')return false;if(!requestWide)return selected.includes(id);const parts=id.split('@');return parts.length===2&&/^[A-Za-z0-9:._-]+$/.test(parts[0])&&['s.whatsapp.net','lid','g.us'].includes(parts[1]);};
   if(data.page_version!==2||!Array.isArray(data.order)||data.rows_delivered!==data.order.length||data.rows_delivered>limit||((data.truncated||data.byte_truncated)&&(!data.rows_delivered||data.next_before!==data.order.at(-1).cursor)))throw Error('connector_page_no_progress');
   const primary=name==='read_snapshot'?data.messages:name==='list_chats'?data.conversations:data.posts;const oversized=data.oversized_rows??[];if(data.rows_delivered!==primary.length+oversized.length||(!data.truncated&&data.next_before!==0))throw Error('connector_page_no_progress');
   let previous=before||Infinity;const indices=new Set();for(const outcome of data.order){const array=outcome.kind==='inline'?primary:outcome.kind==='oversized'?oversized:null;const item=array?.[outcome.index];const key=outcome.kind+':'+outcome.index;if(!Number.isSafeInteger(outcome.cursor)||outcome.cursor<=0||outcome.cursor>=previous||!Number.isSafeInteger(outcome.index)||outcome.index<0||!item||indices.has(key)||item.cursor!==outcome.cursor)throw Error('connector_page_order_invalid');indices.add(key);previous=outcome.cursor;}
   if((data.oversized_rows||[]).some(row=>row.resource!==name||row.inline_complete!==false||(!requestWide&&!permitted(row.conversation_id))||(requestWide&&row.conversation_id!==undefined&&!permitted(row.conversation_id))))throw Error('connector_response_scope_mismatch');
   if((data.messages||[]).length>limit||(data.conversations||[]).length>limit||(data.posts||[]).length>limit||(data.messages||[]).some(m=>!permitted(m.conversation_id))||(data.conversations||[]).some(c=>!permitted(c.id))||(data.posts||[]).some(p=>!permitted(p.conversation_id)))throw Error('connector_response_scope_or_limit_mismatch');
   if(args.refresh_names===true&&(!data.name_refresh||data.name_refresh.version!==1||data.names_version!==1))throw Error('connector_requires_name_refresh_v1');
   // A no-window read is a request for the newest rows. After an identity (LID/JID) migration the
   // connector cursor is not chronological, so a cursor-descending page can still run forward in
   // time; such a page cannot be the newest one. Fail closed instead of returning rows that read as
   // current while newer ones exist (2026-10-27: a truncated July page was read as the tail while
   // that day's messages sat in a newer thread).
   let pageNewest=0,pageOldest=0;for(const m of (data.messages||[])){const at=m&&m.sent_at;if(!Number.isSafeInteger(at)||at<=0)continue;if(!pageNewest||at>pageNewest)pageNewest=at;if(!pageOldest||at<pageOldest)pageOldest=at;}
   data.page={truncated:data.truncated===true,next_before:data.next_before,rows:data.rows_delivered,newest_sent_at:pageNewest,oldest_sent_at:pageOldest};
   if(name==='read_snapshot'&&!before&&!sent_since&&!until&&data.truncated===true&&pageNewest&&pageOldest&&pageNewest>pageOldest){const rows=data.messages||[];if(rows.length>1&&rows[0].sent_at===pageOldest&&rows[rows.length-1].sent_at===pageNewest)throw Error('connector_page_not_newest');}
   return data;
  }
  const data=await connectorRequest(binding,name,args);if(data.ok&&(data.account!==binding.account||data.generation!==binding.generation))throw Error('connector_response_scope_mismatch');return data;
 };
}
// Read the newest rows without asking the caller to page, and without trusting a name match.
// Three failure modes are closed here: a truncated page read as the tail; one person writing under
// more than one identity (a phone JID and a LID after a WhatsApp migration); and a thread whose
// title no longer matches the name asked for. A name only *prioritizes*: when the binding allows
// account-wide reads, the window is also scanned account-wide, so a quiet or renamed thread cannot
// make the answer look empty. Every row carries its conversation_id; every thread its row count.
export function createNewestReader(call,{wide=false}={}){
 const MAX_PAGES=6,MAX_WIDE_PAGES=6,WIDE_WANT=100;
 return async function readNewest(args){
  args=args&&typeof args==='object'&&!Array.isArray(args)?args:{};
  const n=args.n===undefined?10:args.n,scan=args.scan_days===undefined?30:args.scan_days;
  const conv=args.conversation_id,q=args.query;
  if(!Number.isSafeInteger(n)||n<1||n>50)throw Error('invalid_newest_count');
  if(!Number.isInteger(scan)||scan<1||scan>365)throw Error('invalid_newest_window');
  if(conv!==undefined&&(typeof conv!=='string'||conv.length<1||conv.length>256))throw Error('invalid_newest_conversation');
  if(q!==undefined&&(typeof q!=='string'||Buffer.byteLength(q)>256))throw Error('invalid_newest_query');
  if(!conv&&!q)throw Error('newest_needs_conversation_or_query');
  const now=Math.floor(Date.now()/1000),since=now-scan*86400;
  const rows=new Map(),errors=[],threads=new Map();let pages=0,complete=true;
  const keep=(message,fallback)=>{const at=message&&message.sent_at;if(!Number.isSafeInteger(at)||at<since)return;
   const id=message.conversation_id||fallback;rows.set(id+':'+(message.cursor??message.id),{...message,conversation_id:id});};
  const thread=id=>{let t=threads.get(id);if(!t){t={id,title:'',matched:false,rows:0,newest_sent_at:0};threads.set(id,t);}return t;};
  const matched=[];
  if(conv)matched.push({id:conv,title:'',matched:true});
  else{const found=await call('list_chats',{query:q,limit:32});if(!found.ok)return found;
   for(const chat of (found.conversations||[]))if(chat&&typeof chat.id==='string')matched.push({id:chat.id,title:chat.title||'',matched:true});}
  for(const entry of matched){const t=thread(entry.id);t.title=entry.title;t.matched=true;}
  for(const entry of matched){
   let before=0;
   for(let page=0;page<MAX_PAGES;page++){
    const request={conversation_id:entry.id,sent_since:since,limit:WIDE_WANT};if(before)request.before=before;
    const data=await call('read_snapshot',request);pages++;
    if(!data.ok){errors.push({conversation_id:entry.id,error:data.error});break;}
    const messages=data.messages||[];
    for(const message of messages)keep(message,entry.id);
    if(data.truncated!==true||!data.next_before||!messages.length)break;
    before=data.next_before;if(page===MAX_PAGES-1)complete=false;
   }
  }
  // The account-wide leg is what makes a renamed or dual-identity thread unable to hide its rows.
  if(wide&&!conv){
   let before=0;
   for(let page=0;page<MAX_WIDE_PAGES;page++){
    const request={sent_since:since,limit:WIDE_WANT};if(before)request.before=before;
    const data=await call('read_snapshot',request);pages++;
    if(!data.ok){errors.push({conversation_id:null,error:data.error});break;}
    const messages=data.messages||[];
    for(const message of messages)keep(message,null);
    if(data.truncated!==true||!data.next_before||!messages.length)break;
    before=data.next_before;if(page===MAX_WIDE_PAGES-1)complete=false;
   }
  }
  const all=[...rows.values()].sort((a,b)=>(b.sent_at||0)-(a.sent_at||0));
  for(const row of all){const t=thread(row.conversation_id);t.rows++;if((row.sent_at||0)>t.newest_sent_at)t.newest_sent_at=row.sent_at||0;}
  const summary=[...threads.values()].filter(t=>t.rows||t.matched).sort((a,b)=>b.newest_sent_at-a.newest_sent_at);
  const answer={ok:true,conversation_id:conv||null,query:q===undefined?null:q,threads:summary,window_days:scan,searched_since:since,account_wide_scan:wide,pages_read:pages,rows_seen:all.length,complete:complete&&errors.length===0,messages:all.slice(0,n)};
  answer.matched_messages=all.filter(m=>{const t=threads.get(m.conversation_id);return t&&t.matched;}).slice(0,n);
  const newestMatched=(answer.matched_messages[0]&&answer.matched_messages[0].sent_at)||0;
  const loudestOther=summary.find(t=>!t.matched&&t.rows>0);
  if(answer.messages.length){answer.newest_sent_at=answer.messages[0].sent_at;answer.oldest_sent_at=answer.messages[answer.messages.length-1].sent_at;}
  else answer.note='no authorized message in the stated window';
  if(q&&loudestOther&&loudestOther.newest_sent_at>newestMatched)answer.hint='newest rows are outside the name-matched threads: '+loudestOther.id+' has '+loudestOther.rows+' row(s)'+(loudestOther.title?' ('+loudestOther.title+')':'')+(answer.matched_messages.length?'; the newest name-matched row is older':'');
  if(errors.length)answer.errors=errors;
  return answer;
 };
}
export function main(argv=process.argv.slice(2)){
 const at=argv.indexOf('--binding-json'),profileAt=argv.indexOf('--profile-file');
 if(at>=0&&profileAt>=0)throw Error('ambiguous_whatsapp_binding');
 const explicit=profileAt>=0?JSON.parse(readFileSync(argv[profileAt+1],'utf8')).resources:at>=0?JSON.parse(argv[at+1]):{};
 if(!explicit||typeof explicit!=='object'||Array.isArray(explicit))throw Error('invalid_whatsapp_profile');
 const binding={backend:'linked_device',account:process.env.WA_MCP_WHATSAPP_ACCOUNT,generation:Number(process.env.WA_MCP_WHATSAPP_GENERATION),connector_url:process.env.WA_MCP_WHATSAPP_URL,token_file:process.env.WA_MCP_WHATSAPP_TOKEN_FILE,ca_file:process.env.WA_MCP_WHATSAPP_CA_FILE,...explicit};
 const adapter=createWhatsAppAdapter(binding);const newest=createNewestReader(adapter,{wide:binding.account_wide===true&&binding.operator_account_read===true});
 serveMCP({name:'wasm-agent-whatsapp',tools:WHATSAPP_TOOLS,call:(name,args)=>name==='read_newest'?newest(args):adapter(name,args)});
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href)try{main();}catch{console.error('whatsapp_connector_configuration_invalid');process.exitCode=1;}
