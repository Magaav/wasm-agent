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
-- second opinion about a value would be a second contract to keep in step. A key the schema does not
-- declare is refused BY NAME, with the declared names in the fix line and `effect:"none"` - nothing ran.
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
-- refusal is appended to WASM_AGENT_TOOL_ARGUMENTS_LOG and the call proceeds exactly as it did before. It
-- exists so a new refusal can be counted against real traffic instead of guessed at, and it is read from the
-- environment on every call so a test can turn it on around one dispatch.
local function report_to()
  local ok, value = pcall(host.getenv, 'WASM_AGENT_TOOL_ARGUMENTS')
  if not ok or value ~= 'report' then return nil end
  local path_ok, path = pcall(host.getenv, 'WASM_AGENT_TOOL_ARGUMENTS_LOG')
  if not path_ok or type(path) ~= 'string' or path == '' then return nil end
  return path
end

local function record(path, name, unknown, args)
  local line = json.encode({ tool = tostring(name), unknown = unknown,
    keys = (function() local keys = {}; for key in pairs(args or {}) do keys[#keys + 1] = tostring(key) end; table.sort(keys); return keys end)() })
  if type(host.append_file) == 'function' then pcall(host.append_file, path, line .. '\n') end
end

-- `parameters` is the tool's own schema parameters object, or nil when this node has no schema for the name
-- (an unknown tool, or one whose schema only a peer has). No schema is not a verdict: an unknown name is
-- answered by the dispatcher's own unknown-tool path, so this refuses nothing on a schema it cannot read.
function M.refusal(name, args, parameters)
  if type(args) ~= 'table' then return nil end
  if type(parameters) ~= 'table' then return nil end
  -- A schema that says it is open ("additionalProperties": true) declares every name, so nothing is unknown.
  if parameters.additionalProperties == true then return nil end
  local declared = type(parameters.properties) == 'table' and parameters.properties or {}
  local allowed, names = {}, {}
  for key in pairs(declared) do allowed[key] = true; names[#names + 1] = tostring(key) end
  table.sort(names)
  for key in pairs(M.INTERNAL) do allowed[key] = true end
  local unknown = {}
  for key in pairs(args) do
    if not allowed[key] then unknown[#unknown + 1] = tostring(key) end
  end
  if #unknown == 0 then return nil end
  table.sort(unknown)
  local path = report_to()
  if path then record(path, name, unknown, args); return nil end
  local list = #names > 0 and table.concat(names, ', ') or 'no arguments'
  -- The sentence is THIS module's, not the refusal renderer's: `message`, `fix` and `input` together make
  -- lua/core/refusal.lua keep it as written (its own templates describe a code's family, and a code with a
  -- field in it is not a family). The first line names what the tool DOES take, which is the line a model
  -- acts on.
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
