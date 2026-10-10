// Hermetic contract test for the Pi bridge: no OAuth store or network access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-sub-test-'));
const largeArgs = JSON.stringify({path:'lua/core/large.lua',content:'x'.repeat(65536)});
const put = (name, value) => {
  const file = path.join(root, name);
  fs.mkdirSync(path.dirname(file), { recursive:true });
  fs.writeFileSync(file, value);
  return file;
};
try {
  put('pi/package.json', '{"type":"module"}');
  put('pi/dist/core/auth-storage.js', `export class AuthStorage {
    static create(path) {return {path, async read(provider) {
      if (provider !== 'openai-codex') throw new Error('unexpected auth provider');
      return {type:'oauth',accountId:'fixture-account'};
    }};}
  }`);
  put('pi/node_modules/@earendil-works/pi-ai/package.json', '{"type":"module"}');
  // The installed package knows only the id it shipped with; the route's catalogue is the store
  // below, which the bridge reads for an id newer than the installed package.
  const store = put('models-store.json', JSON.stringify({'openai-codex':{models:[
    {id:'gpt-6.1-sol',provider:'openai-codex',api:'openai-codex-responses',
      contextWindow:272000,maxTokens:128000},
    {id:'sol-store-foreign',provider:'opencode-go',api:'openai-codex-responses'},
    {id:'sol-store-protocol',provider:'openai-codex',api:'openai-responses'}]},
    'opencode-go':{models:[{id:'sol-store-wrongroute',provider:'opencode-go',
      api:'openai-completions'}]}}));
  put('pi/node_modules/@earendil-works/pi-ai/dist/providers/openai-codex.js',
    'export function openaiCodexProvider() {return {id:"openai-codex"};}');
  put('pi/node_modules/@earendil-works/pi-ai/dist/models.js', `
    import assert from 'node:assert/strict';
    globalThis.fetch = async (url, options) => {
      if(url==='https://fixture.invalid/responses') {
        const frame='data: '+JSON.stringify({type:'response.output_item.added',output_index:0,item:{type:'message',phase:globalThis.earlyMode==='known'?'commentary':undefined}})+'\\r\\n\\r\\n';
        const encoded=new TextEncoder().encode(frame);
        return new Response(new ReadableStream({start(controller){for(let i=0;i<encoded.length;i+=3)controller.enqueue(encoded.slice(i,i+3));controller.close();}}),{headers:{'Content-Type':'text/event-stream'}});
      }
      assert.equal(url,'https://chatgpt.com/backend-api/wham/usage');
      assert.equal(options.headers['ChatGPT-Account-Id'],'fixture-account');
      assert.equal(options.headers.Authorization,'Bearer fixture-access-token');
      return {ok:true,status:200,async json() {return {rate_limit:{
        primary_window:{used_percent:23,limit_window_seconds:18000,reset_at:2000000000},
        secondary_window:{used_percent:71,limit_window_seconds:604800,reset_at:2000003600},
        monthly_window:{used_percent:84,limit_window_seconds:2592000,reset_at:2000007200}
      }}}};
    };
    export function createModels({credentials}) {
      assert.equal(credentials.path, 'fixture-auth.json');
      return {
        setProvider(p) {assert.equal(p.id,'openai-codex');},
        async getAuth(provider) {assert.equal(provider,'openai-codex'); return {auth:{apiKey:'fixture-access-token'}};},
        getModel(provider,id) {return id==='gpt-6-luna' ? {id,provider,api:'openai-codex-responses'} : undefined;},
        stream(model,context,options) {
          if (context.tools[0].name === 'large_fixture') {
            const text = context.messages.at(-1).content[0].text;
            const args = JSON.parse(text);
            return {
              async *[Symbol.asyncIterator]() {
                yield {type:'toolcall_start',contentIndex:0,partial:{content:[{id:'pi-large',name:'large_fixture'}]}};
                const chunkSize = text.length<1024 ? 300 : 256;
                for (let i=0;i<text.length;i+=chunkSize) yield {type:'toolcall_delta',contentIndex:0,
                  delta:text.slice(i,i+chunkSize),partial:{content:[{id:'pi-large',name:'large_fixture'}]}};
                yield {type:'toolcall_end',contentIndex:0,
                  toolCall:{id:'call-large',name:'large_fixture',arguments:args}};
              },
              async result() {return {stopReason:'toolUse',responseId:'large-fixture',
                content:[{type:'toolCall',id:'call-large',name:'large_fixture',arguments:args}],
                usage:{input:0,cacheRead:0,cacheWrite:0,output:0,totalTokens:0,reasoning:0}};}
            };
          }
          if (context.tools[0].name === 'early_phase') {
            globalThis.earlyMode=context.messages.at(-1).content[0].text;
            return {async *[Symbol.asyncIterator]() {
              const response=await options.fetch('https://fixture.invalid/responses',{signal:options.signal});
              for await(const bytes of response.body) {};
              yield {type:'text_start',contentIndex:0,partial:{content:[{type:'text',text:''}]}};
              yield {type:'text_delta',contentIndex:0,delta:'Checking ',partial:{content:[{type:'text',text:'Checking '}]}};
              yield {type:'text_delta',contentIndex:0,delta:'now',partial:{content:[{type:'text',text:'Checking now'}]}};
              yield {type:'text_end',contentIndex:0,content:'Checking now',partial:{content:[{type:'text',text:'Checking now',textSignature:JSON.stringify({phase:'commentary'})}]}};
            },async result(){return {stopReason:'toolUse',content:[{type:'text',text:'Checking now',textSignature:JSON.stringify({phase:'commentary'})}],usage:{input:10,output:2,totalTokens:12}};}};
          }
          if (context.tools[0].name === 'phase_adversarial') {
            const mode=context.messages.at(-1).content[0].text;
            return {
              async *[Symbol.asyncIterator]() {
                yield {type:'text_delta',contentIndex:0,delta:'provisional',partial:{stopReason:'stop',content:[{type:'text',text:'provisional'}]}};
                if(mode==='error' || mode==='cancel') throw Error(mode==='cancel'?'fixture cancellation':'fixture provider error');
                yield {type:'text_end',contentIndex:0,content:'provisional',partial:{content:[{type:'text',text:'provisional',textSignature:mode==='malformed'?'broken':JSON.stringify({phase:'commentary'})}]}};
                yield {type:'text_delta',contentIndex:1,delta:'answer',partial:{stopReason:'stop',content:[null,{type:'text',text:'answer'}]}};
                yield {type:'text_end',contentIndex:1,content:'answer',partial:{content:[null,{type:'text',text:'answer',textSignature:JSON.stringify({phase:'final_answer'})}]}};
              },
              async result(){return {stopReason:'stop',content:[{type:'text',text:'answer'}],usage:{input:0,output:0,totalTokens:0}};}
            };
          }
          assert.equal(options.reasoningEffort,'none');
          assert.equal(options.transport,'sse');
          assert.equal(context.systemPrompt,'fixture system');
          assert.equal(context.messages[0].content[1].mimeType,'image/png');
          assert.equal(context.messages[1].content[0].arguments.tag,'luna');
          assert.equal(context.messages[2].toolName,'lookup_marker');
          const phased = context.messages.find(message => message.role === 'assistant' &&
            message.content.some(part => part.type === 'text' && part.text === 'phase fixture'));
          assert.ok(phased, 'phase-aware assistant message must reach Pi');
          const phaseText = phased.content.find(part => part.type === 'text' && part.text === 'phase fixture');
          assert.match(JSON.parse(phaseText.textSignature).id, /^msg_/,
            'phase replay must use a Responses message id');
          assert.equal(context.tools[0].name,'lookup_marker');
          return {
            async *[Symbol.asyncIterator]() {
              yield {type:'thinking_delta',delta:'thinking'};
              yield {type:'text_delta',contentIndex:0,delta:'Checking ',partial:{stopReason:'stop',content:[]}};
              yield {type:'text_delta',contentIndex:0,delta:'the result',
                partial:{content:[{type:'text',text:'Checking the result'}]}};
              yield {type:'text_end',contentIndex:0,content:'Checking the result',
                partial:{content:[{type:'text',text:'Checking the result',
                  textSignature:JSON.stringify({phase:'commentary'})}]}};
              yield {type:'text_delta',contentIndex:1,delta:'fixture '};
              yield {type:'text_delta',contentIndex:1,delta:'answer',
                partial:{content:[null,{type:'text',text:'fixture answer'}]}};
              yield {type:'text_end',contentIndex:1,content:'fixture answer',
                partial:{content:[null,{type:'text',text:'fixture answer',
                  textSignature:JSON.stringify({phase:'final_answer'})}]}};
            },
            async result() {return {stopReason:'toolUse',responseId:'fixture-id',
              content:[{type:'text',text:'Checking the result',
                  textSignature:JSON.stringify({phase:'commentary'})},
                {type:'text',text:'fixture answer',
                  textSignature:JSON.stringify({phase:'final_answer'})},
                {type:'toolCall',id:'call-2',name:'lookup_marker',arguments:{tag:'next'}}],
              usage:{input:10,cacheRead:20,cacheWrite:0,output:4,totalTokens:34,reasoning:2}};}
          };
        }
      };
    }
  `);
  const source = fs.readFileSync('lua/core/openai_sub_bridge.lua', 'utf8');
  const bridge = put('bridge.mjs', source.split('return [==[')[1].split(']==]')[0]);
  const request = {home:root,auth_path:'fixture-auth.json',model:'gpt-6-luna',reasoning:'none',
    tools:[{function:{name:'lookup_marker',description:'lookup',parameters:{type:'object'}}}],
    messages:[{role:'system',content:'fixture system'},
      {role:'user',content:[{type:'text',text:'hello'},{type:'image_url',image_url:{url:'data:image/png;base64,AA=='}}]},
      {role:'assistant',content:'',tool_calls:[{id:'call-1',function:{name:'lookup_marker',arguments:'{"tag":"luna"}'}}]},
      {role:'tool',tool_call_id:'call-1',content:'marker'},
      {role:'assistant',id:'wa_fixture-message',phase:'final_answer',content:'phase fixture'}]};
  const run = request => {
    const input = put('input.json', JSON.stringify(request));
    const response = spawnSync(process.execPath,[bridge,input],{encoding:'utf8',
      env:{...process.env,WASM_AGENT_PI_PACKAGE:path.join(root,'pi')}});
    assert.equal(fs.existsSync(input),false,'input must be removed by bridge');
    assert.equal(response.stderr,'');
    return {...response,events:response.stdout.trim().split('\n').map(line=>JSON.parse(line))};
  };
  for(const mode of ['known','unknown']) {
    const early=run({...request,tools:[{function:{name:'early_phase',parameters:{type:'object'}}}],messages:[{role:'user',content:mode}]});
    assert.equal(early.status,0,early.stdout);
    const deltas=early.events.filter(e=>e.type==='commentary_delta'||e.type==='pending_delta');
    assert.equal(deltas.length,2);
    assert(deltas.every(e=>e.type===(mode==='known'?'commentary_delta':'pending_delta')),'only explicit per-message early phase opens commentary');
    assert.equal(deltas.map(e=>e.text).join(''),'Checking now');
    assert.equal(early.events.filter(e=>e.type==='commentary').length,1,'completed identity resolves once');
  }
  const success=run(request);
  assert.equal(success.status,0,success.stdout);
  const pending=success.events.filter(event=>event.type==='pending_delta');
  const resolutions=success.events.filter(event=>event.type==='commentary' || event.type==='delta');
  assert.deepEqual(success.events.map(event=>event.type),[
    'reasoning','pending_delta','pending_delta','commentary',
    'pending_delta','pending_delta','final_answer_begin','delta','result']);
  const begin=success.events.find(event=>event.type==='final_answer_begin');
  assert.equal(begin.source,'pi.text_end.signature');
  assert.equal(begin.timing,'late');
  assert.equal(success.events.filter(event=>event.type==='final_answer_begin').length,1);
  for (const pendingId of new Set(pending.map(event=>event.pending_id))) {
    const provisional=pending.filter(event=>event.pending_id===pendingId).map(event=>event.text).join('');
    const resolved=resolutions.filter(event=>event.pending_id===pendingId);
    assert.equal(resolved.length,1,`pending text ${pendingId} must resolve once`);
    assert.equal(resolved[0].text,provisional,`pending text ${pendingId} must resolve without loss or duplication`);
  }
  assert.deepEqual(resolutions.map(event=>event.type),['commentary','delta']);
  assert.equal(resolutions[0].text,'Checking the result');
  assert.equal(resolutions[1].text,'fixture answer');
  const result=success.events.at(-1).result;
  assert.equal(result.commentary.length,1);
  assert.equal(result.commentary[0].content,'Checking the result');
  assert.equal(result.content,'fixture answer');
  assert.equal(result.tool_calls[0].function.arguments,'{"tag":"next"}');
  assert.equal(result.usage.prompt_tokens,30);
  assert.equal(result.usage.prompt_tokens_details.cached_tokens,20);
  assert.equal(result.finish_reason,'tool_calls');
  for(const mode of ['mixed','malformed','error','cancel']) {
    const adversarial=run({...request,tools:[{function:{name:'phase_adversarial',parameters:{type:'object'}}}],messages:[{role:'user',content:mode}]});
    assert.equal(adversarial.events[0].type,'pending_delta','mutable stopReason never classifies early');
    assert.equal(adversarial.events[0].text,'provisional','error retains prior provisional text');
    if(mode==='error'||mode==='cancel') {
      assert.equal(adversarial.status,1);
      assert.equal(adversarial.events.at(-1).type,'error');
      assert.equal(adversarial.events.filter(e=>e.type==='final_answer_begin').length,0);
    } else {
      assert.equal(adversarial.status,0);
      assert.equal(adversarial.events.filter(e=>e.type==='final_answer_begin').length,1);
      assert.equal(adversarial.events.find(e=>e.type==='final_answer_begin').timing,'late');
      assert.equal(adversarial.events[1].type,mode==='malformed'?'delta':'commentary');
    }
  }
  const missing=run({...request,model:'missing'});
  assert.equal(missing.status,1);
  assert.match(missing.events[0].error,/absent from Pi catalog/);
  // An id the installed package predates but the route's catalogue publishes resolves from the
  // store rather than failing at request time. This is what a newly published model looks like:
  // configured, and unusable until the catalogue is read. The resolved model is the one used -
  // the result names it, so a request cannot silently run the wrong id.
  const stored=run({...request,model:'gpt-6.1-sol',models_store:store});
  assert.equal(stored.status,0,stored.stderr||stored.stdout);
  assert.equal(stored.events.at(-1).result.model,'gpt-6.1-sol');
  // No catalogue, an unreadable one, or one that does not publish the id: the refusal is
  // unchanged, so the store can only ever add ids - it can never answer for a route it is not.
  for (const catalogue of [undefined,path.join(root,'no-such-store.json'),
      put('empty-store.json','{}')]) {
    const refused=run({...request,model:'gpt-6.1-sol',models_store:catalogue});
    assert.equal(refused.status,1,`a catalogue of ${catalogue} must not resolve an unpublished id`);
    assert.match(refused.events[0].error,/absent from Pi catalog/);
  }
  // Another route's entry, and an id published for this route over a protocol this bridge does
  // not speak, stay absent instead of being sent to the wrong edge.
  for (const foreign of ['sol-store-foreign','sol-store-protocol','sol-store-wrongroute']) {
    const refused=run({...request,model:foreign,models_store:store});
    assert.equal(refused.status,1,`${foreign} must not resolve on this route`);
    assert.match(refused.events[0].error,/absent from Pi catalog/);
  }
  const large=run({...request,tools:[{function:{name:'large_fixture',parameters:{type:'object'}}}],
    messages:[...request.messages,{role:'user',content:largeArgs}]});
  assert.equal(large.status,0,large.stderr);
  const bytes=Buffer.byteLength(large.stdout);
  assert.ok(bytes<8*1024*1024,`bounded stream must fit operation limit: ${bytes}`);
  assert.ok(bytes<2*Buffer.byteLength(JSON.stringify(largeArgs))+65536,
    `bounded stream should grow linearly with encoded arguments: ${bytes}`);
  const decisions=large.events.filter(event=>event.type==='decision');
  assert.deepEqual(decisions.map(event=>[event.call_id,event.complete,event.previous_call_id]),
    [['pi-large',false,undefined],['pi-large',false,undefined],
      ['pi-large',false,undefined],['call-large',true,'pi-large']]);
  assert.ok(decisions.at(-1).arguments_truncated);
  assert.equal(decisions.at(-1).arguments_text,
    largeArgs.slice(0,256)+'… [preview only; complete arguments in result]');
  assert.equal(large.events.at(-1).result.tool_calls[0].function.arguments,largeArgs);
  // A first delta beyond the preview cap must announce truncation exactly once.
  const oneChunk=run({...request,tools:[{function:{name:'large_fixture',parameters:{type:'object'}}}],
    messages:[...request.messages,{role:'user',content:JSON.stringify({content:'z'.repeat(300)})}]});
  assert.equal(oneChunk.status,0,oneChunk.stderr);
  assert.equal(oneChunk.events.filter(event=>event.type==='decision' && !event.complete && event.arguments_truncated).length,1);
  const malformed=run({...request,messages:[...request.messages,{role:'unexpected'}]});
  assert.equal(malformed.status,1);
  assert.match(malformed.events[0].error,/Unsupported subscription message role/);
  const limits=run({...request,action:'limits'});
  assert.equal(limits.status,0,limits.stdout);
  assert.deepEqual(limits.events[0].limits,{rolling:{status:'available',percent:23,
    resetsAt:'2033-05-18T03:33:20.000Z'},weekly:{status:'available',percent:71,
    resetsAt:'2033-05-18T04:33:20.000Z'},monthly:{status:'available',percent:84,
    resetsAt:'2033-05-18T05:33:20.000Z'}});
  if (process.argv[2]) {
    const nativeInput=put('native-request.json',JSON.stringify(request));
    const fixture=put('native.lua',`
local json=dofile('lua/vendor/json.lua')
local adapter=dofile('lua/core/openai_sub.lua')
local request=json.decode(host.read_file(host.getenv('WA_SUB_REQUEST')))
adapter.auth_path=function() return 'fixture-auth.json' end
for n=1,12 do
  local result=adapter.complete(request.model,request.messages,request.tools,false,{session_id='native-fixture'},{selected='off'})
  assert(result.content=='fixture answer' and result.stream_complete==true,'native bridge must settle and retain complete output')
end
assert(adapter.limits().rolling.percent==23,'native limits bridge must settle')
local ok,why=pcall(adapter.complete,'missing',request.messages,request.tools,false,{}, {selected='off'})
assert(not ok and tostring(why):find('absent from Pi catalog',1,true),'provider errors remain visible')
-- The catalogue travels with the request: an id the installed package predates resolves from
-- the store the Lua layer named, and another route id does not.
local stored=adapter.complete('gpt-6.1-sol',request.messages,request.tools,false,{session_id='native-fixture'},{selected='off'})
assert(stored.content=='fixture answer' and stored.model=='gpt-6.1-sol','the store-published id must resolve through the bridge')
local refused=pcall(adapter.complete,'sol-store-wrongroute',request.messages,request.tools,false,{}, {selected='off'})
assert(not refused,'another route id must not resolve on the subscription route')
local rejected=json.decode(host.operation('start',json.encode({program='node',args={},command='echo must-not-run'})))
assert(rejected.error=='program_and_command_are_exclusive','ambiguous launch must be refused')
print('native subscription operations ok (15 checks)')
`);
    const env={...process.env};
    for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];
    const nativeTemp=path.join(root,'native temp');fs.mkdirSync(nativeTemp);
    Object.assign(env,{TEMP:nativeTemp,TMP:nativeTemp,TMPDIR:nativeTemp,WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:process.cwd(),WASM_AGENT_PI_PACKAGE:path.join(root,'pi'),
      WASM_AGENT_PI_MODELS_STORE:store,
      WASM_AGENT_SHELL:path.join(root,'nonexistent-shell'),WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
      WA_SCRIPT:fixture,WA_SUB_REQUEST:nativeInput});
    const native=spawnSync(path.resolve(process.argv[2]),['--db',path.join(root,'native.db')],{env,encoding:'utf8',timeout:60000,windowsHide:true});
    assert.equal(native.status,0,native.stderr||String(native.error));
    assert.match(native.stdout,/native subscription operations ok \(15 checks\)/);
    console.log(native.stdout.trim());
  }
  console.log('PASS OpenAI subscription bridge: messages, images, tools, stream, usage, limits and visible failures');
} finally {fs.rmSync(root,{recursive:true,force:true});}
