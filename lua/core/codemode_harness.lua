-- Code mode's ergonomics layer, kept where the guest's *behaviour* can be tested from this tree.
--
-- The pinned Pi prelude (`.git`, vendored by `scripts/provision-codemode-assets.mjs`) hands a script
-- an async function whose tool calls are Promises, and it ends the script the moment the function's
-- promise settles. A script that forgets an `await` therefore ended *before* its calls were admitted
-- and answered `undefined`, and `.map` on the pending Promise answered `undefined` too - four calls
-- and thirteen seconds were spent learning the shape of a call the model had already made
-- (session 570a0da0, 11/11). The prelude is checksum-pinned third-party bytes and its globals are
-- frozen, so the fix lives here: a prologue and an epilogue are prepended and appended to the script
-- *text* the node sends, which is how this layer reaches both loops (native and the `codemode`
-- component) without touching a pinned asset or the host ABI.
--
-- What the layer guarantees (docs/CODEMODE.md, "Natural promises"):
--   * a returned Promise, or an array/object containing Promises, is settled before the value is
--     reported - `return searchTools("*")` answers the list, not `undefined`;
--   * calls still in flight when the script body ends are awaited, never reported `unexecuted`;
--   * a call can be used without `await` where JavaScript allows a value to travel: `return`, `text`,
--     `store` and `console` settle it, and `Promise.all`/`parallel([...])` still run calls concurrently;
--   * a pending value used as if it had settled (`.map`, a property, `for...of`) throws a TypeError
--     that names the call and says to write `await`, instead of answering `undefined`.
--
-- One line per statement and `/* */` comments only: the source below is joined into ONE line (see
-- `join`), so a script's own line 1 is line 2 of the compiled source and a stack frame is one line
-- off. `join` refuses anything that would make the join unsafe.
local M = {}

local SOURCE = [==[
var __h=(function(G){
var P=Promise;
var thenFn=P.prototype.then;
var arrayIsArray=Array.isArray;
var objectKeys=Object.keys;
var objectProto=Object.prototype;
var getProto=Object.getPrototypeOf;
var resolveP=function(value){ return P.resolve(value); };
var allP=function(list){ return P.all(list); };
var inflight=new Set();
var chain=resolveP();
var busy=0;
/* A host built before this layer has no results global: scripts then get one named error instead of "undefined is not a function". */

function isThenable(value){ return value!==null&&(typeof value==='object'||typeof value==='function')&&typeof value.then==='function'; }
function preview(value){ try{ var text=typeof value==='string'?value:JSON.stringify(value); if(text===undefined||text===null){ return ''; } text=String(text); return text.length>72?text.slice(0,69)+'...':text; }catch(error){ return ''; } }
function pendingMessage(label,property){ return new TypeError(label+' has not resolved yet, so '+label+'.'+property+' is unavailable. Write await '+label+' (or return the call: the harness settles it), then use the value. A call settles only while the script waits for it; Promise.all([...]) or parallel([...]) waits for several at once.'); }
function guard(label,promise){
 var settled=false;
 var value;
 var failure;
 thenFn.call(promise,function(result){ settled=true; value=result; },function(error){ settled=true; failure=error; });
 var target=Object.create(P.prototype);
 return new Proxy(target,{
  get:function(object,property){
   if(property==='then'||property==='catch'||property==='finally'){ return function(){ return P.prototype[property].apply(promise,arguments); }; }
   if(property===Symbol.toStringTag){ return 'Promise'; }
   if(property==='constructor'){ return P; }
   if(!settled){ throw pendingMessage(label,typeof property==='symbol'?String(property):property); }
   if(failure){ throw failure; }
   if(value===undefined||value===null){ return undefined; }
   return value[property];
  },
  has:function(object,property){ if(!settled){ throw pendingMessage(label,typeof property==='symbol'?String(property):property); } return value!==undefined&&value!==null&&(property in Object(value)); },
  ownKeys:function(){ if(!settled){ throw pendingMessage(label,'own keys'); } return Reflect.ownKeys(Object(value)); },
  getOwnPropertyDescriptor:function(object,property){ if(!settled){ throw pendingMessage(label,typeof property==='symbol'?String(property):property); } return { value:value==null?undefined:value[property], writable:true, enumerable:true, configurable:true }; },
  set:function(object,property,next){ if(!settled){ throw pendingMessage(label,typeof property==='symbol'?String(property):property); } value[property]=next; return true; },
  deleteProperty:function(object,property){ if(!settled){ throw pendingMessage(label,typeof property==='symbol'?String(property):property); } delete value[property]; return true; }
 });
}
function track(label,promise){ inflight.add(promise); var drop=function(){ inflight.delete(promise); }; thenFn.call(promise,drop,drop); return guard(label,promise); }
async function drain(){
 var rounds=0;
 while(inflight.size>0&&rounds<10000){
  rounds++;
  var batch=[];
  inflight.forEach(function(entry){ batch.push(entry); });
  var swept=[];
  for(var index=0;index<batch.length;index++){ swept.push(thenFn.call(batch[index],function(){},function(){})); }
  await allP(swept);
 }
}
async function settle(value,seen,depth){
 depth=depth||0;
 if(depth>12){ return value; }
 if(isThenable(value)){ return settle(await value,seen,depth+1); }
 if(value===null||typeof value!=='object'){ return value; }
 if(seen.has(value)){ return seen.get(value); }
 if(arrayIsArray(value)){ var list=[]; seen.set(value,list); for(var index=0;index<value.length;index++){ list.push(await settle(value[index],seen,depth+1)); } return list; }
 var proto=getProto(value);
 if(proto===objectProto||proto===null){ var out={}; seen.set(value,out); var keys=objectKeys(value); for(var position=0;position<keys.length;position++){ out[keys[position]]=await settle(value[keys[position]],seen,depth+1); } return out; }
 return value;
}
function hasPending(value,depth){
 depth=depth||0;
 if(depth>6){ return false; }
 if(isThenable(value)){ return true; }
 if(value===null||typeof value!=='object'){ return false; }
 if(arrayIsArray(value)){ for(var index=0;index<value.length;index++){ if(hasPending(value[index],depth+1)){ return true; } } return false; }
 var proto=getProto(value);
 if(proto===objectProto||proto===null){ var keys=objectKeys(value); for(var position=0;position<keys.length;position++){ if(hasPending(value[keys[position]],depth+1)){ return true; } } }
 return false;
}
function enqueue(job){ busy++; chain=thenFn.call(chain,function(){ busy--; return job(); }); }
async function settleAll(value){
 var rounds=0;
 /* The output queue is awaited here, not only counted: a deferred text()/store() waits on a pending call, so its job is still in flight when the queue's counter reaches zero, and a script that ended then would drop the output after done (measured 11/11). */
 do { await drain(); await chain; rounds++; } while((inflight.size>0||busy>0)&&rounds<64);
 var out=await settle(value,new Map(),0);
 await drain();
 await chain;
 return out;
}
function parseAge(spec){
 if(typeof spec==='number'){ return spec>0?spec:null; }
 if(typeof spec!=='string'){ return null; }
 var match=/^\s*([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h)?\s*$/i.exec(spec);
 if(!match){ return null; }
 var size=Number(match[1]);
 if(!(size>0)){ return null; }
 var unit=(match[2]||'s').toLowerCase();
 if(unit==='ms'){ return size/1000; }
 if(unit==='m'){ return size*60; }
 if(unit==='h'){ return size*3600; }
 return size;
}
function callLabel(kind,name,args){ return kind+'.'+name+'('+preview(args)+')'; }
function makeTool(name,raw){
 return function(args){ return track(callLabel('tools',name,args),raw(args)); };
}
function makeGlobal(name,raw){ return function(){ var args=[].slice.call(arguments); return track(name+'('+preview(args[0])+')',raw.apply(null,args)); }; }
function wrapTools(raw){ var out=Object.create(null); var keys=Reflect.ownKeys(raw); for(var index=0;index<keys.length;index++){ var key=keys[index]; if(typeof key==='string'){ out[key]=makeTool(key,raw[key]); } } return Object.freeze(out); }
function text(value){ if(busy===0&&!hasPending(value)){ G.text(value); return; } enqueue(async function(){ G.text(await settle(value,new Map(),0)); }); }
function image(value){ if(busy===0&&!hasPending(value)){ G.image(value); return; } enqueue(async function(){ G.image(await settle(value,new Map(),0)); }); }
function store(key,value){ if(busy===0&&!hasPending(value)){ G.store(key,value); return; } enqueue(async function(){ G.store(key,await settle(value,new Map(),0)); }); }
function load(key){ return G.load(key); }
function makeConsole(raw){
 var out={};
 var levels=['log','info','warn','error','debug'];
 var pending=function(item){ return hasPending(item); };
 for(var index=0;index<levels.length;index++){
  out[levels[index]]=(function(level){ return function(){ var args=[].slice.call(arguments); if(busy===0&&!args.some(pending)){ raw[level].apply(raw,args); return; } enqueue(async function(){ var values=[]; for(var position=0;position<args.length;position++){ values.push(await settle(args[position],new Map(),0)); } raw[level].apply(raw,values); }); }; })(levels[index]);
 }
 return Object.freeze(out);
}
function parallel(items){
 var list=[];
 for(var index=0;index<items.length;index++){ var item=items[index]; list.push(typeof item==='function'?item():item); }
 return track('parallel([...])',allP(list));
}
return {
 enter:async function(body){
  var value=await body(wrapTools(G.tools),makeConsole(G.console),makeGlobal('searchTools',G.searchTools),makeGlobal('describeTool',G.describeTool),makeGlobal('showCall',G.showCall),makeGlobal('capabilities',G.capabilities),makeGlobal('describe',G.describe),parallel,text,store,load,image,G.exit,G.ALL_TOOLS);
  return await settleAll(value);
 }
};
})(globalThis)
]==]

-- The join above needs one line per statement: a `//` comment would swallow the rest of the joined
-- line, a backtick could open a template literal that spans lines, and a `/* */` comment that is not
-- closed on its own line would swallow code. Refused at load, not discovered as a guest SyntaxError.
local function join(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("//", 1, true) then error("codemode_harness: a line comment cannot survive the join: " .. line) end
    if line:find("`", 1, true) then error("codemode_harness: a template literal cannot survive the join: " .. line) end
    local _, opens = line:gsub("/%*", "")
    local _, closes = line:gsub("%*/", "")
    if opens ~= closes then error("codemode_harness: a block comment must open and close on one line: " .. line) end
    if line:find("%S") then lines[#lines + 1] = line end
  end
  return table.concat(lines, " ")
end

local ONE = join(SOURCE)

-- The user's own code keeps its shape: it is the body of ONE function, whose parameters are the
-- wrapped values, so no global has to be reassigned (the prelude's globals are non-writable) and a
-- script that declares its own `const` still sees the wrapped `tools`/`text`/`store`.
M.prologue = ONE .. ";return await __h.enter(async function(tools, console, searchTools, describeTool, showCall, capabilities, describe, parallel, text, store, load, image, exit, ALL_TOOLS){"
M.epilogue = "\n});"

-- The script the node sends: the harness on line 1, the model's code from line 2.
function M.decorate(code)
  if type(code) ~= "string" then return code end
  return M.prologue .. "\n" .. code .. M.epilogue
end

return M
