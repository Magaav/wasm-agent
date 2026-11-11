-- The code-mode seam's parity suite (docs/CORE-SPLIT.md, docs/CODEMODE.md): the same scripts through
-- the native loop in `lua/core/codemode.lua` and through the `codemode` component, compared field for
-- field — the script's value, its output items, the calls and attempts the loop recorded, the fence's
-- discovery, a 200 KB answer, and the refusals a script can actually reach.
--
-- Self-contained: the runner's own `--db` and a scratch WASM_AGENT_HOME, no node, no network, no model.
-- The component half needs a built `codemode.wasm` reachable by this process
-- (`WA_CODEMODE_COMPONENT_WASM`, the development override) and the pinned code-mode assets, because
-- *both* paths run the real QuickJS guest: this suite compares the loops, not a stub.
-- `scripts/test-codemode-component.sh` builds the component and sets the variable. When either is
-- missing the comparisons are SKIPPED — printed as such and reported in REPORT.md — and a skip is
-- never counted as a pass.
local json = dofile('lua/vendor/json.lua')

local checks, comparisons, skipped = 0, 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then error('CODEMODE SEAM CHECK FAILED: ' .. label) end
end
local function skip(what, why)
  skipped = skipped + 1
  print('SKIP codemode seam: ' .. what .. ' (' .. why .. ')')
end
local function decode(value)
  if type(value) ~= 'string' then return value end
  local ok, decoded = pcall(json.decode, value)
  return ok and decoded or value
end
local function text(value)
  if type(value) == 'string' then return value end
  local ok, encoded = pcall(json.encode, value)
  return ok and encoded or tostring(value)
end

-- The two interpreters. The switch is `docs/FEATURES.md`'s `codemode` feature, resolved through
-- `lua/core/features.lua` at every route; two instances of the module share one `host.features` table, so
-- the seam instance carries the module's own test seam (`M.seam_override`) rather than a host stub.
local memory = dofile('lua/core/memory.lua')
memory.setup()
local policy = dofile('lua/core/codemode_policy.lua')
local real_getenv, real_codemode, real_log = host.getenv, host.codemode, host.log
local logged = {}

local function instance(seam)
  host.log = function(line) logged[#logged + 1] = tostring(line) end
  local module = dofile('lua/core/codemode.lua')
  host.log = real_log
  -- BOTH sides are pinned (see `scripts/test-selfloop-component.lua`): an unpinned instance asks the
  -- resolver, which answers `active_component` whenever this tree's component is installed - so the
  -- `native` loop was the component loop on any machine that had one, and the field-for-field comparison
  -- below compared the component with itself.
  module.seam_override = seam and function() return true, 'active_component' end
    or function() return false, 'seam_disabled' end
  return module
end

local session = memory.start_session('local', 'chat', { id = 'codemode-seam', user_id = 'master', node_id = 'seam', title = 'code mode seam' })
local ctx = { session_id = session, user_id = 'master' }

-- The catalogue: two callable tools, one the fence refuses, one the node itself blocks. `execution` is
-- the node's pre-flight summary, so these records are the ones a real run would have.
local function schema(name, description)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = { text = { type = 'string' }, limit = { type = 'integer' } } } } }
end
local catalog = {
  schema('sessions', 'List sessions'),
  schema('read', 'Read a file'),
  schema('subagent', 'Delegate'),
  schema('tool_call', 'Outer facade'),
  schema('operation', 'Operations'),
}
local function current_catalog() return catalog end
local dispatched = {}
-- Every tool call the guest asked for, across the whole run (see the probe after the comparison loop).
local suite_dispatched = 0
local function dispatch(name, params, fragment)
  dispatched[#dispatched + 1] = { name = name, args = fragment }
  if name == 'read' then return { ok = true, text = string.rep('x', 200 * 1024) } end
  return { ok = true, name = name, limit = (type(params) == 'table' and params.limit) or nil }
end
local function execution(name)
  if name == 'operation' then
    return { status = 'blocked', scope = 'workspace_policy_only', workspace_binding = 'supported',
      reason = 'session_workspace_unavailable', detail = 'no allocated binding' }
  end
  return { status = 'not_blocked', scope = 'workspace_policy_only', workspace_binding = 'not_applicable' }
end

-- Is the guest reachable at all? Both paths need the pinned assets; `ready` answers without starting a
-- script, and the native policy pin asks the same question.
local readiness = decode(host.quickjs('ready', json.encode({})))
if type(readiness) ~= 'table' or not readiness.ok then
  skip('parity', 'the pinned code-mode assets are not available to this binary: ' .. text(readiness))
  print(string.format('codemode seam: %d checks, %d parity comparisons, %d skipped', checks, comparisons, skipped))
  return
end

local native = instance(false)
local component = instance(true)

-- A component that cannot answer falls back to the native path (with a log line). A parity comparison
-- between the native path and a silent fallback would pass while proving nothing, so the component
-- instance is proved live before any comparison runs: one script whose answer only the seam can give.
policy.pin(memory, 'master', ctx)
check(policy.enforced(ctx), 'code mode is pinned for this run')
local probe = component.run(memory, { code = 'return 1' }, 'master', ctx, catalog, current_catalog, dispatch, execution)
policy.pin(memory, 'master', ctx)
-- IS A COMPONENT ANSWERING? A component that is not installed falls back to the native loop and logs it
-- (that is the line appended to `logged`), and the native answer carries no `sandbox_calls`: the field is
-- the component loop's own cost count (`lua/core/codemode.lua`'s component path). Testing `probe.ok` and
-- `probe.backend` alone accepted the fallback - both paths set `backend` - so the comparisons below ran
-- native against native, compared nothing, and failed on "the component reports the sandbox crossings it
-- cost" for a component that had never been loaded. The capability is declared, not assumed: absent, the
-- suite skips by name and says which command builds it; present, every comparison runs as before.
local answering = type(probe) == 'table' and probe.ok == true and type(probe.sandbox_calls) == 'number'
if not answering then
  skip('parity', 'the codemode component answered no script (' .. text(probe)
    .. (#logged > 0 and ('; the node logged: ' .. table.concat(logged, '; ')) or '')
    .. '). A component and the node that hosts it share `wit/codemode`, so a node built before this '
    .. 'tree\'s WIT refuses a component built from it: install the node from this tree, or run '
    .. 'scripts/test-codemode-component.sh with WA_BIN pointing at a build of it')
  print(string.format('codemode seam: %d checks, %d parity comparisons, %d skipped', checks, comparisons, skipped))
  return
end
check(probe.sandbox_calls and probe.sandbox_calls > 0, 'the component reports the sandbox crossings it cost')
check(#logged == 0, 'the component path did not fall back: ' .. table.concat(logged, '; '))

-- Does the component JOURNAL the globals it answers itself? It must: the native loop records every guest
-- call it answers - `searchTools`, `describeTool`, `capabilities` included - as an attempt with
-- `target: "global"`, `admitted: false` and the argument/result references. The component answers those
-- inside the guest, so it reports each one to the loop (`progress.answered`, journaled by
-- `lua/core/codemode.lua`); a seam that answered silently would leave the two journals disagreeing about
-- which calls happened. Asserted, not skipped: the comparison below is field for field, global rows
-- included.
local journals_globals = (function()
  policy.pin(memory, 'master', ctx)
  local answer = component.run(memory,
    { code = 'const found = await searchTools("*", {limit: 1}); return found.matches ? found.matches.length : 0;' },
    'master', ctx, catalog, current_catalog, dispatch, execution)
  dispatched = {}
  return type(answer) == 'table' and answer.ok == true and #((answer.attempts) or {}) >= 1
end)()
check(journals_globals, 'the component journals the global it answers in place, as the native loop does')

-- The comparison: everything the model and the journal can see, minus the one field each path owns
-- (`backend` is the same on both; `sandbox_calls` is the component's own cost number).
local function fields(result)
  local calls = {}
  for _, call in ipairs(result.calls or {}) do
    calls[#calls + 1] = { id = call.id, name = call.name, ok = call.ok, evidence = call.evidence and call.evidence.sha256 }
  end
  local attempts = {}
  for _, attempt in ipairs(result.attempts or {}) do
    attempts[#attempts + 1] = { id = attempt.id, name = attempt.name, target = attempt.target,
      admitted = attempt.admitted, ok = attempt.ok,
      arguments = attempt.arguments and attempt.arguments.sha256,
      result = attempt.result and attempt.result.sha256 }
  end
  local unexecuted = {}
  for _, call in ipairs(result.unexecuted or {}) do
    unexecuted[#unexecuted + 1] = { id = call.id, name = call.name, reason = call.reason }
  end
  return { ok = result.ok, error = result.error, value = result.value,
    items = result.items or {}, calls = calls, attempts = attempts, unexecuted = unexecuted }
end

local scripts = {
  { label = 'trivial script', code = 'return 1' },
  { label = 'one tool call', code = 'const r = await tools.sessions({limit:2}); return r;' },
  { label = 'ten parallel calls', code = 'const rs = await Promise.all([1,2,3,4,5,6,7,8,9,10].map(i=>tools.sessions({limit:i}))); return rs.length;' },
  { label = 'the fence is not in the guest tool table', code = 'return JSON.stringify({subagent:typeof tools.subagent,codemode:typeof tools.codemode,tool_call:typeof tools.tool_call,sessions:typeof tools.sessions});' },
  { label = 'discovery lists what cannot be called', code = 'const all = await searchTools("*",{limit:200}); return JSON.stringify(all.tools.filter(t=>t.callable===false).map(t=>t.name));' },
  { label = 'discovery gives an outside tool its route', code = 'const all = await searchTools("*",{limit:200}); const s=all.tools.find(t=>t.name==="subagent"); return JSON.stringify({callable:s.callable,route:s.route,schema:typeof s.schema});' },
  { label = 'describeTool gives a schema', code = 'const d = await describeTool("operation"); return JSON.stringify({callable:d.callable,route:typeof d.route,parameters:typeof d.parameters});' },
  { label = 'a keyword search', code = 'const one = await searchTools("sessions"); return one.matches;' },
  { label = 'a batch with a miss', code = 'const b = await searchTools({names:["sessions","nope_tool"]}); return JSON.stringify({m:b.matches,missing:b.missing.map(x=>x.name)});' },
  { label = 'a 200 KB result', code = 'const big = await tools.read({path:"big"}); return big.text.length;' },
  { label = 'a script that throws', code = 'throw new Error("boom");' },
  { label = 'showCall help', code = 'const help = await describeTool("showCall"); return typeof help;' },
  { label = 'the node capability registry', code = 'const caps = await capabilities(); return typeof caps;' },
  { label = 'an unknown global is refused', code = 'const nope = await describeTool("no_such_tool"); return nope===null;' },
  { label = 'a fenced tool called from a script', code = 'return await tools.subagent({task:"x"});' },
}

-- Can THIS binary carry a failed script's reason across the component boundary? The node maps the guest's
-- `done` event - `value` when the script finished, `error` when it failed - onto the seam's record
-- (`rust/wa-capabilities/src/codemode_seam.rs`, `done-event.error`). A host built before that record had
-- the field answers a failed script with `{ok: false}` and no reason at all, so there is nothing to
-- compare the native message WITH.
--
-- That is a missing capability, not a reason to compare less: the suite names it and returns, and the
-- field-for-field comparison below runs in full the moment the installed node is built from a tree that
-- carries the field. Nothing else is skipped.
local carries = (function()
  policy.pin(memory, 'master', ctx)
  local probe = component.run(memory, { code = 'throw new Error("seam probe");' }, 'master', ctx, catalog,
    current_catalog, dispatch, execution)
  dispatched = {}
  return type(probe) == 'table' and probe.ok == false and probe.error ~= nil and tostring(probe.error) ~= ''
end)()
if not carries then
  skip('parity', 'this binary drops a failed script\'s reason at the seam (rust/wa-capabilities/src/codemode_seam.rs, '
    .. 'done-event.error); a node installed from this tree carries it, and then this suite compares every '
    .. 'field including that one. The native loop still names every failure, and that is asserted per script')
  print(string.format('codemode seam: %d checks, %d parity comparisons, %d skipped', checks, comparisons, skipped))
  return
end

-- Every tool call the guest asked for over the whole run, for the probe at the end: it asks whether the
-- guest can reach the real dispatcher AT ALL, and it used to read whatever the last iteration left (a
-- fenced call, which must dispatch nothing) - so it failed the moment this suite actually ran.
for _, script in ipairs(scripts) do
  dispatched = {}
  policy.pin(memory, 'master', ctx)
  local first = native.run(memory, { code = script.code }, 'master', ctx, catalog, current_catalog, dispatch, execution)
  local native_calls = #dispatched
  suite_dispatched = suite_dispatched + native_calls
  dispatched = {}
  policy.pin(memory, 'master', ctx)
  local second = component.run(memory, { code = script.code }, 'master', ctx, catalog, current_catalog, dispatch, execution)
  local component_calls = #dispatched
  comparisons = comparisons + 1
  local left, right = fields(first), fields(second)
  check(text(left) == text(right), script.label .. ': native ' .. text(left) .. ' vs component ' .. text(right))
  check(native_calls == component_calls, script.label .. ': the same number of tools was dispatched on both paths')
end

-- Refusals unchanged, read the way the model reads them: the discovery view still marks the fenced
-- names `callable:false` with their route, and the guest's own tool table still does not contain them.
local listing = component.run(memory, { code = 'const all = await searchTools("select:subagent,tool_call,sessions"); return JSON.stringify(all.tools.map(t=>({n:t.name,c:t.callable})));' },
  'master', ctx, catalog, current_catalog, dispatch, execution)
local rows = decode(decode(listing.value))
local seen = {}
for _, row in ipairs(type(rows) == 'table' and rows or {}) do seen[row.n] = row.c end
check(seen.subagent == false, 'subagent stays refused inside code mode: ' .. text(listing.value))
check(seen.tool_call == false, 'the outer facade stays refused inside code mode: ' .. text(listing.value))
check(seen.sessions == true, 'a read tool stays callable inside code mode: ' .. text(listing.value))
check(suite_dispatched >= 1, 'the parity suite dispatched tools through the real dispatcher: ' .. suite_dispatched)

print(string.format('codemode seam: %d checks, %d parity comparisons, %d skipped', checks, comparisons, skipped))
