-- A model is measured, not assumed (docs/AGENT-SEAT.md, principle 7).
--
-- The conformance suite runs ~10 recorded-shape tasks against a live model in a scratch home and
-- stores what it measured in ~/.wasm-agent/models/<model>.json. This file is that profile: how to
-- read it, how to write it, and what the node does when there is none.
--
-- The node picks the CodeAct transport and the guidance it sends FROM the profile. With no profile
-- the default is conservative and says so once: a model that can call tools is offered the run tool
-- (a native call needs no fence to be closed), and one that cannot is offered the block. The notice
-- is one line, and it suggests the measurement rather than guessing a result.
local json = dofile("lua/vendor/json.lua")
local state = dofile("lua/core/state.lua")

local M = {}

-- The two transports of principle 2, as the profile names them.
M.BLOCK = "block"
M.TOOL_CALL = "tool_call"

-- A model name is a file name here, and a path is not a name: anything that could escape the models
-- directory is refused rather than sanitised into a different file.
function M.safe_name(model)
  local name = tostring(model or "")
  if name == "" then return nil, "empty_model" end
  if name:find("/", 1, true) or name:find("\\", 1, true) or name == "." or name == ".." then
    return nil, "model_name_not_a_file_name"
  end
  if not name:match("^[%w%._%-]+$") then return nil, "model_name_not_a_file_name" end
  return name
end

-- ~/.wasm-agent/models/<model>.json, through the state helper so a scratch home is honoured.
function M.path(model)
  local name, why = M.safe_name(model)
  if not name then return nil, why end
  return state.path("models/" .. name .. ".json")
end

function M.read(model)
  local name = M.safe_name(model)
  if not name then return nil, "no_profile" end
  local text = state.read("models/" .. name .. ".json")
  if type(text) ~= "string" or text == "" then return nil, "no_profile" end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then return nil, "profile_unreadable" end
  if decoded.model ~= name then return nil, "profile_other_model" end
  return decoded
end

function M.write(model, profile)
  local name, why = M.safe_name(model)
  if not name then return nil, why end
  if type(profile) ~= "table" then return nil, "profile_not_a_table" end
  profile.model = name
  local ok, encoded = pcall(json.encode, profile)
  if not ok then return nil, "profile_not_encodable" end
  local wrote, problem = pcall(state.write, "models/" .. name .. ".json", encoded)
  if not wrote then return nil, "profile_write_failed: " .. tostring(problem) end
  return true
end

return M
