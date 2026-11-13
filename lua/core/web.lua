-- Fixed read-only MCP facade; no model-controlled connector definitions or browser actions.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local M={}

-- A refused fetch is not a dead end.
--
-- Measured 13/11, session b393f280 on node `work`: the run's last tool result was `web_http_429` and the
-- run stopped there with no answer and no next step ("stopped after a tool result with no next step",
-- `lua/core/memory.lua` detail_of). The refusal came back as a bare `{ok:false,error,status}`: a model
-- reading it has nothing to do next, and a model that stops leaves the user with silence. A transient
-- HTTP answer (408, 425, 429, 5xx) is a wait, not a verdict, so the tool says so - once, in the answer,
-- with the wait the server itself named when it named one, and with the honest alternatives.
--
-- It adds a sentence and never retries: replaying a search or a page fetch automatically is the client's
-- decision to make in the open, and an anonymous client that repeats a refused request makes it worse.
M.TRANSIENT = { [408] = true, [425] = true, [429] = true }

function M.next_step(data)
  if type(data) ~= 'table' then return data end
  local status = tonumber(data.status)
  if not status then return data end
  if not (M.TRANSIENT[status] or status >= 500) then return data end
  if data.error == nil then return data end
  data.retryable = true
  local wait = data.retry_after
  if type(wait) ~= 'string' or wait == '' then wait = nil end
  data.next_step = data.next_step or ('The site refused this fetch (HTTP ' .. status
    .. '). This is not the end of the task: '
    .. (wait and ('the same URL is answered again after ' .. wait .. ' (retry-after), so ')
      or 'the same URL may be readable again shortly, so ')
    .. 'use another source, or answer from what you already have and say that the page could not be read. '
    .. 'Do not repeat the same call immediately.')
  return data
end

function M.call(mcp,method,args,ctx)
 local directory=mcp.script_dir()
 if not directory then
  local missing=mcp.scripts_missing and mcp.scripts_missing() or {ok=false,searched={}}
  missing.error='web_adapter_not_installed'
  missing.reason='mcp_scripts_not_found'
  return missing
 end
 local script=host.getenv('WA_WEB_ADAPTER_SCRIPT') or directory..'/mcp-web.mjs'
 local binding={cache_dir=paths.cache()..'/web/'..host.sha256(tostring(ctx.user_id or 'master')..'\0'..tostring(ctx.session_id or ''))}
 local input={action='call',persistent_read=true,read_tools={'read','search'},server={transport='stdio',program=mcp.node_program(),args={script,'--binding-json',json.encode(binding)},timeout_seconds=30},tool=method}
 input.arguments_json=ctx.tool_arguments_json or (next(args)==nil and '{}' or json.encode(args))
 local answer=mcp.invoke(input,ctx)
 if answer.outcome=='unknown' then return M.next_step(mcp.project(answer)) end
 if answer.result_json then
  local result=json.decode(answer.result_json);local data=result.structuredContent
  if type(data)=='table' then data.evidence=answer.evidence;if answer.ok==false then data.ok=false;data.mcp_outcome=answer.outcome end;return M.next_step(data) end
 end
 return M.next_step(mcp.project(answer))
end
return M
