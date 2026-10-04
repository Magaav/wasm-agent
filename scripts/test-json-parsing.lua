local json = dofile('lua/vendor/json.lua')
local checks = 0
local function check(ok, label)
  assert(ok, label)
  checks = checks + 1
end

local cases = {
  {'""', ''}, {'"plain text"', 'plain text'},
  {'"\\\"\\\\\\/\\b\\f\\n\\r\\t"', '"\\/\b\f\n\r\t'},
  {'"prefix\\nmiddle\\tend"', 'prefix\nmiddle\tend'},
  {'"\\u0000"', '\0'}, {'"\\u0041"', 'A'},
  {'"\\u00e9"', '\195\169'}, {'"\\u20ac"', '\226\130\172'},
  {'"\\uD83D\\uDE00"', '\240\159\152\128'},
}
for _, case in ipairs(cases) do check(json.decode(case[1]) == case[2], 'escape decoding') end
for _, raw in ipairs({'"unfinished', '"bad\\x"', '"bad\\u00xz"', '"raw\nnewline"', '"raw\0nul"'}) do
  check(not pcall(json.decode, raw), 'malformed strings must still fail')
end
local nested = json.decode('{"escaped\\nkey":["one\\ttwo",{"x":"\\u20ac"}],"n":-1.25e2,"b":true}')
check(nested['escaped\nkey'][1] == 'one\ttwo' and nested['escaped\nkey'][2].x == '\226\130\172' and nested.n == -125 and nested.b == true, 'nested JSON values')

-- This reproduces the SQL envelope: the trace is itself JSON, stored as an
-- escaped string inside the host's JSON result. The old parser spends minutes
-- repeatedly copying it. A generous CPU budget bounds a failing regression.
local text = string.rep('a\\b\nc"d', 250000)
local trace = json.encode({{request={messages={{role='user',content=text}}}}})
local envelope = json.encode({{trace=trace}})
local started = os.clock()
debug.sethook(function()
  if os.clock() - started > 5 then error('JSON decode exceeded 5 CPU seconds') end
end, '', 10000)
local ok, decoded = pcall(json.decode, envelope)
local seconds = os.clock() - started
debug.sethook()
check(ok, tostring(decoded))
check(decoded[1].trace == trace, 'large SQL envelope preserves the full trace')
local inner = json.decode(decoded[1].trace)
check(inner[1].request.messages[1].content == text, 'large nested trace preserves content')
print(json.encode({checks=checks,skipped=0,bytes=#envelope,cpu_seconds=seconds,
  source=LOADED_SOURCES['lua/vendor/json.lua']}))
