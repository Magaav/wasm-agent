// Narrow public-web backend. Static text/HTML reader, not a JS browser or extraction agent.
import {request} from 'node:https';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {join,isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';
import {TextDecoder} from 'node:util';
import {createHTTPOutcomes,challengeHTML} from './web-http-outcomes.mjs';
const hash=b=>createHash('sha256').update(b).digest('hex');
export function publicAddress(address){
 if(isIP(address)===4){const a=address.split('.').map(Number);return !(a[0]===0||a[0]===10||a[0]===127||a[0]>=224||a[0]===169&&a[1]===254||a[0]===172&&a[1]>=16&&a[1]<=31||a[0]===192&&a[1]===168||a[0]===100&&a[1]>=64&&a[1]<=127||a[0]===198&&[18,19].includes(a[1]));}
 return isIP(address)===6&&/^[23][0-9a-f]{3}:/i.test(address);
}
export function publicURL(value){const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||u.port&&u.port!=='443'||u.hostname.endsWith('.local')||u.hostname==='localhost'||isIP(u.hostname.replace(/^\[|\]$/g,''))&&!publicAddress(u.hostname.replace(/^\[|\]$/g,'')))throw Error('web_url_requires_public_https');u.hash='';return u;}
export async function fetchPublic(value,{maxBytes=8*1024*1024}={}){
 let u=publicURL(value);
 for(let redirects=0;redirects<=3;redirects++){
  const addresses=await lookup(u.hostname.replace(/^\[|\]$/g,''),{all:true,verbatim:true});if(!addresses.length||addresses.some(a=>!publicAddress(a.address)))throw Error('web_private_address_refused');const pinned=addresses[0];
  const reply=await new Promise((resolve,reject)=>{
   const req=request(u,{method:'GET',headers:{'User-Agent':'wasm-agent-web/1','Accept':'text/html,text/plain,application/json,application/xml,application/rss+xml'},lookup:(_name,options,cb)=>options.all?cb(null,[pinned]):cb(null,pinned.address,pinned.family)},res=>{
    const chunks=[];let bytes=0;res.on('data',b=>{bytes+=b.length;if(bytes>maxBytes){res.destroy(Error('web_response_too_large'));return;}chunks.push(b);});res.on('error',reject);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,bytes:Buffer.concat(chunks),url:u.href}));
   });req.setTimeout(20000,()=>req.destroy(Error('web_request_timeout')));req.on('error',reject);req.end();
  });
  if([301,302,303,307,308].includes(reply.status)){if(redirects===3||!reply.headers.location)throw Error('web_redirect_limit');u=publicURL(new URL(reply.headers.location,u).href);continue;}
  if(reply.status!==200){const error=Error('web_http_'+reply.status);error.response=reply;throw error;}return reply;
 }
}
export function entities(text){return text.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,'$1').replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,(_m,key)=>{const names={amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '};if(key[0]!=='#')return names[key.toLowerCase()];const n=key[1].toLowerCase()==='x'?parseInt(key.slice(2),16):Number(key.slice(1));return n>=0&&n<=0x10ffff&&!(n>=0xd800&&n<=0xdfff)?String.fromCodePoint(n):'�';});}
export function extractHTML(raw){const title=entities((raw.match(/<title\b[^>]*>([\s\S]*?)<\/title\s*>/i)||[])[1]||'').replace(/\s+/g,' ').trim();const text=entities(raw.replace(/<!--[\s\S]*?-->/g,'').replace(/<(script|style|noscript|template)\b[^>]*>[\s\S]*?<\/\1\s*>/gi,'').replace(/<\/(p|div|section|article|h[1-6]|li|pre|tr)\s*>|<br\b[^>]*>/gi,'\n').replace(/<[^>]*>/g,'')).replace(/[ \t]+/g,' ').replace(/ *\n */g,'\n').replace(/\n{3,}/g,'\n\n').trim();return {title,text};}
const field=(text,name)=>entities((text.match(new RegExp('<'+name+'(?:\\s[^>]*)?>([\\s\\S]*?)<\\/'+name+'>','i'))||[])[1]||'').trim();
export function parseRSS(raw){if(!/<rss\b/i.test(raw))throw Error('web_search_invalid_rss');return [...raw.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)].map(m=>({title:field(m[1],'title'),url:new URL(field(m[1],'link')).href,snippet:extractHTML(field(m[1],'description')).text,published:field(m[1],'pubDate')||null}));}
export function parseSearchHTML(raw){
 if(challengeHTML(raw))throw Error('web_search_challenge_refused');
 const results=[];
 for(const m of raw.matchAll(/<a\b([^>]*\bclass=["'][^"']*\bresult__a\b[^"']*["'][^>]*)>([\s\S]*?)<\/a>/gi)){
  const href=(m[1].match(/\bhref=["']([^"']+)["']/i)||[])[1];if(!href)continue;
  let url=new URL(entities(href),'https://duckduckgo.com');if(['duckduckgo.com','www.duckduckgo.com'].includes(url.hostname)&&url.searchParams.has('uddg'))url=new URL(url.searchParams.get('uddg'));
  if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('web_search_invalid_result_url');
  results.push({title:extractHTML(m[2]).text,url:url.href,snippet:null,published:null});
 }
 if(!results.length)throw Error('web_search_no_results');return results;
}
function utf8(bytes){return new TextDecoder('utf-8',{fatal:true}).decode(bytes);}
export function createWebAdapter({cacheDir,fetch=fetchPublic,clock=()=>new Date().toISOString(),searchURL,fallback=true}={}){
 if(typeof cacheDir!=='string'||!isAbsolute(cacheDir))throw Error('web_cache_requires_absolute_path');mkdirSync(cacheDir,{recursive:true,mode:0o700});
 const put=record=>{const bytes=Buffer.from(JSON.stringify(record)),ref=hash(bytes),file=join(cacheDir,ref+'.json');if(!existsSync(file))writeFileSync(file,bytes,{flag:'wx',mode:0o600});return ref;};
 const get=ref=>{if(typeof ref!=='string'||!/^[a-f0-9]{64}$/.test(ref))throw Error('invalid_web_ref');const raw=readFileSync(join(cacheDir,ref+'.json'));if(hash(raw)!==ref)throw Error('web_cache_changed');return JSON.parse(utf8(raw));};
 const outcomes=createHTTPOutcomes({put,get,clock,publicURL});
 async function http(url){let reply;try{reply=await fetch(url);}catch(error){if(!error.response)throw error;reply=error.response;}
  if(!Number.isInteger(reply.status)||reply.status<100||reply.status>599||!Buffer.isBuffer(reply.bytes))throw Error('web_response_invalid');return reply;
 }
 function pageRecord(reply,evidence){
  const kind=String(reply.headers['content-type']||'').split(';')[0].toLowerCase();
  if(!['text/html','text/plain','application/json','application/xml','application/rss+xml','text/xml'].includes(kind))return {error:'web_content_type_unsupported:'+kind,response_ref:evidence.response_ref};
  const raw=evidence.raw,parsed=kind==='text/html'?extractHTML(raw):{title:'',text:raw};
  return {ref:put({url:reply.url,title:parsed.title,source_kind:kind,fetched_at:clock(),raw,raw_sha256:hash(reply.bytes),text:parsed.text,http_response_ref:evidence.response_ref,limitations:kind==='text/html'?'Static HTML text only; scripts, styles and templates excluded from the view. Exact raw source retained. JavaScript rendering/PDF not supported.':null})};
 }
 function view(ref,offset=0,limit=4096){if(!Number.isInteger(offset)||offset<0||!Number.isInteger(limit)||limit<4||limit>16384)throw Error('invalid_web_page');const record=get(ref);if(record.source_kind==='web-pending')throw Error('web_pending_requires_pending_ref');const bytes=Buffer.from(record.text);if(offset>bytes.length||offset<bytes.length&&(bytes[offset]&0xc0)===0x80)throw Error('web_offset_not_utf8_boundary');let end=Math.min(bytes.length,offset+limit);while(end>offset&&end<bytes.length&&(bytes[end]&0xc0)===0x80)end--;return {ok:true,ref,url:record.url,title:record.title,source_kind:record.source_kind,fetched_at:record.fetched_at,content:utf8(bytes.subarray(offset,end)),offset,next_offset:end,eof:end===bytes.length,total_bytes:bytes.length,raw_sha256:record.raw_sha256,http_response_ref:record.http_response_ref,limitations:record.limitations};}
 // Providers in order (29/10): DuckDuckGo HTML throttles bursts with a 202 challenge - exactly what a
 // code-mode fan-out produces - so a challenged or empty provider hands the query to Bing RSS. A
 // repeated query inside five minutes answers from the cache and issues no request.
 const providers=searchURL?[{name:'fixture-rss',url:searchURL,parse:parseRSS}]:[
  {name:'duckduckgo-html',url:q=>'https://html.duckduckgo.com/html/?q='+encodeURIComponent(q),parse:parseSearchHTML},
  {name:'bing-rss',url:q=>'https://www.bing.com/search?format=rss&q='+encodeURIComponent(q),parse:parseRSS}].slice(0,fallback?2:1);
 const answer=(args,record,ref,limit,extra)=>{const all=JSON.parse(record.text);return {ok:true,query:args.query,provider:record.source_kind.replace(/^search-/,''),results:all.slice(0,limit),returned:Math.min(limit,all.length),total_cached:all.length,ref,fetched_at:record.fetched_at,...extra};};
 async function search(args){if(typeof args.query!=='string'||!args.query.trim()||args.query.length>512)throw Error('web_query_required');const limit=args.limit??5;if(!Number.isInteger(limit)||limit<1||limit>10)throw Error('invalid_web_search_limit');
  const index=join(cacheDir,'search-'+hash(args.query.trim().toLowerCase())+'.json');
  if(!args.refresh&&existsSync(index)){const row=JSON.parse(readFileSync(index,'utf8'));if(Date.now()-row.saved_at<300000)return answer(args,get(row.ref),row.ref,limit,{cache_hit:true,request_issued:false});}
  let first=null;const skipped=[];
  for(const p of providers){
   const reply=await http(p.url(args.query)),evidence=outcomes.retain(reply),state=outcomes.classify(reply,evidence);
   let failure=state;let all;
   if(!failure){try{all=p.parse(evidence.raw);}catch(error){failure={ok:false,state:'failed',error:error.message,response_ref:evidence.response_ref,status:reply.status,url:reply.url};}}
   // An accepted async job carries its own continuation; only a refusal moves to the next provider.
   if(failure&&failure.pending_ref)return skipped.length?{...failure,fallback_from:skipped}:failure;
   if(failure){first=first||failure;skipped.push({provider:p.name,error:failure.error||failure.state});continue;}
   const record={source_kind:'search-'+p.name,url:reply.url,title:args.query,fetched_at:clock(),raw:evidence.raw,raw_sha256:hash(reply.bytes),http_response_ref:evidence.response_ref,text:JSON.stringify(all),limitations:'Public search results; ranking/coverage is not a quality guarantee.'},ref=put(record);
   writeFileSync(index,JSON.stringify({ref,saved_at:Date.now()}),{mode:0o600});
   return answer(args,record,ref,limit,skipped.length?{fallback_from:skipped}:{});
  }
  return skipped.length>1?{...first,providers_tried:skipped}:first;
 }
 async function read(args){
  if(args.pending_ref){
   if(args.url||args.ref||args.refresh)throw Error('web_pending_conflicts_with_url_or_ref');
   const pending=outcomes.pending(args.pending_ref);
   if(!outcomes.due(pending))return {ok:false,state:'pending',pending_ref:args.pending_ref,poll_after_at:pending.poll_after_at,response_ref:pending.response_ref,request_issued:false};
   const reply=await http(pending.monitor_url),evidence=outcomes.retain(reply),state=outcomes.classify(reply,evidence,{pending});if(state)return state;
   const page=pageRecord(reply,evidence);if(page.error)return {ok:false,state:'failed',...page};
   return {...view(page.ref,args.offset??0,args.limit??4096),state:'complete',completed_pending_ref:args.pending_ref,request_issued:true};
  }
  if(args.ref){if(args.url||args.refresh)throw Error('web_ref_conflicts_with_url');return view(args.ref,args.offset??0,args.limit??4096);}const url=publicURL(args.url).href,index=join(cacheDir,'url-'+hash(url)+'.json');let ref,cacheHit=false;
  if(!args.refresh&&existsSync(index)){const row=JSON.parse(readFileSync(index,'utf8'));if(Date.now()-row.saved_at<300000){get(row.ref);ref=row.ref;cacheHit=true;}}
  if(!ref){const reply=await http(url),evidence=outcomes.retain(reply),state=outcomes.classify(reply,evidence);if(state)return state;
   const page=pageRecord(reply,evidence);if(page.error)return {ok:false,state:'failed',...page};ref=page.ref;
   writeFileSync(index,JSON.stringify({ref,saved_at:Date.now()}),{mode:0o600});
  }
  return {...view(ref,args.offset??0,args.limit??4096),cache_hit:cacheHit};
 }
 return {search,read,get};
}
export const WEB_TOOLS=[{name:'search',description:'Search public web sources. Full search response is retained behind ref; a repeated query within five minutes is answered from the cache unless refresh is set.',inputSchema:{type:'object',properties:{query:{type:'string'},limit:{type:'integer',minimum:1,maximum:10},refresh:{type:'boolean'}},required:['query']},annotations:{readOnlyHint:true}},
 {name:'read',description:'Read static public HTTPS text, page an immutable ref, or read pending_ref for one async monitor GET (never replay the original query). Challenges require human action; no browser actions or automatic polling.',inputSchema:{type:'object',properties:{url:{type:'string'},ref:{type:'string'},pending_ref:{type:'string'},offset:{type:'integer',minimum:0},limit:{type:'integer',minimum:4,maximum:16384},refresh:{type:'boolean'}}},annotations:{readOnlyHint:true}}];
