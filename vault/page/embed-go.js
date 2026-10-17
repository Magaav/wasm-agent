// Vault-owned cross-origin form. Only opaque public receipt/control messages cross the frame boundary.
'use strict';
const el=id=>document.getElementById(id),params=new URLSearchParams(location.hash.slice(1));
const binding={vault_id:params.get('vault'),parent:params.get('parent'),scope:params.get('scope'),channel:params.get('channel')};
history.replaceState(null,'',location.pathname);
let verified=false,active=false,closed=false,token='',busy=false,material='',snapshot=null,pending=null;
const permits=new Map();
function message(state,extra={}){if(binding.parent)parent.postMessage({type:'wa-vault-go',state,channel:binding.channel,scope:binding.scope,vault_id:binding.vault_id,...extra},binding.parent);}
function status(text){el('status').textContent=text;}
function clearMaterial(){material='';el('key').value='';el('admin').value='';}
function lock(){
 el('admin').disabled=busy||!verified||!active;el('enroll').querySelector('button').disabled=el('admin').disabled;
 el('key').disabled=busy||!verified||!active||!token||!snapshot||!!pending;
 el('save').disabled=el('key').disabled;
 el('reconcile').disabled=busy||!verified||!active||!token;
 el('cancel-operation').disabled=busy||!active||!token||!pending;
}
async function api(action,body={}){
 const response=await fetch('/api/embed/go/'+action,{method:'POST',headers:{'Content-Type':'application/json','X-Vault-Token':token,'X-Vault-Instance':binding.vault_id},body:JSON.stringify({scope:binding.scope,expected_vault_id:binding.vault_id,...body}),credentials:'omit',cache:'no-store',redirect:'error'});
 if(!response.ok){if(response.status===401){token='';}const error=Error('vault request refused');error.refused=response.status>=400&&response.status<500;error.authorization=response.status===401;error.conflict=response.status===409;throw error;}
 const value=await response.json();if(value.vault_id!==binding.vault_id||value.scope!==binding.scope||value.provider!=='opencode-go')throw Error('scope mismatch');return value;
}
function adopt(value,announce=true){
 snapshot=value;
 pending=value.operations.find(r=>r.state==='prepared')||null;
 const last=value.operations.at(-1);
 if(pending){status('Pending/unknown operation retained in the vault. Read status or cancel it explicitly; no blind resave.');message('held',{operation:pending.operation});}
 else if(last?.state==='committed'&&last.generation===value.entry.generation&&value.entry.operation===last.operation){
  status('Exact operation committed durably. Parent must verify the effective Go route. Entitlement remains unknown.');
  if(announce)message('committed',{operation:last.operation,generation:last.generation});
 }else if(last?.state==='committed'){status('Prior operation committed but was superseded. No current-key success is claimed.');}
 else status('Vault authorization verified. Enter a new operator-generated key. No inference probe is performed.');
 lock();
}
async function read(){adopt(await api('state'));}
function permit(operation,generation){
 if(!active||closed)throw Error('parent inactive');
 const request=crypto.randomUUID();
 return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{permits.delete(request);reject(Error('parent permission not verified'));},8000);permits.set(request,{resolve,reject,timer});message('intent',{request,operation,generation});});
}
window.addEventListener('message',event=>{
 const value=event.data;
 if(event.source!==parent||event.origin!==binding.parent||!value||value.type!=='wa-vault-go-control'||value.channel!==binding.channel||value.scope!==binding.scope||value.vault_id!==binding.vault_id)return;
 if(value.action==='permit'){
  const waiting=permits.get(value.request);if(!waiting)return;permits.delete(value.request);clearTimeout(waiting.timer);
  if(value.allowed&&active&&!closed)waiting.resolve();else waiting.reject(Error('scope/busy refusal'));return;
 }
 if(value.action==='active'){
  active=value.allowed===true;
  if(!active){clearMaterial();status('Parent is closed, busy or changed scope. No new save is allowed.');}
  lock();return;
 }
 if(value.action==='close'){
  closed=true;active=false;clearMaterial();token='';
  for(const waiting of permits.values()){clearTimeout(waiting.timer);waiting.reject(Error('closed'));}permits.clear();lock();
 }
});
async function run(action){if(busy||closed||!active)return;busy=true;lock();status('Working on the explicit operator action…');try{await action();}catch(error){snapshot=null;status(error.authorization?'Operator authorization refused. Re-enroll privately before reconciling any prior operation.':error.conflict?'Save/auth outcome held. A conflict or duplicate response is not proof of the original outcome. Read durable status; no credential resend.':error.refused?'Vault refused the request (stale/conflicting/invalid). Read durable status before a new explicit action.':'Save/auth outcome unknown. Read durable status; never resend the old key automatically.');message('held',pending?{operation:pending.operation}:{});}finally{clearMaterial();busy=false;lock();}}
el('enroll').addEventListener('submit',event=>{event.preventDefault();event.stopPropagation();if(!verified||!active||busy)return;token=el('admin').value.trim();el('admin').value='';run(read);});
el('key-form').addEventListener('submit',event=>{
 event.preventDefault();event.stopPropagation();if(!verified||!active||!token||busy||pending||!snapshot)return;
 material=el('key').value.trim();el('key').value='';if(!material)return;
 run(async()=>{
  const operation=crypto.randomUUID(),generation=snapshot.entry.generation;
  await permit(operation,generation);if(!material||!active||closed)return;
  // Durable nonsecret fence before the sole credential write. No key in storage, URL or parent messages.
  pending={operation,state:'prepared'};
  const prepared=await api('prepare',{operation,expected_generation:generation});adopt(prepared,false);
  if(!pending||pending.operation!==operation)throw Error('not prepared');
  await permit(operation,generation);if(!material||!active||closed)return;
  const body={operation,key:material};material='';
  try{await api('save',body);}finally{body.key='';}
  await read();
 });
});
el('cancel-entry').addEventListener('click',()=>{clearMaterial();status('Entry cleared. An already dispatched or uncertain write is not silently cancelled.');});
el('reconcile').addEventListener('click',()=>run(read));
el('cancel-operation').addEventListener('click',()=>run(async()=>{if(pending){await api('cancel',{operation:pending.operation});await read();}}));
window.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();clearMaterial();token='';active=false;message('close');lock();}});
window.addEventListener('pagehide',()=>{closed=true;clearMaterial();token='';});
(async()=>{
 try{
  const parentURL=new URL(binding.parent);
  if(parent===window||parentURL.origin!==binding.parent||parentURL.origin===location.origin||!binding.scope?.match(/^[a-f0-9]{64}$/)||!binding.channel?.match(/^[a-f0-9-]{36}$/)||!binding.vault_id?.match(/^[a-f0-9-]{36}$/))throw Error('invalid binding');
  const response=await fetch('/embed/config',{cache:'no-store',credentials:'omit',redirect:'error'});const config=await response.json();
  if(!response.ok||config.parent_origin!==binding.parent||config.vault_id!==binding.vault_id)throw Error('identity/origin mismatch');
  verified=true;
  // Keep only public binding metadata so a real frame reload can reverify identity/scope.
  // Credentials are never URL values; unknown fragments were discarded before bootstrap.
  history.replaceState(null,'',location.pathname+'#'+new URLSearchParams({vault:binding.vault_id,parent:binding.parent,scope:binding.scope,channel:binding.channel}));
  el('destination').textContent='Private destination: '+location.origin+' · vault '+binding.vault_id;
  status('Vault identity verified. Enroll privately, then enter the Go API key below.');message('ready');lock();
 }catch(_){status('Vault framing/origin/identity setup is unavailable or mismatched. No credentials accepted.');clearMaterial();lock();}
})();
