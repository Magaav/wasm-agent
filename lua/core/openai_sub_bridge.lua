-- Pi owns OAuth refresh, locking and the subscription wire protocol. This helper
-- never returns credentials to Lua or puts them in a command line.
return [==[
import { readFileSync, unlinkSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const send = value => new Promise(resolve => process.stdout.write(JSON.stringify(value) + '\n', resolve));
async function main() {
let request;
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
      const key = Number.isFinite(duration) ? (duration >= 172800 ? 'weekly' : 'rolling') : fallback;
      limits[key] = {status:window.limit_reached ? 'limited' : 'available',
        percent:Number(window.used_percent),
        resetsAt:Number.isFinite(Number(window.reset_at))
          ? new Date(Number(window.reset_at)*1000).toISOString() : null};
    };
    addWindow(root.primary_window || root.primary || root.five_hour, 'rolling');
    addWindow(root.secondary_window || root.secondary || root.weekly, 'weekly');
    await send({type:'limits', limits});
    return;
  }
  const model = models.getModel('openai-codex', request.model);
  if (!model) throw new Error('Model is absent from Pi catalog; update Pi: ' + request.model);
  const zeroUsage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0,
    cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };
  const textParts = content => {
    if (typeof content === 'string') return [{type:'text', text:content}];
    return (content || []).map(part => {
      if (part.type === 'text') return {type:'text', text:part.text};
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
      const content = message.content ? textParts(message.content) : [];
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
  const stream = models.stream(model, context, {sessionId:request.session_id,
    transport:'sse', reasoningEffort:request.reasoning, maxTokens:request.max_output});
  for await (const event of stream) {
    if (event.type === 'text_delta' || event.type === 'thinking_delta') {
      ttft ??= Date.now() - started;
      send({type:event.type === 'text_delta' ? 'delta' : 'reasoning', text:event.delta});
    }
  }
  const answer = await stream.result();
  if (answer.stopReason === 'error' || answer.stopReason === 'aborted') {
    throw new Error(answer.errorMessage || answer.stopReason);
  }
  const usage = answer.usage;
  send({type:'result', result:{
    content:answer.content.filter(p => p.type === 'text').map(p => p.text).join(''),
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
  const message = String(error?.message || error)
    .replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '<redacted>')
    .replace(/Bearer\s+\S+/gi, 'Bearer <redacted>')
    .replace(/sk-[\w-]+/g, '<redacted>');
  send({type:'error', error:message});
  process.exitCode = 1;
}
}
main();
]==]
