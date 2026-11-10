-- When a durable MCP read reservation is released (10/11).
--
-- `lua/core/mcp_session.lua` reserves uncertainty in `meta` before every read and releases it only on
-- an answer it can verify. The first rule accepted only a result carrying `result_json` and a matching
-- schema hash, so an answer the MCP server itself gave as a refusal - `mcp_rpc_error:-32002:IMAP
-- account 'default' is not configured` - was rewritten to `outcome=unknown`, the reservation stayed,
-- and that connector answered `mcp_connection_uncertain` on every later call, permanently. Measured on
-- the live `google` connector after the `$schema` fix let the call reach the server at all.
--
-- This pins the predicate that decides it. It is a table in, a decision out: no host, no connector.
local session=dofile('lua/core/mcp_session.lua')
local checks=0
local function check(v,label)assert(v,label);checks=checks+1 end
local function eq(a,b,label)assert(a==b,(label or '')..': got '..tostring(a)..', want '..tostring(b));checks=checks+1 end

-- ---- a verified success is decided ---------------------------------------------------------
local good={ok=true,tool_call_issued=true,outcome='unknown',result_json='{"mailboxes":[]}',schema_hash='h1'}
eq(session.accepted(good,'h1'),true,'a verified result settles the reservation')
eq(session.accepted(good,'h2'),false,'the same result under a different schema does not')

-- ---- a definite refusal FROM THE SERVER is decided (the regression) -------------------------
local refused={ok=false,error="mcp_rpc_error:-32002:IMAP account 'default' is not configured",
  phase='tools/call',tool_call_issued=true,outcome='unknown'}
eq(session.accepted(refused,'h1'),true,'a server-answered rpc error settles the reservation (the wedge)')

-- ---- what must stay unknown ---------------------------------------------------------------
eq(session.accepted({ok=false,outcome='unknown',tool_call_issued=true},'h1'),false,
  'an error with no server answer stays unknown')
eq(session.accepted({ok=false,error='mcp_session_reply_unverified',outcome='unknown',tool_call_issued=true},'h1'),false,
  'a lost reply stays unknown')
eq(session.accepted({ok=false,error='mcp_result_artifact_unverified',outcome='unknown',tool_call_issued=true},'h1'),false,
  'an unverified artifact stays unknown')
eq(session.accepted({ok=true,tool_call_issued=true,outcome='unknown'},'h1'),false,
  'an ok answer that carries no result stays unknown')
eq(session.accepted('not a table','h1'),false,'an unreadable answer stays unknown')

-- ---- a refused submission was never issued ------------------------------------------------
eq(session.accepted({ok=false,outcome='not_submitted',tool_call_issued=false},'h1'),true,
  'a call that was never issued settles as not_submitted')

-- ---- what this test deliberately does NOT claim -----------------------------------------
-- A held reservation is never reopened, even when a retained answer sits beside it: the reply was not
-- verified, and `scripts/test-mcp-recovery.lua` holds that line (`same-VM no replay`). The bug was
-- CREATING that state for an answer the server actually gave - which is what the cases above pin.

print('test-mcp-session-settlement: '..checks..' checks passed')
