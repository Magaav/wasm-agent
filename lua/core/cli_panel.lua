-- The CLI's bottom panel (`host.panel`, rust/wa-host/src/terminal_editor.rs `Panel`): a title, a few
-- lines, then a list or a field, closed with Esc - the way Claude Code shows `/model` or `/usage`.
-- `open` blocks until the reader answers and returns `{action = "select", index = n}`,
-- `{action = "submit", text = ...}`, `{action = "cancel"}` or `{action = "timeout"}`. The panel stays
-- up between calls, so a flow of several does not flicker; `close` gives the screen back to the box.
local json = dofile("lua/vendor/json.lua")
local M = {}

function M.available()
  return type(host) == "table" and type(host.panel) == "function"
end

function M.open(spec)
  local ok, raw = pcall(host.panel, json.encode(spec))
  if not ok or type(raw) ~= "string" then return { action = "unsupported" } end
  local decoded, value = pcall(json.decode, raw)
  if not decoded or type(value) ~= "table" then return { action = "unsupported" } end
  return value
end

function M.close()
  if M.available() then pcall(host.panel) end
end

return M
