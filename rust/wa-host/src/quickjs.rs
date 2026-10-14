//! Node-free, checksum-pinned QuickJS-WASI reactor. Mechanical VM/ABI only;
//! tool permissions and effects stay in Lua. Adapted from QuickJS-WASI3.6.2
//! and Pi-codemode1.2.0 VM driver contracts (MIT notices in licenses/).
use anyhow::{anyhow, bail, Context, Result};
use ring::digest::{digest, SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use serde_json::{json, Value};
use std::{cell::RefCell, collections::{HashMap,HashSet}, ffi::{c_char,c_int}, time::{Instant,SystemTime,UNIX_EPOCH}, sync::OnceLock};
use wasmtime::{Caller, Config, Engine, Instance, Linker, Memory, Module, Store, StoreLimits, StoreLimitsBuilder, Val};
const LICENSES:&str=concat!(include_str!("../../../licenses/pi-MIT.txt"),"\n",include_str!("../../../licenses/quickjs-wasi-MIT.txt"));
const EMBEDDED_WASM:&[u8]=include_bytes!(concat!(env!("OUT_DIR"),"/quickjs.wasm"));
const EMBEDDED_PRELUDE:&[u8]=include_bytes!(concat!(env!("OUT_DIR"),"/prelude.js"));
const WASM_SHA:&str="d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9";
const PRELUDE_SHA:&str="57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281";
fn hash(b:&[u8])->String {digest(&SHA256,b).as_ref().iter().map(|b|format!("{b:02x}")).collect()}
struct Data { events:Vec<Value>, clock_origin:Instant, deadline:Instant, limits:StoreLimits, output_bytes:usize, pending:HashSet<u64> }
struct Sandbox {store:Store<Data>, instance:Instance, memory:Memory, api:i32, settle:i32, stalled:i32, owner:String}
thread_local! {static SESSIONS:RefCell<HashMap<String,Sandbox>>=RefCell::new(HashMap::new());}
fn engine()->Result<Engine> {static ENGINE:OnceLock<Engine>=OnceLock::new();if let Some(e)=ENGINE.get(){return Ok(e.clone())}let mut c=Config::new();c.consume_fuel(true);let e=Engine::new(&c)?;let _=ENGINE.set(e);Ok(ENGINE.get().expect("engine initialized").clone())}
fn module(engine:&Engine,bytes:&[u8])->Result<Module>{static MODULE:OnceLock<Module>=OnceLock::new();if let Some(m)=MODULE.get(){return Ok(m.clone())}let m=Module::new(engine,bytes)?;let _=MODULE.set(m);Ok(MODULE.get().expect("module initialized").clone())}
fn mem(c:&mut Caller<'_,Data>)->Result<Memory>{c.get_export("memory").and_then(|e|e.into_memory()).ok_or_else(||anyhow!("guest memory absent"))}
fn read(c:&mut Caller<'_,Data>,ptr:i32,len:usize)->Result<Vec<u8>> {let m=mem(c)?;let p=usize::try_from(ptr)?;let end=p.checked_add(len).context("guest range overflow")?;Ok(m.data(&*c).get(p..end).context("guest range outside memory")?.to_vec())}
fn write(c:&mut Caller<'_,Data>,ptr:i32,b:&[u8])->Result<()> {let m=mem(c)?;m.write(c,usize::try_from(ptr)?,b)?;Ok(())}
fn cfun(c:&mut Caller<'_,Data>,name:&str,args:&[Val],value:Val)->Result<Val>{let f=c.get_export(name).and_then(|e|e.into_func()).context("guest ABI export absent")?;let mut out=[value];f.call(c,args,&mut out)?;Ok(out[0].clone())}
fn cint(c:&mut Caller<'_,Data>,name:&str,args:&[Val])->Result<i32>{cfun(c,name,args,Val::I32(0))?.i32().context("guest integer result")}
fn strval(c:&mut Caller<'_,Data>,value:i32)->Result<String>{let ptr=cint(c,"qjs_get_string",&[Val::I32(value)])?;if ptr==0{bail!("guest string conversion failed")}let m=mem(c)?;let bytes=m.data(&*c).get(usize::try_from(ptr)?..).context("guest string range")?;let n=bytes.iter().position(|b|*b==0).context("guest unterminated string")?;if n>16*1024*1024{bail!("guest string too large")}let result=String::from_utf8(bytes[..n].to_vec())?;let f=c.get_export("qjs_free_cstring").and_then(|e|e.into_func()).context("guest free absent")?;f.call(c,&[Val::I32(ptr)],&mut [])?;Ok(result)}
fn bridge(c:&mut Caller<'_,Data>,name:i32,name_len:i32,argc:i32,argv:i32)->Result<i32>{
 if read(c,name,usize::try_from(name_len)?)?!=b"bridge"{bail!("unregistered guest callback")}
 if !(1..=4).contains(&argc){bail!("invalid bridge arity")}
 let mut values=Vec::new();for i in 0..argc {let p=argv.checked_add(i*4).context("argv overflow")?;values.push(i32::from_le_bytes(read(c,p,4)?.try_into().unwrap()))}
 let kind=strval(c,values[0])?;
 let event=match kind.as_str(){
  "call"|"global"=>{if values.len()<3{bail!("call arity")}let id=cfun(c,"qjs_get_float64",&[Val::I32(values[1])],Val::F64(0))?.f64().context("call id")?;if !id.is_finite()||id<1.0||id.fract()!=0.0{bail!("call id invalid")}json!({"type":"call","id":id as u64,"target":if kind=="call"{"tool"}else{"global"},"name":strval(c,values[2])?,"args":if values.len()>3{Some(strval(c,values[3])?)}else{None}})},
  "output"=>{if values.len()<3{bail!("output arity")}let t=strval(c,values[1])?;if t=="image"{bail!("image output not enabled")}json!({"type":"output","item":{"type":"text","text":strval(c,values[2])?,"console":t=="console"}})},
  "done"=>{if values.len()<3{bail!("done arity")}let ok=cint(c,"qjs_get_bool",&[Val::I32(values[1])])?!=0;if ok{json!({"type":"done","ok":true,"value":strval(c,values[2])?,"writes":if values.len()>3{Some(strval(c,values[3])?)}else{None}})}else{json!({"type":"done","ok":false,"error":strval(c,values[2])?})}},
  _=>bail!("unknown bridge message")};
 let size=serde_json::to_vec(&event)?.len();let data=c.data_mut();if event["type"]=="call" && !data.pending.insert(event["id"].as_u64().context("call id")?){bail!("duplicate guest call")};data.output_bytes=data.output_bytes.checked_add(size).context("output overflow")?;if data.output_bytes>16*1024*1024||data.events.len()>=100000{bail!("sandbox output bound")};data.events.push(event);
 cint(c,"qjs_get_undefined",&[])
}
impl Sandbox {
 fn i(&mut self,name:&str,args:&[i32])->Result<i32>{let f=self.instance.get_func(&mut self.store,name).with_context(||format!("missing {name}"))?;let a=args.iter().map(|v|Val::I32(*v)).collect::<Vec<_>>();let mut out=[Val::I32(0)];f.call(&mut self.store,&a,&mut out)?;out[0].i32().context("integer result")}
 fn v(&mut self,name:&str,args:&[i32])->Result<()> {let f=self.instance.get_func(&mut self.store,name).with_context(||format!("missing {name}"))?;let a=args.iter().map(|v|Val::I32(*v)).collect::<Vec<_>>();f.call(&mut self.store,&a,&mut [])?;Ok(())}
 fn free(&mut self,values:&[i32])->Result<()> {for &value in values{self.v("qjs_free_value",&[value])?}Ok(())}
 fn put(&mut self,s:&str)->Result<i32>{if s.len()>16*1024*1024{bail!("sandbox input bound")}let p=self.i("wasm_malloc",&[(s.len()+1)as i32])?;if p==0{bail!("guest allocation failed")}self.memory.write(&mut self.store,p as usize,s.as_bytes())?;self.memory.write(&mut self.store,p as usize+s.len(),&[0])?;Ok(p)}
 fn string(&mut self,s:&str)->Result<i32>{let p=self.put(s)?;let value=self.i("qjs_new_string",&[p,s.len()as i32])?;self.v("wasm_free",&[p])?;Ok(value)}
 fn eval(&mut self,s:&str)->Result<i32>{let p=self.put(s)?;let n=self.put("codemode.js")?;let value=self.i("qjs_eval",&[p,s.len()as i32,n,0])?;self.v("wasm_free",&[p])?;self.v("wasm_free",&[n])?;if self.i("qjs_is_exception",&[value])?!=0{bail!("guest evaluation exception")}Ok(value)}
 fn prop(&mut self,value:i32,name:&str)->Result<i32>{let p=self.put(name)?;let v=self.i("qjs_get_prop_string",&[value,p])?;self.v("wasm_free",&[p])?;Ok(v)}
 fn call(&mut self,fun:i32,this:i32,args:&[i32])->Result<i32>{let p=self.i("wasm_malloc",&[(args.len()*4)as i32])?;for(i,v)in args.iter().enumerate(){self.memory.write(&mut self.store,p as usize+i*4,&v.to_le_bytes())?}let result=self.i("qjs_call",&[fun,this,args.len()as i32,p])?;self.v("wasm_free",&[p])?;if self.i("qjs_is_exception",&[result])?!=0{bail!("guest call exception")}Ok(result)}
 fn drain(&mut self)->Result<Value>{while self.i("qjs_is_job_pending",&[])?!=0{if Instant::now()>self.store.data().deadline||crate::host::run_cancel_requested(){bail!("sandbox deadline or cancellation")}if self.i("qjs_execute_pending_job",&[])?<0{bail!("promise job failed")}}let s=self.stalled;let result=self.call(s,self.api,&[])?;self.free(&[result])?;let events=std::mem::take(&mut self.store.data_mut().events);Ok(json!({"ok":true,"events":events,"backend":"rust-wasmtime-quickjs-wasi","node_required":false}))}
 fn start(args:&Value)->Result<Self>{
  let wasm=match args["wasm_path"].as_str(){Some(path)=>std::fs::read(path)?,None=>EMBEDDED_WASM.to_vec()};if wasm.is_empty(){bail!("code-mode assets unavailable; provision and embed at build time")};if hash(&wasm)!=WASM_SHA{bail!("QuickJS artifact hash mismatch")}
  let prelude=match args["prelude_path"].as_str(){Some(path)=>std::fs::read(path)?,None=>EMBEDDED_PRELUDE.to_vec()};if hash(&prelude)!=PRELUDE_SHA{bail!("Pi prelude hash mismatch")}
  let e=engine()?;let module=module(&e,&wasm)?;let mut linker=Linker::new(&e);
  linker.func_wrap("env","host_get_timezone_offset",|_:i32,_:i32|->i32{0})?;
  linker.func_wrap("env","host_interrupt",|c:Caller<'_,Data>|->i32{(Instant::now()>c.data().deadline||crate::host::run_cancel_requested())as i32})?;
  linker.func_wrap("env","host_module_normalize",|_:i32,_:i32|->i32{0})?;
  linker.func_wrap("env","host_module_load",|_:i32,_:i32|->i32{0})?;
  linker.func_wrap("env","host_promise_rejection",|mut c:Caller<'_,Data>,a:i32,b:i32,_:i32|->Result<()>{for v in[a,b]{let f=c.get_export("qjs_free_value").and_then(|e|e.into_func()).context("free export")?;f.call(&mut c,&[Val::I32(v)],&mut [])?}Ok(())})?;
  linker.func_wrap("env","host_call",|mut c:Caller<'_,Data>,n:i32,l:i32,_:i32,a:i32,v:i32|->Result<i32>{bridge(&mut c,n,l,a,v)})?;
  linker.func_wrap("wasi_snapshot_preview1","fd_close",|_:i32|->i32{52})?;
  linker.func_wrap("wasi_snapshot_preview1","fd_seek",|_:i32,_:i64,_:i32,_:i32|->i32{52})?;
  linker.func_wrap("wasi_snapshot_preview1","fd_fdstat_get",|mut c:Caller<'_,Data>,fd:i32,p:i32|->Result<i32>{if fd!=1&&fd!=2{return Ok(8)}let mut b=[0u8;24];b[0]=2;write(&mut c,p,&b)?;Ok(0)})?;
  linker.func_wrap("wasi_snapshot_preview1","fd_write",|mut c:Caller<'_,Data>,fd:i32,p:i32,n:i32,out:i32|->Result<i32>{if fd!=1&&fd!=2{return Ok(8)}if !(0..=100000).contains(&n){bail!("iov bound")}let mut size=0u32;for i in 0..n{let b=read(&mut c,p.checked_add(i*8).context("iov overflow")?,8)?;size=size.checked_add(u32::from_le_bytes(b[4..8].try_into().unwrap())).context("write overflow")?;}write(&mut c,out,&size.to_le_bytes())?;Ok(0)})?;
  linker.func_wrap("wasi_snapshot_preview1","clock_time_get",|mut c:Caller<'_,Data>,id:i32,_:i64,p:i32|->Result<i32>{if id!=0&&id!=1{return Ok(52)}let n=if id==0{SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()as u64}else{c.data().clock_origin.elapsed().as_nanos()as u64};write(&mut c,p,&n.to_le_bytes())?;Ok(0)})?;
  linker.func_wrap("wasi_snapshot_preview1","random_get",|mut c:Caller<'_,Data>,p:i32,n:i32|->Result<i32>{if !(0..=1048576).contains(&n){bail!("random bound")}let mut b=vec![0;n as usize];SystemRandom::new().fill(&mut b).map_err(|_|anyhow!("random unavailable"))?;write(&mut c,p,&b)?;Ok(0)})?;
  let timeout=args["timeout_ms"].as_u64().unwrap_or(30000).clamp(1,300000);
  let mut store=Store::new(&e,Data{events:vec![],clock_origin:Instant::now(),deadline:Instant::now()+std::time::Duration::from_millis(timeout),limits:StoreLimitsBuilder::new().memory_size(128*1024*1024).instances(1).build(),output_bytes:0,pending:HashSet::new()});store.limiter(|d|&mut d.limits);store.set_fuel(500_000_000)?;
  let instance=linker.instantiate(&mut store,&module)?;let memory=instance.get_memory(&mut store,"memory").context("guest memory")?;
  let owner=args["owner"].as_str().context("owner scope required")?.to_owned();if owner.len()!=64||!owner.bytes().all(|b|b.is_ascii_hexdigit()){bail!("invalid owner scope")}
  let mut s=Self{store,instance,memory,api:0,settle:0,stalled:0,owner};s.v("_initialize",&[])?;if s.i("qjs_init",&[])?!=0{bail!("qjs init failed")}
  s.v("qjs_set_interrupt_handler",&[1])?;s.v("qjs_set_memory_limit",&[64*1024*1024])?;s.v("qjs_set_max_stack_size",&[512*1024])?;
  let name=s.put("bridge")?;let b=s.i("qjs_new_host_function",&[name,6,0])?;s.v("wasm_free",&[name])?;let u=s.i("qjs_get_undefined",&[])?;let p=s.eval(std::str::from_utf8(&prelude)?)?;
  let t=s.string(&serde_json::to_string(&args["tools"])?)?;let g=s.string(&serde_json::to_string(&args["globals"])?)?;let data=s.string(&serde_json::to_string(&args["store"])?)?;
  s.api=s.call(p,u,&[b,t,g,data])?;s.settle=s.prop(s.api,"settle")?;s.stalled=s.prop(s.api,"stalled")?;
  s.free(&[b,u,p,t,g,data])?;Ok(s)
 }
 fn run(&mut self,code:&str)->Result<()> {let run=self.prop(self.api,"run")?;let f=self.eval(&format!("(async (tools, console) => {{{code}\n}})"))?;let result=self.call(run,self.api,&[f])?;self.free(&[run,f,result])?;Ok(())
 }
 fn deliver(&mut self,args:&Value)->Result<Value>{let id=args["call_id"].as_u64().context("result id")?;if !self.store.data_mut().pending.remove(&id){bail!("unknown or already settled call")};let idval=self.instance.get_typed_func::<f64,i32>(&mut self.store,"qjs_new_number")?.call(&mut self.store,id as f64)?;let flag=self.i(if args["ok"].as_bool()==Some(true){"qjs_get_true"}else{"qjs_get_false"},&[])?;let payload=self.string(args["payload"].as_str().context("raw payload string required")?)?;let u=self.i("qjs_get_undefined",&[])?;let settle=self.settle;let result=self.call(settle,self.api,&[idval,flag,payload,u])?;self.free(&[idval,flag,payload,u,result])?;self.drain()}
}
fn control(action:&str,args:&Value)->Result<Value>{if action=="info"{return Ok(json!({"ok":true,"backend":"rust-wasmtime-quickjs-wasi","embedded_assets":!EMBEDDED_WASM.is_empty(),"wasm_sha256":WASM_SHA,"prelude_sha256":PRELUDE_SHA,"licenses":LICENSES,"node_required":false}))}SESSIONS.with(|cell|{let mut map=cell.borrow_mut();if action=="start"{if map.len()>=4{bail!("sandbox session capacity")}let mut s=Sandbox::start(args)?;let result=match s.run(args["code"].as_str().context("code required")?).and_then(|_|s.drain()){Ok(v)=>v,Err(e)=>return Ok(json!({"ok":false,"error":format!("codemode_sandbox: {e:#}"),"events":std::mem::take(&mut s.store.data_mut().events),"effect":"none"}))};let id=format!("{:x}-{}",SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),map.len());map.insert(id.clone(),s);return Ok(json!({"ok":true,"id":id,"events":result["events"],"backend":"rust-wasmtime-quickjs-wasi","node_required":false}))}let id=args["id"].as_str().context("sandbox id")?;let s=map.get_mut(id).context("sandbox unavailable")?;if args["owner"].as_str()!=Some(&s.owner){bail!("sandbox owner mismatch")}match action{"admit"=>{if Instant::now()>s.store.data().deadline||crate::host::run_cancel_requested(){bail!("sandbox deadline or cancellation before admission")}Ok(json!({"ok":true}))},"deliver"=>match s.deliver(args){Ok(v)=>Ok(v),Err(e)=>Ok(json!({"ok":false,"error":format!("codemode_sandbox: {e:#}"),"events":std::mem::take(&mut s.store.data_mut().events)}))},"close"=>{map.remove(id);Ok(json!({"ok":true}))},_=>bail!("unknown sandbox action")}})}
pub extern "C-unwind" fn capability(l:*mut crate::lua::LuaState)->c_int{let action=crate::lua::arg_string(l,1).unwrap_or_default();let raw=crate::lua::arg_string(l,2).unwrap_or_default();let result=(||{let args:Value=serde_json::from_str(&raw)?;control(&action,&args)})();let out=match result{Ok(v)=>v,Err(e)=>json!({"ok":false,"error":format!("codemode_sandbox: {e:#}")})}.to_string();unsafe{crate::lua::lua_pushlstring(l,out.as_ptr()as *const c_char,out.len())};1}
