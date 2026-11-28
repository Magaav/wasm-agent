-- ONE validator for a tool call's arguments, at the dispatch a local call and a peer call share.
--
-- WHY. Two "what hurt" notes from real sessions: `tools.remote({capability:"bash", stdin:"hello"})` wrote an
-- empty file and answered code 0 with empty stdout, and a `read`/grep on a peer answered less than the same
-- call here. Both are the same failure one level down: an argument the tool does not know is SILENTLY
-- DROPPED, so the call runs as a different call and its answer looks like success. The fix is one refusal,
-- worded the same whichever route the call took - a direct model call, a script's `tools.<name>`, a
-- `tool_call` batch, or a peer's capability - because they all reach `tools.dispatch`, which is where this
-- is asked (lua/core/tools.lua; the peer path ends in the same function, lua/core/server.lua wa_peer_dispatch).
--
-- WHAT IT JUDGES. Only the TOP-LEVEL key names of the arguments, against the names the tool's own schema
-- declares. It does not type-check, bound-check or rewrite a value: the handler already does that, and a
-- second opinion about a value would be a second contract to keep in step.
--
-- STEP 1 (23/11, Fable): a key the schema does not declare is RECORDED, not refused - one telemetry event
-- per distinct tool+field, names only, never a value - and the call runs exactly as it did before this
-- module existed. Enforcement returns in STEP 2 for model-sent calls first, once every field real use sends
-- has been declared or stopped sending it. Until then this module is a measurement, not a wall.
--
-- WHAT IT EXCLUDES, in two tables that each say why:
--   * INTERNAL - fields the RUNTIME adds to a call it makes itself (adoption's budget_ms, the reader's
--     `tool` label, another node's picture request). These are not the model's words and no caller can
--     reach them; each entry names the code that writes it.
--   * SYNONYMS - a well-known spelling a handler already maps onto its declared argument (file_tools.ALIASES
--     maps `file_path` onto `path`, `old_string`/`new_string` onto `old_text`/`new_text`). Refusing those
--     would break calls the node deliberately accepts, so the allow-list is read from that same table rather
--     than restated here.
local json = dofile('lua/vendor/json.lua')

local M = {}

M.INTERNAL = {
  -- Adoption (`remote {capability:"bash", budget_ms:...}` -> lua/core/server.lua adopt_bash): the caller's
  -- word about how long IT may wait, never a field of the tool being run.
  budget_ms = 'adoption wait budget, read by lua/core/server.lua adopt_bash',
  -- The name a reader's row shows for a running command (lua/core/tools.lua bash -> provenance.tool) and the
  -- label adopt_bash hands `operation await` so the op's own result is drawn under the tool that made it.
  tool = 'the reader label for a command (provenance.tool, operation await)',
  -- A peer's picture bytes as one node's read asks another's (lua/core/remote_image.lua): the field travels
  -- on the wire only, and a peer that predates it answers exactly what it answered before.
  image_bytes = 'a picture request between nodes (lua/core/remote_image.lua)',
  -- Code mode's own pending layer stamps these on a call it re-dispatches; they are not arguments.
  copen = 'code-mode pending bookkeeping',
  -- `operation start` is called with the priority flag set by code mode (lua/core/tools.lua bash,
  -- ctx.background_operation): the caller's own statement about who waits, not an argument of the tool.
  background = 'operation start priority flag, set by lua/core/tools.lua from code mode',
  -- `operation`'s own control flag: the kernel's control call (a catalogue probe), never a model's word.
  control = 'operation control call, sent by the kernel',
  -- The pending layer asks an await for the command's output in the same call (lua/core/codemode_pending.lua):
  -- the answer is the call's, not a field of the tool the model is naming.
  output = 'code-mode pending: ask the await for output (lua/core/codemode_pending.lua)',
  max_bytes = 'code-mode pending: the await output bound (lua/core/codemode_pending.lua)',
  -- The file tools' synonyms live here, read from the one table that defines them (file_tools.ALIASES).
  file_path = 'synonym for path (lua/core/file_tools.lua ALIASES)',
  old_string = 'synonym for old_text (lua/core/file_tools.lua ALIASES)',
  new_string = 'synonym for new_text (lua/core/file_tools.lua ALIASES)',
  -- The targets those synonyms map onto: `edit` accepts a single top-level old_text/new_text pair (the
  -- ALIASES table maps old_string onto old_text, so the handler reads exactly these names).
  old_text = 'top-level single-edit pair (lua/core/file_tools.lua ALIASES target)',
  new_text = 'top-level single-edit pair (lua/core/file_tools.lua ALIASES target)',
}

-- The report mode, used to MEASURE before refusing: with WASM_AGENT_TOOL_ARGUMENTS=report every would-be
-- STEP 1 (23/11, Fable). This check is REPORT-ONLY on main: a call with an argument the tool does not
-- declare RUNS EXACTLY as it did before the validator existed (the field is ignored, as it always was), and
-- the fact is recorded instead of refused - ONE telemetry event per distinct tool+field, with NO values.
-- Enforcement comes back in STEP 2, for model-sent calls first, once every field real use sends has been
-- declared or stopped. So this function answers nil always; the name is kept so the call site reads the same.
local RECORDED = {}

-- Who sent the call: the model itself, the runtime on the model's behalf, or another node. Read from the
-- context the dispatcher already carries - never from the arguments, which are what is being judged.
local function caller_kind(ctx)
  ctx = type(ctx) == 'table' and ctx or {}
  if ctx.peer_call then return 'peer' end
  if ctx.codemode_nested or ctx.codemode_deadline or ctx.subagent or ctx.internal_call then return 'internal' end
  return 'model'
end

-- One event per distinct tool+field, for the life of this process: a chatty caller costs one row, not one
-- per call. The payload carries names only - never a value, which could be a secret or a whole file.
local function note(name, field, fields, ctx)
  local key = tostring(name) .. '\0' .. tostring(field)
  if RECORDED[key] then return end
  RECORDED[key] = true
  local ok, telemetry = pcall(dofile, 'lua/core/telemetry.lua')
  if not ok or type(telemetry) ~= 'table' or type(telemetry.event) ~= 'function' then return end
  ctx = type(ctx) == 'table' and ctx or {}
  pcall(telemetry.event, ctx.session_id, ctx.run_id, nil, 'tool_arguments', 'undeclared',
    { tool = tostring(name), field = tostring(field), fields = fields, caller = caller_kind(ctx) })
end

-- What the call carries that the tool's schema does not declare: the one rule, in one place, so the row
-- that measures it and the dispatch that runs it cannot disagree.
-- THE CONTRACT MODULE, THROUGH THE SHARED LOADER (law 18): reload.require reads WASM_AGENT_LUA_ROOT first,
-- so this works whatever the process's cwd is.
local contract_module
local function require_contract()
  if contract_module ~= nil then return contract_module or nil end
  local ok, module = pcall(dofile, 'lua/core/reload.lua')
  if ok and type(module) == 'table' and type(module.require) == 'function' then
    local loaded, contract = pcall(module.require, 'lua/core/json_contract.lua')
    if loaded and type(contract) == 'table' and type(contract.field_intent) == 'function' then
      contract_module = contract
      return contract
    end
  end
  contract_module = false
  return nil
end

function M.undeclared(name, args, parameters)
  if type(args) ~= 'table' then return nil end
  if type(parameters) ~= 'table' then return nil end
  -- A schema that says it is open ("additionalProperties": true) declares every name, so nothing is unknown.
  if parameters.additionalProperties == true then return nil end
  local declared = type(parameters.properties) == 'table' and parameters.properties or {}
  local allowed = {}
  for key in pairs(declared) do allowed[key] = true end
  for key in pairs(M.INTERNAL) do allowed[key] = true end
  local unknown = {}
  for key in pairs(args) do
    if not allowed[key] then unknown[#unknown + 1] = tostring(key) end
  end
  if #unknown == 0 then return nil end
  table.sort(unknown)
  return unknown
end

-- The nearest declared name, the same rule as the contract layer's (edit distance, half the word sent, at
-- least 2, so a suggestion is only made when it is close enough to be worth naming).
local function edit_cost(a, b)
  if #a == 0 then return #b end
  if #b == 0 then return #a end
  local row = {}
  for j = 0, #b do row[j] = j end
  for i = 1, #a do
    local previous = row[0]
    row[0] = i
    for j = 1, #b do
      local current = row[j]
      row[j] = math.min(row[j] + 1, row[j - 1] + 1, previous + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
      previous = current
    end
  end
  return row[#b]
end
local function nearest(name, declared)
  local sent = tostring(name)
  -- A PREFIX WINS FIRST, exactly as in lua/core/json_contract.lua: `q` is four edits from `query`, and a
  -- distance threshold alone would refuse the one suggestion a model was going to make.
  local prefix
  for candidate in pairs(declared or {}) do
    local word = tostring(candidate)
    local shorter, longer = sent, word
    if #shorter > #longer then shorter, longer = longer, shorter end
    if #shorter >= 1 and #longer > #shorter and longer:sub(1, #shorter) == shorter then
      if not prefix or #word < #prefix or (#word == #prefix and word < prefix) then prefix = word end
    end
  end
  if prefix then return prefix end
  local best, best_cost
  for candidate in pairs(declared or {}) do
    local word = tostring(candidate)
    local cost = edit_cost(sent, word)
    if best_cost == nil or cost < best_cost or (cost == best_cost and word < best) then best, best_cost = word, cost end
  end
  if not best or best_cost > math.max(2, math.floor(#sent / 2)) then return nil end
  return best
end

-- `parameters` is the tool's own schema parameters object, or nil when this node has no schema for the name
-- (an unknown tool, or one whose schema only a peer has). No schema is not a verdict: an unknown name is
-- answered by the dispatcher's own unknown-tool path, so this refuses nothing on a schema it cannot read.

-- ── ENFORCEMENT (STEP 2, 23/11) ───────────────────────────────────────────────────────────────────────
-- ONE LINE decides who is refused. 'model' refuses an undeclared field again for a call THE MODEL sent and
-- records only for internal and peer callers; 'off' is STEP 1's behaviour (record everything, refuse
-- nothing). The other half of the switch is measured, not promised: internal and peer callers come under
-- enforcement only after 24 h with no `tool_arguments` event whose caller is internal or peer in this node's
-- telemetry - the row scripts/test-tool-args-report.lua names that measurement, and the flip is this line.
-- SHIPPED 'model' (25/11, this mission). The field work STEP 2 was waiting on is done, and the mission
-- that writes the one rule into the contract layer (lua/core/json_contract.lua) is the moment the model
-- door closes: a call THE MODEL sent with a name its tool never declares is refused by name, with the
-- nearest name the tool does take. Internal and peer callers stay report-only until the measurement above
-- says otherwise - their fields are the runtime's own, and a peer call is judged by the PEER's schema.
M.ENFORCE = 'model'

-- Record always; refuse only what the switch names. STEP 1 recorded everything and refused nothing; STEP 2
-- refuses the MODEL's own calls again (the door the model reads), and keeps internal and peer callers
-- report-only until the measurement above says otherwise.
function M.refusal(name, args, parameters, ctx)
  local unknown = M.undeclared(name, args, parameters)
  if not unknown then return nil end
  for _, field in ipairs(unknown) do note(name, field, unknown, ctx) end
  local caller = caller_kind(ctx)
  if M.ENFORCE ~= 'model' or caller ~= 'model' then return nil end
  local declared = type(parameters) == 'table' and type(parameters.properties) == 'table' and parameters.properties or {}
  local names = {}
  for key in pairs(declared) do names[#names + 1] = tostring(key) end
  table.sort(names)
  local list = #names > 0 and table.concat(names, ', ') or 'no arguments'
  -- The same code and the same suggestion the contract layer makes (lua/core/json_contract.lua,
  -- `unknown_argument:q - did you mean query?`), because a call refused at this door and the same call
  -- refused inside a run block must read as one refusal, not two.
  local first = unknown[1]
  -- THE ONE OWNER OF "WHAT DID THE CALLER MEAN" (refusals-that-help (b), law 17/18): the contract layer's
  -- nearest name first, then its intent table for words a model uses for a field it never saw
  -- (`new_str` -> `edits`, `name` -> `id`), and the shape of the field it names.
  local contract = require_contract()
  local did, how = nil, nil
  if type(contract) == 'table' and type(contract.field_intent) == 'function' then
    did, how = contract.field_intent(name, first, declared)
  end
  local shape = nil
  if did and type(contract) == 'table' and type(contract.shape_of) == 'function' then
    shape = contract.shape_of(declared[did])
  end
  return {
    error = 'unknown_argument:' .. first .. (did and (' - did you mean ' .. did .. '?') or ''),
    tool = tostring(name),
    unknown_arguments = unknown,
    accepted = names,
    effect = 'none',
    did_you_mean = did,
    suggested = did,
    suggested_shape = shape,
    suggested_reason = how,
    message = '`' .. tostring(name) .. '` does not take the argument `' .. first .. '` - its own schema '
      .. 'never declares that name, so nothing ran. It declares: ' .. list .. '.',
    fix = 'drop `' .. first .. '`' .. (did and (', did you mean `' .. did .. '`?') or '')
      .. ' `' .. tostring(name) .. '` takes: ' .. list .. '.'
      .. (did and shape and (' `' .. did .. '` is ' .. shape .. '.') or ''),
    input = table.concat(unknown, ', '),
  }
end

return M
