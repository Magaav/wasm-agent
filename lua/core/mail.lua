-- Fixed mail facade over mail-mcp; no model-controlled server definitions.
--
-- The credential never reaches this file. It lives in `<data>/secrets/mail-<segment>.env` (0600), and
-- `scripts/mcp-mail.mjs` is the only process that reads it - the host cannot pass literal environment
-- values to a spawned MCP server, so that proxy exists to hold the boundary. This facade decides two
-- things the proxy cannot know: which binary and secret file apply, and whether a write tool is even
-- offered. The proxy checks the same write tier again, on its own, before dispatching.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local platform = dofile('lua/core/platform.lua')
local M = {}

-- Tools that change mail. Everything not listed here is a read, which is why the list is exhaustive
-- rather than a pattern: a new upstream tool is refused by name until someone decides its tier.
local WRITE = {
  smtp_send_message = true, smtp_reply_message = true, smtp_forward_message = true,
  draft_create = true, draft_update = true, draft_delete = true, draft_send = true,
  imap_append_message = true, imap_delete_message = true, imap_move_message = true,
  imap_copy_message = true, imap_update_message_flags = true, imap_bulk_delete = true,
  imap_bulk_move = true, imap_bulk_update_flags = true, imap_create_mailbox = true,
  imap_delete_mailbox = true, imap_rename_mailbox = true, imap_search_and_delete = true,
  imap_search_and_move = true, graph_send_message = true, ews_send_message = true,
}

function M.is_write(tool) return WRITE[tool] == true end

function M.secret_file(ctx)
  ctx = ctx or {}
  if type(ctx.mail_secret_file) == 'string' and ctx.mail_secret_file ~= '' then return ctx.mail_secret_file end
  local segment = type(ctx.mail_segment) == 'string' and ctx.mail_segment or 'default'
  -- A segment names one account; it is a file name component, so it may not contain one.
  if not segment:match('^[a-z0-9_-]+$') then return nil end
  return paths.data() .. '/secrets/mail-' .. segment .. '.env'
end

local function script_dir(mcp)
  local directory = mcp.script_dir()
  if not directory then return nil end
  return directory
end

function M.call(mcp, method, args, ctx)
  ctx = ctx or {}
  local binary = mcp.mail_program and mcp.mail_program()
  if not binary then
    return { ok = false, error = 'mail_binary_not_found', tool_call_issued = false,
      fix = 'run the installer (it provisions mail-mcp) or set MAIL_MCP_BIN' }
  end
  local directory = script_dir(mcp)
  if not directory then
    local missing = mcp.scripts_missing and mcp.scripts_missing() or { ok = false, searched = {} }
    missing.error = 'mail_proxy_not_installed'
    missing.reason = 'mcp_scripts_not_found'
    return missing
  end
  local secret = M.secret_file(ctx)
  if not secret then return { ok = false, error = 'mail_segment_invalid', tool_call_issued = false } end
  if host.path_kind(secret) ~= 'file' then
    return { ok = false, error = 'mail_secret_file_missing', file = secret, tool_call_issued = false,
      fix = 'run scripts/mail-auth.mjs for this account (App Password or OAuth) to create it' }
  end
  local writes = host.getenv('WA_MAIL_WRITES') == 'enabled'
  if M.is_write(method) and not writes then
    return { ok = false, error = 'mail_writes_not_enabled', tool = method, tool_call_issued = false,
      outcome = 'not_submitted', fix = 'writes are off; set WA_MAIL_WRITES=enabled to allow this tool' }
  end
  local binding = { binary = binary, secret_file = secret, writes = writes and 'enabled' or 'disabled' }
  local node = mcp.node_program and mcp.node_program() or (host.getenv('WA_NODE') or 'node')
  local input = {
    action = 'call',
    server = {
      transport = 'stdio',
      program = node,
      args = { directory .. '/mcp-mail.mjs', '--binding-json', json.encode(binding) },
      timeout_seconds = tonumber(ctx.mail_timeout_seconds) or 120,
    },
    tool = method,
  }
  input.arguments_json = ctx.tool_arguments_json or (next(args) == nil and '{}' or json.encode(args))
  local answer = mcp.invoke(input, ctx)
  if answer.outcome == 'unknown' then return mcp.project(answer) end
  if answer.result_json then
    local result = json.decode(answer.result_json)
    local data = result.structuredContent
    if type(data) == 'table' then
      if data.ok == nil then data.ok = true end -- a structured result with no error is a success; the SDK does not set it
      data.evidence = answer.evidence
      if answer.ok == false then data.ok = false; data.mcp_outcome = answer.outcome end
      return data
    end
  end
  return mcp.project(answer)
end

return M
