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

-- `parameters` is the tool's own schema parameters object, or nil when this node has no schema for the name
-- (an unknown tool, or one whose schema only a peer has). No schema is not a verdict: an unknown name is
-- answered by the dispatcher's own unknown-tool path, so this refuses nothing on a schema it cannot read.

-- ── ENFORCEMENT (STEP 2, 23/11) ───────────────────────────────────────────────────────────────────────
-- ONE LINE decides who is refused. 'model' refuses an undeclared field again for a call THE MODEL sent and
-- records only for internal and peer callers; 'off' is STEP 1's behaviour (record everything, refuse
-- nothing). The other half of the switch is measured, not promised: internal and peer callers come under
-- enforcement only after 24 h with no `tool_arguments` event whose caller is internal or peer in this node's
-- telemetry - the row scripts/test-tool-args-report.lua names that measurement, and the flip is this line.
-- SHIPPED 'off': the model door can be enforced again in one line ('model'), and G may ship with it only
-- when the full main-health is green with it. It is off here because STEP 2's field work is not finished:
-- turning it on today would re-red the rows whose callers still send an undeclared field (see the report's
-- field table), and a red main is not a place to discover that a declaration is missing.
M.ENFORCE = 'off'

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
  return {
    error = 'unknown_argument:' .. table.concat(unknown, ','),
    tool = tostring(name),
    unknown_arguments = unknown,
    accepted = names,
    effect = 'none',
    message = '`' .. tostring(name) .. '` declares: ' .. list .. '. Nothing ran: an argument the tool does not '
      .. 'declare is refused by name rather than ignored, because a dropped field is a call that did something '
      .. 'else in silence.',
    fix = 'send only the names `' .. tostring(name) .. '` declares: ' .. list .. '.',
    input = table.concat(unknown, ', '),
  }
end

return M
