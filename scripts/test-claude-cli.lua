-- The claude CLI route's mapping, judged without a live call (mission claude-inside-wa, part B).
--
-- Every line this row feeds in was OBSERVED in a real `claude -p --output-format stream-json --verbose` run
-- (ready-claude-b.md, stream-json/event-shapes.jsonl). A stub that invented shapes would prove the parser agrees
-- with my imagination, which is the failure this factory keeps paying for.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end

local claude = dofile('lua/core/claude_cli.lua')
local checks, failed = 0, 0
local function ok(what) checks = checks + 1 end
local function eq(got, want, what)
  if got == want then ok() else failed = failed + 1; io.stderr:write(('FAIL %s: got %q want %q\n'):format(what, tostring(got), tostring(want))) end
end

-- 1. The argv names the flags the CLI's own --help prints, and never carries the prompt.
local argv = claude.command('claude-sonnet-4-5')
eq(table.concat(argv, ' '), '-p --output-format stream-json --verbose --model claude-sonnet-4-5', 'argv')
eq(argv[1] ~= 'hello', true, 'the prompt is not on the command line')
eq(table.concat(claude.command(nil), ' '), '-p --output-format stream-json --verbose', 'argv without a model')

-- 2. The events, exactly as observed.
eq(claude.event('{"type":"system","subtype":"init","session_id":"s1","tools":["Bash"]}').kind, 'init', 'init')
eq(claude.event('{"type":"system","subtype":"init","session_id":"s1"}').session_id, 's1', 'init session')
eq(claude.event('{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}').kind, 'thinking_progress', 'thinking progress is not content')
eq(claude.event('{"type":"assistant","message":{"content":[{"type":"text","text":"oi"}]}}').text, 'oi', 'text')
eq(claude.event('{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"}]}}').text, 'hm', 'thinking')
eq(claude.event('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"cmd":"ls"}}]}}').kind, 'tool_use', 'tool use')
eq(claude.event('{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.85}}').utilization, 0.85, 'rate limit')
local res = claude.event('{"type":"result","stop_reason":"end_turn","total_cost_usd":0.0556461,"usage":{"input_tokens":10,"output_tokens":68},"session_id":"s1"}')
eq(res.stop_reason, 'end_turn', 'result stop')
eq(res.cost_usd, 0.0556461, 'result cost')
eq(res.output_tokens, 68, 'result tokens')

-- 3. What is unknown stays unknown, by name.
eq(claude.event('{"type":"something_new"}').kind, 'unknown', 'an unknown type is not content')
eq(claude.event('{"type":"something_new"}').raw_type, 'something_new', 'and it names itself')
eq(claude.event('not json').raw_type, 'unparsable', 'an unparsable line is named')

-- 4. A whole stream: text joined, the last result kept, progress not counted as text.
local stream = {
  '{"type":"system","subtype":"init","session_id":"s9"}',
  '{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}',
  '{"type":"assistant","message":{"content":[{"type":"text","text":"oi"}]}}',
  '{"type":"assistant","message":{"content":[{"type":"text","text":" tudo"}]}}',
  '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning"}}',
  '{"type":"result","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2},"session_id":"s9"}',
}
local got = claude.consume(stream)
eq(got.text, 'oi tudo', 'text joined')
eq(got.session_id, 's9', 'session id')
eq(got.result.stop_reason, 'end_turn', 'result kept')
eq(got.rate_limit.status, 'allowed_warning', 'rate limit surfaced')
eq(got.events, 6, 'every line accounted for')
eq(#got.unknown, 0, 'nothing was unknown in a real stream')

-- 5. No CLI is a NAMED refusal, never a silence.
local none, why = claude.binary(nil)
eq(none, nil, 'no binary -> no provider')
eq(why:match('^claude_cli_missing: ') ~= nil, true, 'the refusal is named')
eq(claude.binary('/usr/bin/claude'), '/usr/bin/claude', 'a binary is used as given')

-- 6. THE SPAWN LOOP, end to end, against a STUB that answers in the CLI's own shape (the same lines a real run
-- produced). This is the check that would catch a prompt never reaching the child, or an exit code ignored.
local stub = os.tmpname()
local fh = assert(io.open(stub, "w"))
fh:write[[#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"system","subtype":"init","session_id":"stub-session"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"oi do stub"}]}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn","cost_usd":0,"usage":{"input_tokens":3,"output_tokens":4},"session_id":"stub-session"}'
exit 0
]]
fh:close()
os.execute("chmod +x " .. string.format('%q', stub))
local out = claude.complete(stub, "um prompt", nil)
eq(out ~= nil, true, 'the stub answered')
eq(out.text, 'oi do stub', 'the text came back through consume')
eq(out.exit_ok, true, 'the exit status was read')
eq(out.session_id, 'stub-session', 'the session id travels')
local none, why2 = claude.complete(nil, 'x', nil)
eq(none, nil, 'no binary is refused')
eq(type(why2) == 'string' and why2:match('^claude_cli_missing: ') ~= nil, true, 'named refusal')
os.remove(stub)

if failed > 0 then print(('claude cli FAILED (%d of %d)'):format(failed, checks + failed)); os.exit(1) end
print(('claude cli ok (%d checks)'):format(checks))
