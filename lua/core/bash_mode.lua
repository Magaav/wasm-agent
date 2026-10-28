-- `!command` in the CLI: Claude Code's bash mode.
--
-- The command runs here, in the chat's working directory, through the same `host.exec` the `bash`
-- tool uses (same bounds, same containment). Its output is drawn in the transcript the way a tool
-- result is, and the command with its output is recorded in the session as one user message in
-- Claude Code's shape - `<bash-input>…</bash-input>` then `<bash-stdout>…</bash-stdout>
-- <bash-stderr>…</bash-stderr>` - so the model sees it on the next turn. Like Claude Code it does
-- not start a turn: the reader runs a command, looks at it, and then asks.
--
-- The row is `phase = "bash"`: `memory.session_state` reads it as settled rather than as a question
-- nobody answered, and the CLI's replay draws it as a command again instead of as raw tags.
-- Everything recorded or drawn goes through `redact.value` first, `/vault` keys included.
local json = dofile("lua/vendor/json.lua")
local redact = dofile("lua/core/redact.lua")

local M = {}

-- The most output kept in the context; the transcript shows the usual clipped preview either way.
M.MAX_CONTEXT = 30000

local function clip(text)
  text = tostring(text or "")
  if #text <= M.MAX_CONTEXT then return text end
  return text:sub(1, M.MAX_CONTEXT) .. "\n[... " .. (#text - M.MAX_CONTEXT) .. " more bytes not kept]"
end

-- `!  ls -la ` -> `ls -la`; nil for a line that is not bash mode or has no command.
function M.command(line)
  local rest = tostring(line or ""):match("^%s*!(.*)$")
  if not rest then return nil end
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
  return rest ~= "" and rest or nil
end

-- The message the model sees, from a redacted result (`{code, stdout, stderr}`).
function M.context(command, result)
  result = type(result) == "table" and result or { stdout = tostring(result or "") }
  local stderr = tostring(result.stderr or result.error or "")
  local code = tonumber(result.code)
  if code and code ~= 0 and stderr == "" then stderr = "exit code " .. code end
  return "<bash-input>" .. command .. "</bash-input>\n<bash-stdout>" .. clip(result.stdout) ..
    "</bash-stdout><bash-stderr>" .. clip(stderr) .. "</bash-stderr>"
end

-- The command and the output back out of a recorded message (for the replay), or nil.
function M.parse(content)
  content = tostring(content or "")
  local command = content:match("^<bash%-input>(.-)</bash%-input>")
  if not command then return nil end
  return command, content:match("<bash%-stdout>(.-)</bash%-stdout>") or "",
    content:match("<bash%-stderr>(.-)</bash%-stderr>") or ""
end

-- Run, draw, record. `opts`: `{session_id, cwd, view, exec, record}` (the last two injectable for
-- tests). Returns the redacted result and the recorded content.
function M.run(command, opts)
  opts = opts or {}
  local view = opts.view
  local args = { command = command }
  if view then view:event({ type = "tool", name = "bash", arguments = args, quiet = true }) end
  local exec = opts.exec or function(text, cwd) return host.exec(text, cwd or "") end
  local ok, raw = pcall(exec, command, opts.cwd)
  local result
  if not ok then result = { code = -1, stdout = "", stderr = tostring(raw) }
  elseif type(raw) == "string" then
    local decoded, value = pcall(json.decode, raw)
    result = (decoded and type(value) == "table") and value or { stdout = raw }
  else result = type(raw) == "table" and raw or {} end
  local clean = redact.value(result, { tool = "bash", args = args })
  if view then view:event({ type = "tool_result", name = "bash", result = clean, quiet = true }) end
  local content = M.context(command, clean)
  local record = opts.record or function(session_id, turn) return dofile("lua/core/memory.lua").append_turn(session_id, turn) end
  if opts.session_id then record(opts.session_id, { role = "user", phase = "bash", content = content }) end
  return clean, content
end

return M
