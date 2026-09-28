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
  put('pi/node_modules/@earendil-works/pi-ai/dist/providers/openai-codex.js',
    'export function openaiCodexProvider() {return {id:"openai-codex"};}');
  put('pi/node_modules/@earendil-works/pi-ai/dist/models.js', `
    import assert from 'node:assert/strict';
    globalThis.fetch = async (url, options) => {
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
        getModel(provider,id) {return id==='missing' ? undefined : {id,provider,api:'openai-codex-responses'};},
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
              yield {type:'text_delta',contentIndex:0,delta:'Checking '};
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
  const success=run(request);
  assert.equal(success.status,0,success.stdout);
  const pending=success.events.filter(event=>event.type==='pending_delta');
  const resolutions=success.events.filter(event=>event.type==='commentary' || event.type==='delta');
  assert.deepEqual(success.events.map(event=>event.type),[
    'reasoning','pending_delta','pending_delta','commentary',
    'pending_delta','pending_delta','delta','result']);
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
  const missing=run({...request,model:'missing'});
  assert.equal(missing.status,1);
  assert.match(missing.events[0].error,/absent from Pi catalog/);
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
local rejected=json.decode(host.operation('start',json.encode({program='node',args={},command='echo must-not-run'})))
assert(rejected.error=='program_and_command_are_exclusive','ambiguous launch must be refused')
print('native subscription operations ok (15 checks)')
`);
    const env={...process.env};
    for(const key of Object.keys(env))if(/^(WA_|WASM_AGENT_)/.test(key))delete env[key];
    const nativeTemp=path.join(root,'native temp');fs.mkdirSync(nativeTemp);
    Object.assign(env,{TEMP:nativeTemp,TMP:nativeTemp,TMPDIR:nativeTemp,WASM_AGENT_HOME:root,WASM_AGENT_LUA_ROOT:process.cwd(),WASM_AGENT_PI_PACKAGE:path.join(root,'pi'),
      WASM_AGENT_SHELL:path.join(root,'nonexistent-shell'),WASM_AGENT_RELAY:'',WASM_AGENT_RENDEZVOUS:'',
      WA_SCRIPT:fixture,WA_SUB_REQUEST:nativeInput});
    const native=spawnSync(path.resolve(process.argv[2]),['--db',path.join(root,'native.db')],{env,encoding:'utf8',timeout:60000,windowsHide:true});
    assert.equal(native.status,0,native.stderr||String(native.error));
    assert.match(native.stdout,/native subscription operations ok \(15 checks\)/);
    console.log(native.stdout.trim());
  }
  console.log('PASS OpenAI subscription bridge: messages, images, tools, stream, usage, limits and visible failures');
} finally {fs.rmSync(root,{recursive:true,force:true});}
