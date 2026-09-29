-- The listing, as the route serves it for `modules/index.json`, printed for a caller that needs the
-- bytes a page would have fetched.
--
-- Why it exists: the host page is also a static page (a worker can render it with the headless
-- observer), and the honest way to give it a listing is the route's own answer for this tree -
-- not a checked-in file listing module ids, which would survive a deletion and lie.
--
-- The environment is the ask, exactly as for a node: WASM_AGENT_MODULES,
-- WASM_AGENT_MODULE_CAPABILITIES, WASM_AGENT_MODULES_DIR. Nothing here decides anything.
local json = dofile("lua/vendor/json.lua")
local modules = dofile("lua/core/modules.lua")

local answer = json.decode(wa_modules("file", "", "index.json", ""))
if type(answer) ~= "table" or answer.status ~= 200 then
  io.stderr:write("module listing unavailable: " .. tostring(answer and answer.body) .. "\n")
  os.exit(1)
end
io.write(answer.body)
