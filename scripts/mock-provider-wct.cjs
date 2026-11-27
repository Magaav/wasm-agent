// The stub model for waiting-costs-no-turns: ONE tool call for a long job, then a plain answer.
//
//   node scripts/mock-provider-wct.cjs <port> [job-seconds]
//
// Why a second stub rather than a mode on mock-provider-a24.cjs: that file is the serve smoke's contract
// (three turns, a wake, a subagent) and its answers are asserted by that row. This one answers exactly one
// shape - `run` a script that starts a job and ends with the handle live - so `GET /calls` counts the
// model round trips for that one shape and nothing else.
//
// The row it serves (scripts/test-wct-serve-step.sh): a job of N seconds must cost ONE tool round. Before
// the change the node answered the script with a pending handle and the model had to ask again; the count
// is what tells the two apart.
const http = require('node:http');

const port = Number(process.argv[2]);
const jobSeconds = Number(process.argv[3] || process.env.WCT_JOB_SECONDS || 6);
const state = { count: 0, tool_rounds: 0, prompts: [], answered: [], request_bytes: 0, request_bytes_each: [] };

const usage = { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11, prompt_tokens_details: { cached_tokens: 0 } };

/// The last user message, as text.
function lastUserText(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message && message.role === 'user') {
      const content = message.content;
      if (typeof content === 'string') return content;
      if (Array.isArray(content)) return content.map((part) => (part && part.text) || '').join(' ');
    }
  }
  return '';
}

/// The text of the newest tool result, so the final answer carries what the model was actually told.
function lastToolText(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message && message.role === 'tool') {
      const content = message.content;
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

/// The one script: start a job that speaks once and then keeps working, and END with the handle live.
/// `wait_s: 0` is what makes it a handle; the harness's hold is what decides how long the answer waits.
const script = [
  `const h = await tools.bash({command:'sleep ${jobSeconds}; echo wct-step-done', wait_s: 0});`,
  "text('started: ' + String(h.state || '?'));",
  'return h;',
].join('\n');

function answer(res, body) {
  state.count += 1;
  const size = Buffer.byteLength(JSON.stringify(body));
  state.request_bytes += size;
  state.request_bytes_each.push(size);
  state.prompts.push(lastUserText(body).slice(0, 200));
  const wantsJob = !alreadyUsedTools(body);
  let message;
  if (wantsJob) {
    state.tool_rounds += 1;
    message = {
      role: 'assistant',
      content: null,
      tool_calls: [
        {
          id: 'call-run-1',
          type: 'function',
          // The code-mode tool is `run`, and the script is its `code` argument.
          function: { name: 'run', arguments: JSON.stringify({ code: script }) },
        },
      ],
    };
  } else {
    // What the model was told, echoed back: the row asserts the settled output arrived in the ONE result.
    const seen = lastToolText(body);
    state.answered.push(seen.slice(0, 400));
    // A VERDICT, not a quote: the note rides in the tool result as either header lines or JSON, and a
    // truncated echo would hide it (measured: the first 600 bytes named calls/full_result/items and the
    // settled record began past them). The row asks one question - did the settled output reach the model
    // in this one result - so the stub answers that question and nothing else.
    const settled = seen.includes('wct-step-done');
    // WHAT A MODEL DOES WHEN THE ANSWER IS A HANDLE, measured rather than assumed (the before/after row):
    // it asks again. With WCT_POLL=1 the stub keeps asking - one `wait(op)` tool round per ask - until the
    // job's output appears, so the call count IS the number of round trips the model spends waiting. The
    // after run needs no policy of its own: the settled output is already in the first result, so this
    // branch is never reached.
    const opMatch = /op-\d+-\d+-\d+/.exec(seen);
    if (!settled && process.env.WCT_POLL === '1' && opMatch) {
      state.tool_rounds += 1;
      const pollScript = `const r = await wait('${opMatch[0]}'); text('polled'); return r;`;
      state.answered.push('poll:' + opMatch[0]);
      const pollMessage = {
        role: 'assistant',
        content: null,
        tool_calls: [
          {
            id: 'call-run-' + (state.tool_rounds + 1),
            type: 'function',
            function: { name: 'run', arguments: JSON.stringify({ code: pollScript }) },
          },
        ],
      };
      respond(res, body, pollMessage, true);
      return;
    }
    const pending = seen.includes('pending_settled') || seen.includes('pending: settled');
    message = {
      role: 'assistant',
      content:
        'settled-output:' + (settled ? 'present' : 'missing') +
        ' pending-note:' + (pending ? 'present' : 'missing') +
        ' bytes:' + seen.length,
    };
  }
  respond(res, body, message, wantsJob);
}

/// One answer, streaming or not: `wantsJob` decides the finish reason, `message` is what the model says.
function respond(res, body, message, wantsToolCall) {
  const wantsJob = wantsToolCall;
  if (body.stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    if (wantsJob) {
      res.write(
        'data: ' + JSON.stringify({
          id: 'stub-wct',
          choices: [{
            delta: {
              tool_calls: [{ index: 0, id: 'call-run-1', type: 'function', function: { name: 'run', arguments: message.tool_calls[0].function.arguments } }],
            },
            finish_reason: null,
          }],
          usage,
        }) + '\n\n',
      );
      res.end('data: ' + JSON.stringify({ id: 'stub-wct', choices: [{ delta: {}, finish_reason: 'tool_calls' }] }) + '\n\ndata: [DONE]\n\n');
      return;
    }
    res.write('data: ' + JSON.stringify({ id: 'stub-wct', choices: [{ delta: { content: message.content }, finish_reason: null }], usage }) + '\n\n');
    res.end('data: ' + JSON.stringify({ id: 'stub-wct', choices: [{ delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n');
    return;
  }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ id: 'stub-wct', model: 'stub-model', choices: [{ message, finish_reason: wantsJob ? 'tool_calls' : 'stop' }], usage }));
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/calls') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(state));
    return;
  }
  if (req.method === 'GET') {
    res.writeHead(200, { 'content-type': 'text/plain' });
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
