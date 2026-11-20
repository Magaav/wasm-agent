-- Which adapter serves a transport (docs/AGENT-SEAT.md, principles 2 and 3).
--
-- The choice is by TRANSPORT - the wire protocol a route already declares (provider.transport) -
-- and never by model name. A model whose transport is unknown is refused by name; it is never
-- guessed onto the adapter of whichever model happened to be measured last. That is the same rule
-- the seat states for CodeAct transport selection, applied to the provider seam.
local M = {}

-- An allow-list, not a block-list: a transport is served only when it is named here, and a new
-- provider refuses until someone decides. Every entry is a file beside this one.
M.ADAPTERS = {
  ["openai-completions"] = "lua/core/adapters/openai_completions.lua",
  ["anthropic-messages"] = "lua/core/adapters/anthropic_messages.lua",
  ["local"] = "lua/core/adapters/local.lua",
}

-- The transports this build can serve, sorted, for a refusal that names them.
function M.transports()
  local names = {}
  for name in pairs(M.ADAPTERS) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- The adapter for a transport, or nil and the reason. An unknown transport answers
-- "unknown_transport: <name> (this build serves: a, b, c)" - the refusal names both sides, so the
-- fix is in the message rather than in a guess.
function M.for_transport(transport)
  local name = tostring(transport or "")
  if name == "" then
    return nil, "unknown_transport: the route declares no transport (this build serves: "
      .. table.concat(M.transports(), ", ") .. ")"
  end
  local path = M.ADAPTERS[name]
  if not path then
    return nil, "unknown_transport: " .. name .. " (this build serves: "
      .. table.concat(M.transports(), ", ") .. ")"
  end
  local adapter = dofile(path)
  if type(adapter) ~= "table" or type(adapter.from_payload) ~= "function" then
    return nil, "adapter_malformed: " .. path .. " does not answer from_payload"
  end
  return adapter
end

return M
