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
function observedFetch(state) {
  const fetchImpl=globalThis.fetch.bind(globalThis);
  return async (url,options) => {
    state.fetch_observed=true;state.stage='response_headers';
    let response;
    try {response=await fetchImpl(url,options);} catch(error) {state.causes=causeChain(error);state.cancelled=options?.signal?.aborted===true;throw error;}
    state.http_status=response.status;
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
  const partialToolCall = event => event.partial?.content?.[event.contentIndex] || {};
  // Decisions are display telemetry; the result below carries exact arguments for execution.
  // Never re-emit the growing argument prefix on every token (quadratic wire output).
  const publishDecision = (decision, complete, previousId) => send({type:'decision',
    call_id:decision.id, ...(previousId && previousId !== decision.id ? {previous_call_id:previousId} : {}),
    name:decision.name, arguments_text:(decision.preview || '') +
      (decision.truncated ? '… [preview only; complete arguments in result]' : ''), complete,
    ...(decision.truncated ? {arguments_truncated:true} : {})});
  const retryLimit=request.transport_retries ?? 1;
  if(!Number.isInteger(retryLimit) || retryLimit<0 || retryLimit>1) throw Error('invalid_subscription_transport_retries');
  const timeoutMs=request.timeout_ms ?? 3600000;
  if(!Number.isInteger(timeoutMs) || timeoutMs<1 || timeoutMs>86400000) throw Error('invalid_subscription_timeout');
  const deadline=Date.now()+timeoutMs;
  let answer;
  for(let attempt=1;;attempt++) {
    activeTransport={schema_version:1,attempt,stage:'adapter',fetch_observed:false,response_bytes:0,
      body_eof:false,model_output_seen:false,causes:[]};
    try {
      const stream = models.stream(model, context, {sessionId:request.session_id,
        transport:'sse', reasoningEffort:request.reasoning, maxTokens:request.max_output,
        maxRetries:0,fetch:observedFetch(activeTransport)});
      for await (const event of stream) {
        // Unknown/new progress events are conservative: never replay across a
        // provider-version change merely because the bridge cannot display them.
        if(!['start','error','done'].includes(event.type)) activeTransport.model_output_seen=true;
    if (event.type === 'text_delta' || event.type === 'thinking_delta') {
      ttft ??= Date.now() - started;
      // A response-global mutable stopReason is not a per-item phase.
      if (event.type === 'text_delta') {
        send({type:'pending_delta', pending_id:`${request.stream_id || 'stream'}:${event.contentIndex}`, text:event.delta});
      } else if (event.type === 'thinking_delta') {
        reasoningText += event.delta;
        send({type:'reasoning', text:event.delta, chars:[...reasoningText].length});
      }
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
      const pendingId = `${request.stream_id || 'stream'}:${event.contentIndex}`;
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
        if((answer.content || []).length) activeTransport.model_output_seen=true;
        throw new Error(answer.errorMessage || answer.stopReason);
      }
      if(activeTransport.fetch_observed || attempt>1)
        await send({type:'transport_attempt',diagnostic:{...activeTransport,ok:true,elapsed_ms:Date.now()-started}});
      break;
    } catch(error) {
      if(!activeTransport.causes.length) activeTransport.causes=causeChain(error);
      const status=activeTransport.http_status;
      const aborted=activeTransport.cancelled===true || answer?.stopReason==='aborted'
        || activeTransport.causes.some(c=>['AbortError','TimeoutError'].includes(c.name));
      const knownTransient=!aborted && activeTransport.fetch_observed && activeTransport.causes.some(c=>transientCodes.has(c.code))
        && (status===undefined || status===200) && !activeTransport.model_output_seen;
      const retry=knownTransient && attempt<=retryLimit && Date.now()+1000<deadline;
      await send({type:'transport_attempt',diagnostic:{...activeTransport,ok:false,retry_scheduled:retry,
        retry_limit:retryLimit,elapsed_ms:Date.now()-started,upstream_usage:'unknown'}});
      if(!retry) {
        const code=activeTransport.causes.find(c=>c.code)?.code || 'unclassified';
        throw Error('subscription_stream_failure: stage='+activeTransport.stage+' cause='+code
          +' attempt='+attempt+' model_output_seen='+activeTransport.model_output_seen+'; '+redactError(error.message || error));
      }
      await send({type:'transport_retry',attempt,limit:retryLimit,wait_ms:1000,
        note:'Retrying inference before model output; prior upstream usage unknown; no tools replayed'});
      await new Promise(resolve=>setTimeout(resolve,1000));
      if(Date.now()>=deadline) throw Error('subscription_retry_deadline_exhausted');
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
      return {phase, content:p.text, pending_id:`${request.stream_id || 'stream'}:${index}`};
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
