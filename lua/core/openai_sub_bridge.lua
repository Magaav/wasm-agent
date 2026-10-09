-- Pi owns OAuth refresh, locking and the subscription wire protocol. This helper
-- never returns credentials to Lua or puts them in a command line.
return [==[
import { readFileSync, unlinkSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const send = value => new Promise(resolve => process.stdout.write(JSON.stringify(value) + '\n', resolve));
const redactError = value => String(value || '').replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '<redacted>')
  .replace(/Bearer\s+\S+/gi, 'Bearer <redacted>').replace(/sk-[\w-]+/g, '<redacted>')
  .replace(/https?:\/\/[^\s)]+/gi,'<url-redacted>');
const transientCodes = new Set(['UND_ERR_SOCKET','UND_ERR_RES_CONTENT_LENGTH_MISMATCH',
  'UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT','ECONNRESET','ECONNREFUSED','EPIPE','ETIMEDOUT','EAI_AGAIN']);
const causeChain = error => {
  const chain=[],seen=new Set();
  for(let current=error;current && !seen.has(current) && chain.length<4;current=current.cause) {
    seen.add(current);
    const raw=redactError(current.message || current);
    chain.push({name:redactError(current.name || 'Error').slice(0,80),code:typeof current.code==='string' && /^[A-Z][A-Z0-9_]{0,79}$/.test(current.code) ? current.code : null,
      message:raw.slice(0,256),message_truncated:raw.length>256});
  }
  return chain;
};
// Observe below Pi's error normalizer, which otherwise drops Node's error.cause.
// Never copy URLs, headers, request bodies or streamed text into diagnostics.
// Error messages are bounded/redacted heuristically; cause codes are typed identifiers.
function observedFetch(state,onConnected) {
  const fetchImpl=globalThis.fetch.bind(globalThis);
  return async (url,options) => {
    state.fetch_observed=true;state.stage='response_headers';
    let response;
    try {response=await fetchImpl(url,options);} catch(error) {state.causes=causeChain(error);state.cancelled=options?.signal?.aborted===true;throw error;}
    state.http_status=response.status;
    if(response.ok)onConnected?.();
    for(const name of ['x-request-id','request-id']) {
      const value=response.headers.get(name);
      if(value && /^[a-zA-Z0-9_-]{1,128}$/.test(value)) {state.request_id=value;break;}
    }
    if(!response.body) return response;
    const reader=response.body.getReader();state.stage='response_body';
    const body=new ReadableStream({
      async pull(controller) {
        try {
          const item=await reader.read();
          if(item.done) {state.body_eof=true;reader.releaseLock();controller.close();}
          else {state.response_bytes+=item.value.byteLength;controller.enqueue(item.value);}
        } catch(error) {state.causes=causeChain(error);state.cancelled=options?.signal?.aborted===true;try{reader.releaseLock();}catch{} controller.error(error);}
      },
      async cancel(reason) {try{return await reader.cancel(reason);}finally{try{reader.releaseLock();}catch{}}}
    });
    return new Response(body,{status:response.status,statusText:response.statusText,headers:response.headers});
  };
}
async function main() {
let request,activeTransport;
try {
  const input = process.argv[2];
  request = JSON.parse(readFileSync(input, 'utf8'));
  unlinkSync(input);
  const names = ['@earendil-works/pi-coding-agent', '@mariozechner/pi-coding-agent'];
  const roots = [process.env.WASM_AGENT_PI_PACKAGE,
    ...names.flatMap(name => [
      join(request.home, 'AppData/Roaming/npm/node_modules', name),
      join(request.home, '.npm-global/lib/node_modules', name),
      join(request.home, '.local/lib/node_modules', name),
      join(dirname(dirname(process.execPath)), 'lib/node_modules', name),
      join('/usr/local/lib/node_modules', name), join('/usr/lib/node_modules', name),
    ])].filter(Boolean);
  for (const name of names) {
    try { roots.unshift(dirname(createRequire(join(request.home, 'package.json')).resolve(name + '/package.json'))); }
    catch { /* Try explicit/global installation paths below. */ }
  }
  const root = roots.find(root => existsSync(join(root, 'dist/core/auth-storage.js')));
  if (!root) throw new Error('Install Pi or set WASM_AGENT_PI_PACKAGE to its package directory');
  const load = path => import(pathToFileURL(path).href);
  const { AuthStorage } = await load(join(root, 'dist/core/auth-storage.js'));
  const requirePi = createRequire(join(root, 'package.json'));
  let ai;
  for (const name of ['@earendil-works/pi-ai', '@mariozechner/pi-ai']) {
    const nested = join(root, 'node_modules', name, 'dist');
    if (existsSync(join(nested, 'models.js'))) { ai=nested; break; }
    try { ai = dirname(requirePi.resolve(name)); break; } catch {}
  }
  if (!ai) throw new Error('Pi AI package is missing');
  const { createModels } = await load(join(ai, 'models.js'));
  const { openaiCodexProvider } = await load(join(ai, 'providers/openai-codex.js'));
  const credentials = AuthStorage.create(request.auth_path);
  const models = createModels({ credentials });
  models.setProvider(openaiCodexProvider());
  // Pi's *installed package* catalogues the ids it shipped with. The route's catalogue is the
  // store below - the same file wasm-agent's preflight decides servability from - and Pi's own
  // runtime overlays it too. An id newer than the installed Pi resolves here rather than being
  // reported absent: `Model is absent from Pi catalog; update Pi: <id>` at request time is what
  // a newly published model looked like before this, i.e. configured and unusable. Read-only:
  // the store is pi's file and wasm-agent neither writes nor extends it.
  const storedModel = id => {
    try {
      const store = JSON.parse(readFileSync(request.models_store, 'utf8'));
      const published = (store && store['openai-codex'] && store['openai-codex'].models) || [];
      return published.find(candidate => candidate && candidate.id === id &&
        candidate.provider === 'openai-codex' && candidate.api === 'openai-codex-responses')
        || undefined;
    } catch { return undefined; }
  };
  if (request.action === 'limits') {
    // Ask Pi to resolve/refresh OAuth under its own credential-store lock. The
    // access token stays in this child and is never returned to Lua or persisted
    // by wasm-agent. OpenAI's subscription endpoint is private and can change.
    const resolved = await models.getAuth('openai-codex');
    const credential = await credentials.read('openai-codex');
    if (!resolved?.auth?.apiKey || !credential?.accountId) {
      await send({type:'limits', limits:{}});
      return;
    }
    const response = await fetch('https://chatgpt.com/backend-api/wham/usage', {
      headers:{'Accept':'application/json', 'Authorization':`Bearer ${resolved.auth.apiKey}`,
        'ChatGPT-Account-Id':credential.accountId, 'User-Agent':'codex-cli'}
    });
    if (!response.ok) throw new Error(`subscription_limits_http_${response.status}`);
    const payload = await response.json();
    const root = payload.rate_limits || payload.rate_limit || {};
    const limits = {};
    const addWindow = (window, fallback) => {
      if (!window || !Number.isFinite(Number(window.used_percent))) return;
      const duration = Number(window.limit_window_seconds);
      const key = Number.isFinite(duration)
        ? (duration >= 2592000 ? 'monthly' : duration >= 172800 ? 'weekly' : 'rolling')
        : fallback;
      limits[key] = {status:window.limit_reached ? 'limited' : 'available',
        percent:Number(window.used_percent),
        resetsAt:Number.isFinite(Number(window.reset_at))
          ? new Date(Number(window.reset_at)*1000).toISOString() : null};
    };
    addWindow(root.primary_window || root.primary || root.five_hour, 'rolling');
    addWindow(root.secondary_window || root.secondary || root.weekly, 'weekly');
    addWindow(root.tertiary_window || root.tertiary || root.monthly_window || root.monthly, 'monthly');
    await send({type:'limits', limits});
    return;
  }
  const model = models.getModel('openai-codex', request.model) || storedModel(request.model);
  if (!model) throw new Error('Model is absent from Pi catalog; update Pi: ' + request.model);
  const zeroUsage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0,
    cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };
  const responseMessageId = id => {
    // Responses input message ids must use the provider's `msg` namespace. The
    // durable wasm-agent id is still useful for stability, but its `wa_` prefix
    // is not a valid Responses message id.
    const value = String(id || 'message').replace(/[^a-zA-Z0-9_-]/g, '_');
    return `msg_${value}`.slice(0,64);
  };
  const textParts = (content, phase, id) => {
    // Pi's Responses adapter reads this signature to round-trip message phase.
    const textPart = text => ({type:'text', text,
      ...(phase ? {textSignature:JSON.stringify({v:1, id:responseMessageId(id), phase})} : {})});
    if (typeof content === 'string') return [textPart(content)];
    return (content || []).map(part => {
      if (part.type === 'text') return textPart(part.text);
      const url = part.image_url?.url;
      const match = typeof url === 'string' && url.match(/^data:([^;]+);base64,(.*)$/s);
      if (!match) throw new Error('Unsupported subscription image part');
      return {type:'image', mimeType:match[1], data:match[2]};
    });
  };
  const messages = [];
  const system = [];
  const toolNames = new Map();
  for (const message of request.messages) {
    if (message.role === 'system') { system.push(message.content); continue; }
    if (message.role === 'assistant') {
      const content = message.content ? textParts(message.content, message.phase, message.id) : [];
      for (const call of message.tool_calls || []) {
        toolNames.set(call.id, call.function.name);
        content.push({type:'toolCall', id:call.id, name:call.function.name,
          arguments:JSON.parse(call.function.arguments || '{}')});
      }
      messages.push({role:'assistant', content, api:model.api, provider:model.provider,
        model:model.id, usage:zeroUsage, stopReason:message.tool_calls?.length ? 'toolUse' : 'stop', timestamp:0});
    } else if (message.role === 'tool') {
      messages.push({role:'toolResult', toolCallId:message.tool_call_id,
        toolName:toolNames.get(message.tool_call_id) || 'tool', content:textParts(message.content),
        isError:false, timestamp:0});
    } else if (message.role === 'user') {
      messages.push({role:'user', content:textParts(message.content), timestamp:0});
    } else throw new Error('Unsupported subscription message role: ' + message.role);
  }
  const context = {systemPrompt:system.join('\n\n'), messages,
    tools:(request.tools || []).map(tool => ({name:tool.function.name,
      description:tool.function.description, parameters:tool.function.parameters}))};
  const started = Date.now();
  let ttft;
  let reasoningText = '';
  const streamedFinalText = new Set();
  const toolDecisions = new Map();
  let attemptTag=request.stream_id || 'stream';
  let attemptTexts=new Map(),attemptDecisions=new Map(),attemptThoughts=new Map(),lastPartialContent;
  // This bridge never dispatches tools. Known adapter output is provisional until
  // a successful result reaches Lua; regenerating it cannot replay an old tool.
  // Reject new event/block fields rather than treating invisible output as safe.
  const knownBlocks = content => Array.isArray(content) && Array.from(content).every(block => {
    if(!block || typeof block!=='object' || Array.isArray(block))return false;
    const fields=block.type==='text' ? ['type','text','textSignature']
      : block.type==='thinking' ? ['type','thinking','thinkingSignature']
      : block.type==='toolCall' ? ['type','id','name','arguments','partialJson','namespace'] : null;
    if(!fields || Object.keys(block).some(key=>!fields.includes(key)))return false;
    if(block.type==='toolCall')return typeof block.id==='string' && block.id!=='' && typeof block.name==='string'
      && block.arguments!==null && typeof block.arguments==='object' && !Array.isArray(block.arguments)
      && (block.partialJson===undefined || typeof block.partialJson==='string')
      && (block.namespace===undefined || typeof block.namespace==='string');
    const field=block.type==='text'?'text':'thinking',signature=block.type==='text'?'textSignature':'thinkingSignature';
    return typeof block[field]==='string' && (block[signature]===undefined || typeof block[signature]==='string');
  });
  const knownProvisionalEvent = event => {
    const fields={start:['type','partial'],error:['type','reason','error'],done:['type','reason','message'],
      text_start:['type','contentIndex','partial'],thinking_start:['type','contentIndex','partial'],
      text_delta:['type','contentIndex','delta','partial'],thinking_delta:['type','contentIndex','delta','partial'],
      text_end:['type','contentIndex','content','partial'],thinking_end:['type','contentIndex','content','partial'],
      toolcall_start:['type','contentIndex','partial'],toolcall_delta:['type','contentIndex','delta','partial'],
      toolcall_end:['type','contentIndex','toolCall','partial']}[event.type];
    if(!fields || Object.keys(event).some(key=>!fields.includes(key)))return false;
    if(event.type==='error')return knownBlocks(event.error?.content);
    if(event.type==='done')return knownBlocks(event.message?.content);
    if(event.type==='start')return knownBlocks(event.partial?.content);
    const content=event.partial?.content,index=event.contentIndex;
    if(!Number.isInteger(index) || index<0 || !knownBlocks(content) || index>=content.length)return false;
    const expected=event.type.startsWith('text_')?'text':event.type.startsWith('thinking_')?'thinking':'toolCall';
    if(content[index].type!==expected)return false;
    if(event.type.endsWith('_delta') && typeof event.delta!=='string')return false;
    if(event.type.endsWith('_end') && expected!=='toolCall' && typeof event.content!=='string')return false;
    return event.type!=='toolcall_end' || knownBlocks([event.toolCall]);
  };
  const partialToolCall = event => event.partial?.content?.[event.contentIndex] || {};
  // Item-open is not output. Only exact known empty blocks are replay-safe:
  // a signature/encrypted thought, tool placeholder, unknown property or missing
  // snapshot remains conservative. Check the whole snapshot, not only the new item.
  const knownEmptyBlocks = content => Array.isArray(content) && Array.from(content).every(block => {
    if(!block || typeof block!=='object' || Array.isArray(block)) return false;
    const field=block.type==='text' ? 'text' : block.type==='thinking' ? 'thinking' : null;
    return field!==null && block[field]==='' && Object.keys(block).every(key=>key==='type'||key===field);
  });
  const emptyItemStart = event => {
    const field=event.type==='text_start' ? 'text' : event.type==='thinking_start' ? 'thinking' : null;
    const index=event.contentIndex,content=event.partial?.content;
    return field!==null && Object.keys(event).every(key=>['type','contentIndex','partial'].includes(key))
      && Number.isInteger(index) && index>=0 && Array.isArray(content)
      && index<content.length && content[index]?.type===(field==='text'?'text':'thinking')
      && knownEmptyBlocks(content);
  };
  const recordProgress = event => {
    if(knownBlocks(event.partial?.content))lastPartialContent=event.partial.content;
    if(!knownProvisionalEvent(event)) {
      activeTransport.uncommitted_retry_safe=false;
      if(!['start','error','done'].includes(event.type)) {
        activeTransport.model_output_seen=true;
        activeTransport.output_progress_class ??= 'unknown_adapter_shape';
      }
    }
    const known=['start','error','done','text_start','thinking_start','text_delta','thinking_delta',
      'text_end','thinking_end','toolcall_start','toolcall_delta','toolcall_end'];
    activeTransport.last_adapter_event=known.includes(event.type)?event.type:'unknown_progress';
    if(emptyItemStart(event)) {
      const field=event.type==='text_start'?'text':'thinking';
      activeTransport.empty_item_starts[field]++;
      return;
    }
    if(!['start','error','done'].includes(event.type)) {
      activeTransport.model_output_seen=true;
      activeTransport.output_progress_class ??= activeTransport.last_adapter_event;
      return true;
    }
  };
  // Decisions are display telemetry; the result below carries exact arguments for execution.
  // Never re-emit the growing argument prefix on every token (quadratic wire output).
  const publishDecision = (decision, complete, previousId) => {
    if(previousId)attemptDecisions.delete(previousId);
    const value={type:'decision',
    call_id:decision.id, ...(previousId && previousId !== decision.id ? {previous_call_id:previousId} : {}),
    name:decision.name, arguments_text:(decision.preview || '') +
      (decision.truncated ? '… [preview only; complete arguments in result]' : ''), complete,
    ...(decision.truncated ? {arguments_truncated:true} : {})};
    attemptDecisions.set(decision.id,value);
    return send(value);
  };
  const midstreamRecovery=request.midstream_recovery===true;
  const retryLimit=request.transport_retries ?? 10;
  if(!Number.isInteger(retryLimit) || retryLimit<0 || retryLimit>10) throw Error('invalid_subscription_transport_retries');
  const recoveryWindow=request.recovery_window_ms ?? 60000;
  if(!Number.isInteger(recoveryWindow) || recoveryWindow<1 || recoveryWindow>60000) throw Error('invalid_subscription_recovery_window');
  const interval=recoveryWindow/Math.max(1,retryLimit);
  const initialWait=Math.min(500,interval/4);
  const cooldownMs=request.reconnect_cooldown_ms ?? 180000;
  if(!Number.isInteger(cooldownMs) || cooldownMs<1 || cooldownMs>180000) throw Error('invalid_subscription_reconnect_cooldown');
  let recoveryStarted,retryIndex=0,cycle=1;
  const retryEvent=async(state,reason,extra={})=>send({type:'retry',retry_id:request.stream_id || 'subscription-recovery',
    index:retryIndex,limit:retryLimit,cycle,state,reason,window_ms:recoveryWindow,
    elapsed_ms:recoveryStarted===undefined ? 0 : Date.now()-recoveryStarted,...extra});
  const timeoutMs=request.timeout_ms ?? 3600000;
  if(!Number.isInteger(timeoutMs) || timeoutMs<1 || timeoutMs>86400000) throw Error('invalid_subscription_timeout');
  const deadline=Date.now()+timeoutMs;
  const restartCycle=async(reason)=>{
    await retryEvent('exhausted',reason);
    if(Date.now()+cooldownMs>=deadline) {
      await retryEvent('exhausted','Original request deadline cannot fit another reconnect check');
      throw Error('subscription_retry_deadline_exhausted; '+reason);
    }
    await retryEvent('reconnecting',reason,{wait_ms:cooldownMs,cooldown_ms:cooldownMs});
    await new Promise(resolve=>setTimeout(resolve,cooldownMs));
    if(Date.now()>=deadline) throw Error('subscription_retry_deadline_exhausted');
    cycle++;retryIndex=0;recoveryStarted=Date.now();
  };
  let answer,lastFailure='Recovery window expired';
  for(let attempt=1;;attempt++) {
    answer=undefined;
    attemptTag=(request.stream_id || 'stream')+(attempt===1?'':':attempt-'+attempt);
    reasoningText='';attemptTexts=new Map();attemptDecisions=new Map();attemptThoughts=new Map();lastPartialContent=undefined;
    toolDecisions.clear();streamedFinalText.clear();
    activeTransport={schema_version:1,attempt,stage:'adapter',fetch_observed:false,response_bytes:0,
      body_eof:false,model_output_seen:false,uncommitted_retry_safe:true,empty_item_starts:{text:0,thinking:0},causes:[]};
    let recoveryTimer;
    const recoveryController=new AbortController();
    if(retryIndex>0) {
      let remaining=Math.min(deadline,recoveryStarted+recoveryWindow)-Date.now();
      if(remaining<=0) {
        await restartCycle(lastFailure);retryIndex=1;
        remaining=Math.min(deadline,recoveryStarted+recoveryWindow)-Date.now();
      }
      await retryEvent('attempting','Reconnecting to provider');
      recoveryTimer=setTimeout(()=>{activeTransport.recovery_timeout=true;recoveryController.abort();},Math.min(interval,remaining));
    }
    try {
      const stream = models.stream(model, context, {sessionId:request.session_id,
        transport:'sse', reasoningEffort:request.reasoning, maxTokens:request.max_output,
        maxRetries:0,signal:recoveryController.signal,fetch:observedFetch(activeTransport,()=>{
          clearTimeout(recoveryTimer);
          if(retryIndex>0)retryEvent('connected','Provider connection established; waiting for model output');
        })});
      for await (const event of stream) {
        // Unknown shapes fence regeneration. Known output is still uncommitted:
        // no tool dispatch is possible inside this bridge.
        if(recordProgress(event)) clearTimeout(recoveryTimer);
    if (event.type === 'text_delta' || event.type === 'thinking_delta') {
      ttft ??= Date.now() - started;
      // A response-global mutable stopReason is not a per-item phase.
      if (event.type === 'text_delta') {
        const id=`${attemptTag}:${event.contentIndex}`;
        const item=attemptTexts.get(id) || {pending_id:id,text:'',phase:''};
        item.text+=event.delta;attemptTexts.set(id,item);
        send({type:'pending_delta', pending_id:id, text:event.delta});
      } else if (event.type === 'thinking_delta') {
        reasoningText += event.delta;
        attemptThoughts.set(event.contentIndex,(attemptThoughts.get(event.contentIndex)||'')+event.delta);
        send({type:'reasoning', text:event.delta, chars:[...reasoningText].length});
      }
    } else if (event.type === 'thinking_end') {
      attemptThoughts.set(event.contentIndex,event.content || event.partial?.content?.[event.contentIndex]?.thinking || '');
    } else if (event.type === 'text_end') {
      ttft ??= Date.now() - started;
      const block = event.partial?.content?.[event.contentIndex] || {};
      let phase = '';
      try {
        const value = JSON.parse(block.textSignature || '{}').phase;
        if (value === 'commentary' || value === 'final_answer') phase = value;
      } catch {}
      // Pi exposes final_answer while deltas are arriving, but commentary only
      // on the completed text block's signature. Keep unclassified text visibly
      // provisional, then resolve it to commentary or the completed answer here.
      const pendingId = `${attemptTag}:${event.contentIndex}`;
      attemptTexts.set(pendingId,{pending_id:pendingId,text:event.content || block.text || '',phase});
      if (phase === 'final_answer') send({type:'final_answer_begin', message_id:pendingId,
        pending_id:pendingId, source:'pi.text_end.signature', timing:'late'});
      if (phase === 'commentary') send({type:'commentary', pending_id:pendingId, text:event.content || block.text || ''});
      else if (!streamedFinalText.has(event.contentIndex)) send({type:'delta', pending_id:pendingId, text:event.content || block.text || ''});
      streamedFinalText.delete(event.contentIndex);
    } else if (event.type === 'toolcall_start') {
      ttft ??= Date.now() - started;
      const index = event.contentIndex;
      const block = partialToolCall(event);
      const decision = {id:block.id || `pi-${index}`, name:block.name || '', preview:'', truncated:false, announced:false};
      toolDecisions.set(index, decision);
      publishDecision(decision, false);
    } else if (event.type === 'toolcall_delta') {
      ttft ??= Date.now() - started;
      const index = event.contentIndex;
      const block = partialToolCall(event);
      let decision = toolDecisions.get(index);
      if (!decision) {
        decision = {id:block.id || `pi-${index}`, name:block.name || '', preview:'', truncated:false, announced:false};
        toolDecisions.set(index, decision);
      }
      decision.name = block.name || decision.name;
      const points = Array.from(event.delta || '');
      const room = Math.max(0, 256 - Array.from(decision.preview).length);
      decision.preview += points.slice(0, room).join('');
      if (points.length > room) decision.truncated = true;
      if (points.length && !decision.announced) {
        decision.announced = true;
        if (decision.truncated) decision.truncationAnnounced = true;
        publishDecision(decision, false);
      } else if (decision.truncated && !decision.truncationAnnounced) {
        decision.truncationAnnounced = true;
        publishDecision(decision, false);
      }
    } else if (event.type === 'toolcall_end') {
      ttft ??= Date.now() - started;
      const index = event.contentIndex;
      const call = event.toolCall || {};
      let decision = toolDecisions.get(index);
      if (!decision) decision = {id:call.id || `pi-${index}`, name:call.name || '', preview:'', truncated:false, announced:false};
      const previousId = decision.id;
      decision.id = call.id || decision.id;
      decision.name = call.name || decision.name;
      const finalPoints = Array.from(JSON.stringify(call.arguments || {}));
      decision.preview = finalPoints.slice(0, 256).join('');
      decision.truncated = finalPoints.length > 256;
      publishDecision(decision, true, previousId);
      toolDecisions.delete(index);
    }
  }
      answer = await stream.result();
      if (answer.stopReason === 'error' || answer.stopReason === 'aborted') {
        if(!knownBlocks(answer.content))activeTransport.uncommitted_retry_safe=false;
        if(!knownEmptyBlocks(answer.content)) {
          activeTransport.model_output_seen=true;
          activeTransport.output_progress_class ??= 'failed_result_content';
        }
        throw new Error(answer.errorMessage || answer.stopReason);
      }
      clearTimeout(recoveryTimer);
      if(activeTransport.fetch_observed || attempt>1)
        await send({type:'transport_attempt',diagnostic:{...activeTransport,ok:true,elapsed_ms:Date.now()-started}});
      if(retryIndex>0) await retryEvent('recovered','Provider response restored');
      break;
    } catch(error) {
      if(!activeTransport.causes.length) activeTransport.causes=causeChain(error);
      const status=activeTransport.http_status;
      clearTimeout(recoveryTimer);
      const ownTimeout=activeTransport.recovery_timeout===true;
      const aborted=!ownTimeout && (activeTransport.cancelled===true || answer?.stopReason==='aborted'
        || activeTransport.causes.some(c=>['AbortError','TimeoutError'].includes(c.name)));
      const knownTransient=!aborted && activeTransport.fetch_observed
        && (ownTimeout || activeTransport.causes.some(c=>transientCodes.has(c.code)))
        && (status===undefined || status===200)
        && ((!activeTransport.model_output_seen && activeTransport.uncommitted_retry_safe)
          || (midstreamRecovery && activeTransport.uncommitted_retry_safe));
      if(knownTransient && recoveryStarted===undefined) recoveryStarted=Date.now();
      let recoveryDeadline=Math.min(deadline,(recoveryStarted ?? Date.now())+recoveryWindow);
      const nextCycle=knownTransient && retryLimit>0 && (retryIndex>=retryLimit || Date.now()>=recoveryDeadline);
      const retry=knownTransient && retryLimit>0 && Date.now()<deadline;
      await send({type:'transport_attempt',diagnostic:{...activeTransport,ok:false,retry_scheduled:retry,
        retry_limit:retryLimit,elapsed_ms:Date.now()-started,upstream_usage:'unknown'}});
      const code=ownTimeout ? 'recovery_attempt_timeout' : activeTransport.causes.find(c=>c.code)?.code || 'unclassified';
      const reason=activeTransport.stage+': '+code+' — '+redactError(error.message || error).slice(0,256);
      lastFailure=reason;
      if(retryIndex>0) await retryEvent('failed',reason);
      if(!retry) {
        if(retryIndex>0) await retryEvent(knownTransient ? 'exhausted' : 'suppressed',reason);
        throw Error('subscription_stream_failure: stage='+activeTransport.stage+' cause='+code
          +' attempt='+attempt+' model_output_seen='+activeTransport.model_output_seen+'; '+redactError(error.message || error));
      }
      // Pi may finalize a thinking block without a delta, and normalizes failed
      // results after deleting scratch fields. Preserve that final known snapshot.
      const retained=knownBlocks(answer?.content)?answer.content:lastPartialContent;
      for(const [index,block] of (retained || []).entries()) {
        if(block.type==='thinking')attemptThoughts.set(index,block.thinking);
        else if(block.type==='text') {
          const id=`${attemptTag}:${index}`,item=attemptTexts.get(id)||{pending_id:id,phase:''};
          item.text=block.text;attemptTexts.set(id,item);
        }
      }
      // Freeze the abandoned previews BEFORE another attempt. Durable retry rows
      // retain full text/reasoning plus bounded tool previews; operation evidence
      // retains the original bridge output. Never commit an abandoned tool call.
      if(activeTransport.model_output_seen)await retryEvent('interrupted',reason,{index:Math.max(1,retryIndex),
        discarded_attempt:{id:attemptTag,attempt,reasoning:[...attemptThoughts.values()].join('\n\n'),texts:[...attemptTexts.values()],
          decisions:[...attemptDecisions.values()],tools_executed:0}});
      if(nextCycle) {
        await restartCycle(reason);
        recoveryDeadline=Math.min(deadline,recoveryStarted+recoveryWindow);
      }
      retryIndex++;
      const target=recoveryStarted+initialWait+(retryIndex-1)*interval;
      const waitMs=Math.max(0,Math.min(target-Date.now(),recoveryDeadline-Date.now()));
      await retryEvent('waiting',reason,{wait_ms:waitMs});
      await send({type:'transport_retry',attempt,index:retryIndex,cycle,limit:retryLimit,wait_ms:waitMs,
        note:activeTransport.model_output_seen ? 'Regenerating uncommitted response; prior output preserved as interrupted; upstream usage unknown; no tools replayed'
          : 'Retrying inference before model output; prior upstream usage unknown; no tools replayed'});
      if(waitMs>0) await new Promise(resolve=>setTimeout(resolve,waitMs));
      if(Date.now()>=recoveryDeadline) {
        await restartCycle(reason);retryIndex=1;
        await retryEvent('waiting',reason,{wait_ms:0});
      }
    }
  }
  const usage = answer.usage;
  const textMessages = answer.content
    .map((p, index) => ({p, index}))
    .filter(item => item.p.type === 'text')
    .map(({p, index}) => {
      let phase = '';
      try {
        const value = JSON.parse(p.textSignature || '{}').phase;
        if (value === 'commentary' || value === 'final_answer') phase = value;
      } catch {}
      return {phase, content:p.text, pending_id:`${attemptTag}:${index}`};
    });
  const finalMessages = textMessages.filter(message => message.phase !== 'commentary');
  const finalPhase = finalMessages.length ? finalMessages[finalMessages.length - 1].phase : '';
  send({type:'result', result:{
    content:finalMessages.map(p => p.content).join(''),
    commentary:textMessages.filter(message => message.phase === 'commentary')
      .map(p => ({content:p.content, pending_id:p.pending_id})),
    final_phase:finalPhase,
    reasoning:answer.content.filter(p => p.type === 'thinking').map(p => p.thinking).join(''),
    tool_calls:answer.content.filter(p => p.type === 'toolCall').map(p => ({id:p.id,
      type:'function', function:{name:p.name, arguments:JSON.stringify(p.arguments)}})),
    finish_reason:answer.stopReason === 'length' ? 'length' : answer.stopReason === 'toolUse' ? 'tool_calls' : 'stop',
    stream_complete:true, model:model.id, request_id:answer.responseId, ttft_ms:ttft,
    usage:{prompt_tokens:usage.input + usage.cacheRead + usage.cacheWrite,
      completion_tokens:usage.output, total_tokens:usage.totalTokens,
      prompt_tokens_details:{cached_tokens:usage.cacheRead},
      completion_tokens_details:{reasoning_tokens:usage.reasoning}}}});
} catch (error) {
  // Provider errors can contain bearer tokens. Never print unfiltered diagnostics.
  const message = redactError(error?.message || error);
  await send({type:'error', error:message,diagnostic:activeTransport});
  process.exitCode = 1;
}
}
main();
]==]
