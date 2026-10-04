const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const [repo, tip, bin, baselineRef = tip + '^'] = process.argv.slice(2);
assert.ok(repo && tip && bin, 'usage: node reviews/json-parsing-attack.cjs <repo> <tip> <binary> [baseline-ref]');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-json-review-'));
const git = (...args) => {
  const r = spawnSync('git', ['-C', repo, ...args], {windowsHide:true});
  assert.equal(r.status, 0, String(r.stderr)); return r.stdout;
};
const candidate = git('show', tip + ':lua/vendor/json.lua');
const baseline = git('show', baselineRef + ':lua/vendor/json.lua');
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
try {
  fs.writeFileSync(path.join(tmp, 'candidate.lua'), candidate);
  fs.writeFileSync(path.join(tmp, 'baseline.lua'), baseline);
  const lua = String.raw`
local candidate_source = assert(host.read_file(args[1]))
local baseline_source = assert(host.read_file(args[2]))
local new = assert(load(candidate_source, '@candidate'))()
local old = assert(load(baseline_source, '@baseline'))()
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function fingerprint(value)
  if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
  local items = {}
  for k,v in pairs(value) do items[#items+1] = fingerprint(k) .. '=' .. fingerprint(v) end
  table.sort(items)
  return 'table:{' .. table.concat(items,';') .. '}'
end
local function outcome(parser, raw)
  local ok, value = pcall(parser.decode, raw)
  if ok then return 'ok:' .. fingerprint(value) end
  return 'error:' .. tostring(value):gsub('^.-:%d+: ', '')
end
local corpus = {'null','true','false','0','-1.25e2','[]','{}','[true,false,null,1,"x"]',
  '{"0":0,"s":"","a":[true,false],"n":null}',
  '"\\uD800"','"\\uDC00"','"\\uD800\\u0000"','"\\uDFFF\\uFFFF"',
  '"\\uFFFF"','"\\uDBFF\\uDFFF"','"\\ud800\\udc00"',
  '"\\u000"','"\\u000g"','"\\uD800\\u"','"abc\\"','"abc\\x"','"abc',
  '"\\\\"','"\\\""','"\\/"','"\\b\\f\\n\\r\\t"','""','"raw\0nul"',
  '"raw\1control"','"raw\31control"','"raw\nnewline"','"x"garbage'}
for _, raw in ipairs(corpus) do check(outcome(new,raw) == outcome(old,raw), 'corpus parity: '..raw) end
math.randomseed(424242)
for i = 1, 2000 do
  local parts = {}
  for j = 1, math.random(0,64) do parts[j] = string.char(math.random(0,255)) end
  local value = table.concat(parts)
  local encoded = old.encode(value)
  check(new.decode(encoded) == value and old.decode(encoded) == value, 'byte roundtrip')
  local cut = encoded:sub(1,math.random(1,#encoded))
  check(outcome(new,cut) == outcome(old,cut), 'truncated parity')
end
local timings = {}
for _, count in ipairs({62500,125000,250000}) do
  local value = string.rep('a\\b\nc"d', count)
  local trace = new.encode({{request={messages={{role='user',content=value}}}}})
  local envelope = new.encode({{trace=trace}})
  local started = os.clock()
  local outer = new.decode(envelope)
  local inner = new.decode(outer[1].trace)
  local seconds = os.clock()-started
  check(outer[1].trace == trace and inner[1].request.messages[1].content == value, 'large exact roundtrip')
  check(seconds < 5, 'large decode budget')
  timings[#timings+1] = {bytes=#envelope,cpu_seconds=seconds}
end
print(new.encode({checks=checks,skipped=0,source=host.sha256(candidate_source),baseline=host.sha256(baseline_source),timings=timings}))
`;
  fs.writeFileSync(path.join(tmp, 'attack.lua'), lua);
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(WASM_AGENT_|WA_|OPENAI_|ANTHROPIC_|OPENCODE_)/.test(key)));
  Object.assign(env, {WA_SCRIPT:path.join(tmp,'attack.lua'), WASM_AGENT_HOME:tmp, WASM_AGENT_MANAGED:'0', WASM_AGENT_RELAY:'', WASM_AGENT_RENDEZVOUS:''});
  const result = spawnSync(bin, ['--db', ':memory:', path.join(tmp,'candidate.lua'), path.join(tmp,'baseline.lua')], {cwd:repo, env, encoding:'utf8', timeout:30000, windowsHide:true});
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  const evidence = JSON.parse(result.stdout.trim());
  assert.equal(evidence.source,hash(candidate)); assert.equal(evidence.baseline,hash(baseline));
  console.log(JSON.stringify({...evidence,tested_tip:tip,baseline_ref:baselineRef,binary_sha256:hash(fs.readFileSync(bin))}));
} finally { fs.rmSync(tmp, {recursive:true,force:true}); }
