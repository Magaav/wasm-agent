-- Fixed read-only MCP facade; no model-controlled connector definitions or browser actions.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local M={}
function M.call(mcp,method,args,ctx)
 local directory=mcp.script_dir();if not directory then return {ok=false,error='web_adapter_not_installed'} end
 local script=host.getenv('WA_WEB_ADAPTER_SCRIPT') or directory..'/mcp-web.mjs'
 local binding={cache_dir=paths.cache()..'/web/'..host.sha256(tostring(ctx.user_id or 'master')..'\0'..tostring(ctx.session_id or ''))}
 local input={action='call',persistent_read=true,read_tools={'read','search'},server={transport='stdio',program=host.getenv('WA_NODE') or 'node',args={script,'--binding-json',json.encode(binding)},timeout_seconds=30},tool=method}
 input.arguments_json=ctx.tool_arguments_json or (next(args)==nil and '{}' or json.encode(args))
 local answer=mcp.invoke(input,ctx)
 if answer.outcome=='unknown' then return mcp.project(answer) end
 if answer.result_json then
  local result=json.decode(answer.result_json);local data=result.structuredContent
  if type(data)=='table' then data.evidence=answer.evidence;if answer.ok==false then data.ok=false;data.mcp_outcome=answer.outcome end;return data end
 end
 return mcp.project(answer)
end
return M
