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

-- A model id is a file name here, and a path is not a name - but a model id may legitimately CARRY a
-- separator (`vendor/model`, which is how most providers name them). It used to be refused outright, so
-- such a model could never have a profile and the door could never open for it (review r1, item 5).
-- The file name is the id with the separator PERCENT-ENCODED: one-to-one and reversible, so the id is
-- still the id, and a name still cannot walk out of the models directory.
function M.file_name(model)
  local name = tostring(model or "")
  if name == "" then return nil, "empty_model" end
  if name == "." or name == ".." then return nil, "model_name_not_a_file_name" end
  if name:find("%z") then return nil, "model_name_not_a_file_name" end
  local encoded = name:gsub("[/\\]", function(c) return c == "/" and "%%2F" or "%%5C" end)
  encoded = encoded:gsub("%s", "%%20")
  if not encoded:match("^[%w%._%%%-]+$") then return nil, "model_name_not_a_file_name" end
  return encoded
end

-- The same question, under the name the rest of the tree calls it: a name that is safe to store.
function M.safe_name(model)
  return M.file_name(model)
end

-- ~/.wasm-agent/models/<model>.json, through the state helper so a scratch home is honoured.
function M.path(model)
  local name, why = M.file_name(model)
  if not name then return nil, why end
  return state.path("models/" .. name .. ".json")
end

-- The built-in default transport, by PROVIDER (review MUST 1).
--
-- A provider is an adapter family: every model behind it speaks one wire protocol and one action
-- channel. Keying this by provider id - not by a model name - keeps the core free of model branches
-- (the rule the reviewer enforces): a new model on this provider inherits the default, and a new
-- provider refuses until someone writes a row here or a measured profile replaces it.
M.DEFAULT_TRANSPORTS = {
  -- The fleet's provider: an OpenAI-compatible endpoint whose models take native tool calls, and
  -- whose local edge refuses a request with no session (so the tool-call transport is what actually
  -- works there). Measured by the conformance suite on 19/11: the model acts through run() calls.
  ["opencode-go"] = M.TOOL_CALL,
}

-- The transport this provider uses when no measured profile exists, or nil when nobody decided.
function M.builtin_transport(provider_id)
  return M.DEFAULT_TRANSPORTS[tostring(provider_id or "")]
end

function M.read(model)
  local name = M.file_name(model)
  if not name then return nil, "no_profile" end
  local text = state.read("models/" .. name .. ".json")
  if type(text) ~= "string" or text == "" then return nil, "no_profile" end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" then return nil, "profile_unreadable" end
  -- The profile stores the model ID as the operator names it; the FILE name is the encoded one.
  if tostring(decoded.model or "") ~= tostring(model) then return nil, "profile_other_model" end
  return decoded
end

function M.write(model, profile)
  local name, why = M.file_name(model)
  if not name then return nil, why end
  if type(profile) ~= "table" then return nil, "profile_not_a_table" end
  profile.model = tostring(model)
  local ok, encoded = pcall(json.encode, profile)
  if not ok then return nil, "profile_not_encodable" end
  local wrote, problem = pcall(state.write, "models/" .. name .. ".json", encoded)
  if not wrote then return nil, "profile_write_failed: " .. tostring(problem) end
  return true
end

return M
