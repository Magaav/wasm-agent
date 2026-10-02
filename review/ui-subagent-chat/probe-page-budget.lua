-- Reviewer's node-level probe of the rule behind the page-budget fallback.
--
-- Run:  WASM_AGENT_LUA_ROOT=<tree> [WASM_AGENT_TOOL_OUTPUT_BYTES=<n>] WASM_AGENT_HOME=<scratch> \
--       wa.exe --db <scratch>/probe.db        (WA_SCRIPT=this file)
--
-- It answers, in the node's own code (lua/core/session_view.lua + lua/core/tool_output.lua) and not in a
-- JS fixture: is the size the window asks for accepted? is the unsized read accepted? what is the budget?
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local view = dofile('lua/core/session_view.lua')
local output = dofile('lua/core/tool_output.lua')

local sid = memory.start_session('', 'page budget probe', {user_id = 'owner'})
for i = 1, 12 do memory.append_turn(sid, {role = 'user', content = 'row ' .. i}) end
local task = {subagent_id = 'child', session_id = sid, state = 'completed', settled = true}

local function attempt(args)
  local ok, page = pcall(view.get, memory, sid, args, task)
  if not ok then return {threw = tostring(page)} end
  return {error = page.error, returned = page.returned, encoded_bytes = #json.encode(page),
    requested_byte_limit = args.byte_limit}
end

local report = {
  schema = 'wasm-agent.review-page-budget/v1',
  env_wasm_agent_tool_output_bytes = host.getenv('WASM_AGENT_TOOL_OUTPUT_BYTES') or '',
  max_bytes = output.MAX_BYTES,
  valid_max = output.MAX_BYTES - 2048,
  sized_40960 = attempt({limit = 200, byte_limit = 40960}),
  sized_20480 = attempt({limit = 200, byte_limit = 20480}),
  unsized = attempt({limit = 200}),
}
print(json.encode(report))
