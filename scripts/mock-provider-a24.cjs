// Local stub model for the A2.4 serve smoke (docs/KERNEL.md, "A2.4"). OpenAI-shaped, no upstream,
// no credential: it answers `stub-ok` immediately, and when the *last user message* asks to be woken
// it answers with a `wake` tool call instead, which is how the smoke exercises the self-loop.
//
//   node scripts/mock-provider-a24.cjs <port>
//
// GET /calls answers `{"count":N,"prompts":[...],"self_wakes":M}` so the harness can see that a
// [self-wake] turn really reached the model without the harness prompting again.
const http = require('node:http');
const port = Number(process.argv[2]);
const state = { count: 0, prompts: [], self_wakes: 0 };

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

/// True once the conversation already carries a tool result or a tool call: the stub asks for `wake`
/// exactly once per turn, so the agent's next round gets a plain answer instead of the same call again.
function alreadyUsedTools(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  return messages.some((message) => message && (message.role === 'tool' || (message.tool_calls && message.tool_calls.length)));
}

const usage = { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11, prompt_tokens_details: { cached_tokens: 0 } };

function answer(res, body) {
  state.count += 1;
  const prompt = lastUserText(body);
  state.prompts.push(prompt.slice(0, 400));
  if (/\[self-wake/.test(prompt)) state.self_wakes += 1;
  const wantsWake = /wake me/i.test(prompt) && !/\[self-wake/.test(prompt) && !alreadyUsedTools(body);
  const message = wantsWake
    ? {
        role: 'assistant',
        content: null,
        tool_calls: [
          {
            id: 'call-wake-1',
            type: 'function',
            function: { name: 'wake', arguments: JSON.stringify({ in_seconds: 2, reason: 'smoke' }) },
          },
        ],
      }
    : { role: 'assistant', content: 'stub-ok' };
  if (body.stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (wantsWake) {
      // The tool call as one delta, the way a provider streams it.
      res.write(
        'data: ' +
          JSON.stringify({
            id: 'stub',
            choices: [
              {
                delta: {
                  tool_calls: [
                    { index: 0, id: 'call-wake-1', type: 'function', function: { name: 'wake', arguments: message.tool_calls[0].function.arguments } },
                  ],
                },
                finish_reason: null,
              },
            ],
            usage,
          }) +
          '\n\n',
      );
      res.end('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: {}, finish_reason: 'tool_calls' }] }) + '\n\ndata: [DONE]\n\n');
      return;
    }
    res.write('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: { content: 'stub-ok' }, finish_reason: null }], usage }) + '\n\n');
    res.end('data: ' + JSON.stringify({ id: 'stub', choices: [{ delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n');
    return;
  }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ id: 'stub', model: 'stub-model', choices: [{ message, finish_reason: wantsWake ? 'tool_calls' : 'stop' }], usage }));
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/calls') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(state));
    return;
  }
  if (req.method === 'GET') {
    res.end('ready');
    return;
  }
  let body = '';
  req.on('data', (chunk) => (body += chunk));
  req.on('end', () => {
    let parsed = {};
    try {
      parsed = JSON.parse(body);
    } catch (error) {
      parsed = {};
    }
    answer(res, parsed);
  });
});
server.listen(port, '127.0.0.1');
