// Local stub model for the "a line typed during a run" rows (scripts/test-cli-queued.sh).
//
// The action is the `run` TOOL CALL - one path since change/one-run-path (Victor 21/11): the fenced
// run block and WASM_AGENT_RAW_CODE are gone, so a fixture that sends `codemode` would be refused by
// name on this main and measure nothing.
//
// OpenAI-shaped, no upstream, no credential. It answers `stub-quiet` to anything, except that a user
// message asking it to RUN THE SCRIPT (and a conversation that has not used a tool yet) answers one
// `codemode` tool call whose code runs two bash commands, the first of which sleeps:
//
//   * every planned call executed  -> WA_QUEUED_MARKER gains two lines;
//   * a wait that was cut by the reader's Ctrl+Enter -> the second one never runs, so it has one.
//
//   node scripts/mock-provider-queued.cjs <port>     (GET /calls answers {count, prompts})
const http = require('node:http');
const port = Number(process.argv[2]);
const marker = process.env.WA_QUEUED_MARKER || '/tmp/wa-queued-marker.txt';
const state = { count: 0, prompts: [] };

function lastUserText(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index] && messages[index].role === 'user') {
      const content = messages[index].content;
      if (typeof content === 'string') return content;
      if (Array.isArray(content)) return content.map((part) => (part && part.text) || '').join(' ');
    }
  }
  return '';
}

function alreadyUsedTools(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  return messages.some((message) => message && (message.role === 'tool' || (message.tool_calls && message.tool_calls.length)));
}

const usage = { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11, prompt_tokens_details: { cached_tokens: 0 } };

function scriptCode() {
  return (
    "await tools.bash({command: 'sleep 6; echo one >> " + marker + "'});\n" +
    "await tools.bash({command: 'echo two >> " + marker + "'});\n" +
    'return {done: true};'
  );
}

function answer(res, body) {
  state.count += 1;
  const prompt = lastUserText(body);
  state.prompts.push(prompt.slice(0, 400));
  const wantsScript = /run the script/i.test(prompt) && !alreadyUsedTools(body);
  const message = wantsScript
    ? {
        role: 'assistant',
        content: null,
        tool_calls: [
          {
            id: 'call-script-1',
            type: 'function',
            function: { name: 'run', arguments: JSON.stringify({ code: scriptCode() }) },
          },
        ],
      }
    : { role: 'assistant', content: 'stub-quiet' };
  if (body.stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (wantsScript) {
      res.write(
        'data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: { tool_calls: [{ index: 0, id: 'call-script-1', type: 'function', function: { name: 'run', arguments: message.tool_calls[0].function.arguments } }] }, finish_reason: null }], usage }) + '\n\n',
      );
      res.end('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: {}, finish_reason: 'tool_calls' }] }) + '\n\ndata: [DONE]\n\n');
      return;
    }
    res.write('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: { content: 'stub-quiet' }, finish_reason: null }], usage }) + '\n\n');
    res.end('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n');
    return;
  }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ id: 'stub', model: 'stub-model', choices: [{ message, finish_reason: wantsScript ? 'tool_calls' : 'stop' }], usage }));
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/calls') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(state));
    return;
  }
  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch { body = {}; }
    answer(res, body);
  });
});
server.listen(port, '127.0.0.1');
