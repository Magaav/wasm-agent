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
-- What the layer guarantees (docs/CODEMODE.md):
--   * a returned Promise, or an array/object containing Promises, is settled before the value is
--     reported - `return searchTools("*")` answers the list, not `undefined`;
--   * `vars.<name>` is a session variable kept in the session store (`vars.x = v` writes, `delete
--     vars.x` or `vars.x = null` drops it), committed when the script finishes;
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
var rawResults=typeof G.results==='function'?G.results:function(){ throw new TypeError('results is unavailable on this node: its code-mode host predates explicit reuse and the retained-result reader'); };
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
function reuseResult(label,hit){
 var value=hit.value;
 if(value!==null&&typeof value==='object'&&!arrayIsArray(value)){
  var keys=objectKeys(value);
  var copy={};
  for(var index=0;index<keys.length;index++){ copy[keys[index]]=value[keys[index]]; }
  copy.reused_from=hit.reused_from;
  copy.age_s=hit.age_s;
  return copy;
 }
 return { reused_from:hit.reused_from, age_s:hit.age_s, value:value };
}
function callLabel(kind,name,args){ return kind+'.'+name+'('+preview(args)+')'; }
function withReuse(label,raw,args,reuse,name){
 return (async function(){
  var seconds=parseAge(reuse);
  if(seconds===null){ throw new TypeError(label+' reuse expects a duration such as "60s", "5m", "1h" or a number of seconds'); }
  var hit=await rawResults({ op:'reuse', tool:name, args:args===undefined?{}:args, max_age_s:seconds });
  if(hit&&hit.reused_from!==undefined&&hit.reused_from!==null){ return reuseResult(label,hit); }
  return await raw(args);
 })();
}
function makeTool(name,raw){
 return function(args,options){
  var label=callLabel('tools',name,args);
  var reuse=options&&options.reuse;
  if(reuse!==undefined&&reuse!==null&&reuse!==false){ return track(label,withReuse(label,raw,args,reuse,name)); }
  return track(label,raw(args));
 };
}
function makeGlobal(name,raw){ return function(){ var args=[].slice.call(arguments); return track(name+'('+preview(args[0])+')',raw.apply(null,args)); }; }
/* A name that is not a tool answers with the names closest to it instead of "not a function" (14/11). Only string names are checked; symbols and the names a runtime probes (then, toJSON...) stay undefined. */
var probes={then:1,toJSON:1,constructor:1,valueOf:1,toString:1,inspect:1,prototype:1,length:1,name:1};
function nearest(name,keys){ var low=name.toLowerCase(); var parts=low.split(/[_\W]+/).filter(function(p){ return p.length>2; }); var scored=[]; for(var index=0;index<keys.length;index++){ var key=keys[index]; var k=key.toLowerCase(); var score=0; if(k.indexOf(low)>=0||low.indexOf(k)>=0){ score+=3; } for(var position=0;position<parts.length;position++){ if(k.indexOf(parts[position])>=0){ score+=1; } } if(score>0){ scored.push([score,key]); } } scored.sort(function(a,b){ return b[0]-a[0]||a[1].length-b[1].length; }); return scored.slice(0,4).map(function(entry){ return entry[1]; }); }
function wrapTools(raw,extras){ var out=Object.create(null); var keys=Reflect.ownKeys(raw); for(var index=0;index<keys.length;index++){ var key=keys[index]; if(typeof key==='string'){ out[key]=makeTool(key,raw[key]); } } Object.freeze(out); var names=objectKeys(out); return new Proxy(out,{ get:function(object,property){ if(typeof property!=='string'||property in object||probes[property]){ return object[property]; } if(extras&&Object.prototype.hasOwnProperty.call(extras,property)){ return extras[property]; } var stemmed=names.filter(function(n){ return n.indexOf(property+'_')===0&&/^[0-9a-f]+$/.test(n.slice(property.length+1)); }); if(stemmed.length===1){ return object[stemmed[0]]; } var hashed=/^(.+)_[0-9a-f]{8}$/.exec(property); if(hashed){ var base=hashed[1]; var same=names.filter(function(n){ return n===base||(n.indexOf(base+'_')===0&&/^[0-9a-f]{8}$/.test(n.slice(base.length+1))); }); if(same.length===1){ return object[same[0]]; } } var close=nearest(property,names); throw new TypeError('tools.'+property+' is not a tool here.'+(close.length?' Closest: '+close.join(', ')+'.':'')+' searchTools("'+property.replace(/"/g,'')+'") finds tools by words.'); } }); }
function text(value){ if(busy===0&&!hasPending(value)){ G.text(value); return; } enqueue(async function(){ G.text(await settle(value,new Map(),0)); }); }
function image(value){ if(busy===0&&!hasPending(value)){ G.image(value); return; } enqueue(async function(){ G.image(await settle(value,new Map(),0)); }); }
function store(key,value){ if(busy===0&&!hasPending(value)){ G.store(key,value); return; } enqueue(async function(){ G.store(key,await settle(value,new Map(),0)); }); }
function load(key){ return G.load(key); }
/* Session variables (docs/CODEMODE.md, "Session variables"): vars.<name> is the session store's key "vars.<name>", so store/load stay the one persistence path. A write commits with the store's: when the script finishes; a script that throws keeps none of them. A delete is written as null, which the core drops from the row (the component seam refuses the prelude's bare [key] delete), so null and undefined both clear a variable. */
var VAR_PREFIX='vars.';
var VAR_MAX=65536;
var VARS_MAX=262144;
var varName=/^[A-Za-z_$][A-Za-z0-9_$]{0,63}$/;
var PLAIN=' Keep plain data: objects, arrays, strings, numbers, booleans, null.';
/* UTF-8 bytes through native calls only: a JavaScript loop over 60 KB of text spends the sandbox's fuel (three 60 KB writes ran it out, 15/11). */
var asciiOnly=/^[\x00-\x7f]*$/;
function utf8Bytes(text){ if(asciiOnly.test(text)){ return text.length; } try{ return unescape(encodeURIComponent(text)).length; }catch(error){ return text.length*3; } }
function makeVars(index){
 var sizes=Object.create(null);
 var given=index!==null&&typeof index==='object'&&!arrayIsArray(index)?objectKeys(index):[];
 for(var position=0;position<given.length;position++){ if(varName.test(given[position])&&typeof index[given[position]]==='number'){ sizes[given[position]]=index[given[position]]; } }
 /* What this script read or wrote, with the JSON it had: a value changed in place (vars.list.push(x)) is written back when the script ends, so a variable behaves like one. */
 var held=new Map();
 function others(name){ var sum=0; var names=objectKeys(sizes); for(var position=0;position<names.length;position++){ if(names[position]!==name){ sum+=sizes[names[position]]; } } return sum; }
 function check(name){ if(typeof name!=='string'||!varName.test(name)){ throw new TypeError('vars.'+String(name)+' is not a variable name: use an identifier (letters, digits, _ or $, not starting with a digit, at most 64 characters).'); } }
 function encode(name,value){ var json; try{ json=JSON.stringify(value); }catch(error){ throw new TypeError('vars.'+name+' cannot be kept: the value is not JSON-encodable ('+String(error&&error.message||error)+').'+PLAIN); } if(typeof json!=='string'){ throw new TypeError('vars.'+name+' cannot be kept: a '+typeof value+' is not JSON-encodable.'+PLAIN); } return json; }
 function remove(name){ G.store(VAR_PREFIX+name,null); delete sizes[name]; held.delete(name); }
 function write(name,value){
  if(value===undefined||value===null){ remove(name); return; }
  var json=encode(name,value);
  var bytes=utf8Bytes(json);
  if(bytes>VAR_MAX){ throw new RangeError('vars.'+name+' is '+bytes+' bytes of JSON, more than the '+VAR_MAX+' one variable may hold. Keep the IDs or a summary, or write the data to a file with a tool.'); }
  var after=others(name)+bytes;
  if(after>VARS_MAX){ throw new RangeError('vars are full: writing vars.'+name+' would make '+after+' bytes of JSON, more than the '+VARS_MAX+' a session may hold. delete vars.<name> for what you no longer need.'); }
  G.store(VAR_PREFIX+name,value);
  sizes[name]=bytes;
  held.set(name,{ value:value, json:json });
 }
 function read(name){ if(held.has(name)){ return held.get(name).value; } if(!(name in sizes)){ return undefined; } var value=G.load(VAR_PREFIX+name); if(value===null||value===undefined){ return undefined; } held.set(name,{ value:value, json:JSON.stringify(value) }); return value; }
 var proxy=new Proxy({},{
  get:function(object,property){ if(typeof property!=='string'||!varName.test(property)){ return undefined; } return read(property); },
  set:function(object,property,value){ check(property); if(busy===0&&!hasPending(value)){ write(property,value); return true; } enqueue(async function(){ write(property,await settle(value,new Map(),0)); }); return true; },
  deleteProperty:function(object,property){ check(property); remove(property); return true; },
  has:function(object,property){ return typeof property==='string'&&(property in sizes); },
  ownKeys:function(){ return objectKeys(sizes).sort(); },
  getOwnPropertyDescriptor:function(object,property){ if(typeof property!=='string'||!(property in sizes)){ return undefined; } return { value:read(property), writable:true, enumerable:true, configurable:true }; },
  defineProperty:function(object,property){ throw new TypeError('vars.'+String(property)+': assign vars.<name> = value instead of defining a property.'); }
 });
 function flush(){ held.forEach(function(entry,name){ if(name in sizes&&encode(name,entry.value)!==entry.json){ write(name,entry.value); } }); }
 return { proxy:proxy, flush:flush };
}
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
var results=Object.freeze({
 get:function(hash){ return track('results.get('+preview(hash)+')',rawResults({ op:'get', hash:hash })); },
 last:function(count,options){ return track('results.last('+preview(count)+')',rawResults({ op:'last', n:count, tool:options&&options.tool })); },
 diff:function(before,after){ return track('results.diff('+preview(before)+', '+preview(after)+')',rawResults({ op:'diff', a:before, b:after })); }
});
return {
 enter:async function(index,body){
  var vars=makeVars(index);
  /* The script helpers are reachable as tools.<name> too (14/11: tools.searchTools(...) read as "not a tool"): one name, wherever the model reaches for it. */
  var helpers={ searchTools:makeGlobal('searchTools',G.searchTools), describeTool:makeGlobal('describeTool',G.describeTool), showCall:makeGlobal('showCall',G.showCall), describe:makeGlobal('describe',G.describe), results:results, parallel:parallel, vars:vars.proxy };
  var value=await body(wrapTools(G.tools,helpers),makeConsole(G.console),helpers.searchTools,helpers.describeTool,helpers.showCall,makeGlobal('capabilities',G.capabilities),helpers.describe,results,parallel,text,store,load,image,G.exit,G.ALL_TOOLS,vars.proxy);
  var out=await settleAll(value);
  vars.flush();
  return out;
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
-- The script runs in its own block, so `const text = ...` (or store, load, image, exit, results, parallel)
-- shadows the helper instead of being "invalid redefinition of parameter name" (14/11). The brace stays on
-- line 1, so script line N is still compiled line N+1.
-- The session's variables arrive as `{name: bytes}` on line 1 (names are identifiers and sizes integers,
-- so the text holds no newline and the script's line numbers do not move).
local OPEN = ONE .. ";return await __h.enter("
local BODY = ",async function(tools, console, searchTools, describeTool, showCall, capabilities, describe, results, parallel, text, store, load, image, exit, ALL_TOOLS, vars){{"
M.prologue = OPEN .. "{}" .. BODY
M.epilogue = "\n}});"

local function index_json(vars)
  local parts = {}
  for _, entry in ipairs(type(vars) == "table" and vars or {}) do
    if type(entry) == "table" and type(entry.name) == "string" and entry.name:match("^[%a_$][%w_$]*$") and tonumber(entry.bytes) then
      parts[#parts + 1] = '"' .. entry.name .. '":' .. string.format("%d", math.floor(tonumber(entry.bytes)))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The script the node sends: the harness on line 1, the model's code from line 2. `vars` is the
-- session's variable index, `{ {name=, bytes=} ... }` (lua/core/codemode.lua `session_vars`).
function M.decorate(code, vars)
  if type(code) ~= "string" then return code end
  return OPEN .. index_json(vars) .. BODY .. "\n" .. code .. M.epilogue
end

return M
