-- One status on every tool answer (operator 14/11: "return 200 for success", made engineering law):
-- the dispatcher stamps it, so no tool can drift and the model reads one signal everywhere.
--   200 it worked  ·  202 accepted, still running or queued  ·  400 the call was wrong (fix the call)
--   403 not allowed  ·  404 no such tool/target  ·  500 the call was right and the world failed it
-- A tool that already says its own `status` keeps it (the WhatsApp send answers 200/202/500 itself).
local M = {}

local NOT_FOUND = { 'unknown_tool', 'unknown_node', 'unknown_capability', 'unknown_id', '_not_found', 'file_missing', 'not_found' }
local FORBIDDEN = { 'forbidden', 'not_in_profile', 'denied', 'not_granted', 'requires_approval', 'hook_denied' }
local BAD_CALL = { 'schema_', 'bad_', '_required', 'invalid', 'exclusive', 'retired', 'codemode_only' }

local function has(text, list)
  for _, part in ipairs(list) do if text:find(part, 1, true) then return true end end
  return false
end

function M.of(result)
  if type(result) ~= 'table' then return 200 end
  if type(result.status) == 'number' then return result.status end
  local state = type(result.state) == 'string' and result.state or ''
  if state == 'pending' or state == 'queued' or state == 'running' then return 202 end
  local failed = result.ok == false or result.error ~= nil
  if not failed then return 200 end
  local code = tostring(result.code or result.error or ''):lower()
  if has(code, FORBIDDEN) then return 403 end
  if has(code, NOT_FOUND) then return 404 end
  if has(code, BAD_CALL) then return 400 end
  -- a script that did not run as written (SyntaxError, ReferenceError, TypeError ...) is the call to fix
  if code:find('^%a*error') then return 400 end
  return 500
end

function M.stamp(result)
  -- An array answer (a list) stays a list: a key on it would make it an object nothing can encode.
  if type(result) == 'table' and result.status == nil and result[1] == nil and next(result) ~= nil then result.status = M.of(result) end
  return result
end

return M
