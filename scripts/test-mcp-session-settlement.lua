-- When a durable MCP read reservation is released (10/11).
--
-- `lua/core/mcp_session.lua` reserves uncertainty in `meta` before every read and releases it only on
-- an answer it can verify. The first rule accepted only a result carrying `result_json` and a matching
-- schema hash, so an answer the MCP server itself gave as a refusal - `mcp_rpc_error:-32002:IMAP
-- account 'default' is not configured` - was rewritten to `outcome=unknown`, the reservation stayed,
-- and that connector answered `mcp_connection_uncertain` on every later call, permanently. Measured on
-- the live `google` connector after the `$schema` fix let the call reach the server at all.
--
-- This pins the predicate that decides it, and the reconciliation of a marker an earlier process left
-- behind: table in, a decision out - no connector is spawned and no read is issued.
local json=dofile('lua/vendor/json.lua')
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
-- A held reservation whose retained answer is a *complete result* is not settled here: nothing verified
-- its sha256 (that was in the reply that was lost), so it keeps holding and `scripts/test-mcp-recovery.lua`
-- owns that line (`same-VM no replay`). The bug was CREATING that state for an answer the server actually
-- gave - which is what the cases above pin.

-- ---- a marker left behind is settled from its evidence, never by replaying it (10/11) ------------
-- Session db57bc92 was killed while the `google` connector was mid-repair, and the reservation it had
-- written before submitting the read outlived the process: every later call in that session answered
-- `mcp_connection_uncertain`. The evidence for what happened is still on disk, and reconciling it must
-- not re-send the call.
local files, deletes, issued = {}, {}, 0
local real_read_file, real_sql_exec = host.read_file, host.sql_exec
local real_http, real_operation = host.http, host.operation
host.http = function() issued = issued + 1; error('a read must not be issued while reconciling') end
host.operation = function() issued = issued + 1; error('no operation may start while reconciling') end
local function with_evidence(answer, request_input)
  files['/mcp/requests/r1.json.result.json'] = answer and json.encode(answer) or nil
  files['/mcp/requests/r1.json'] = request_input and json.encode(request_input) or nil
end
host.read_file = function(path) return files[path] end
host.sql_exec = function(sql, params)
  local values = json.decode(params) or {}
  deletes[#deletes + 1] = values[1]
  return json.encode({ ok = true, changes = 1 })
end
local function reconciled(answer, request_input)
  with_evidence(answer, request_input)
  deletes = {}
  return session.reconcile('mcp.read_uncertain.v1:key', '/mcp/requests/r1.json', 'h1')
end

-- a server-answered refusal: definite, so the reservation is released and no call is issued
local settled = reconciled({ request_id = 'r1', ok = false, tool_call_issued = true, outcome = 'unknown',
  error = "mcp_rpc_error:-32002:IMAP account 'default' is not configured" }, { request_id = 'r1' })
eq(settled.released, true, 'a retained server refusal reconciles the marker')
eq(settled.reason, 'server_error', 'and it says what settled it')
eq(#deletes, 1, 'exactly one marker is deleted, never a request')
eq(issued, 0, 'reconciling issues no call')

-- a complete result is not enough: its sha256 was in the reply nobody has
eq(reconciled({ request_id = 'r1', ok = true, tool_call_issued = true, outcome = 'unknown',
  result_json = '{"mailboxes":[]}', schema_hash = 'h1' }, { request_id = 'r1' }).released, false,
  'a complete retained result keeps the marker (its reply was never verified)')
eq(reconciled({ request_id = 'r1', ok = true, tool_call_issued = true, outcome = 'unknown',
  result_json = '{"mailboxes":[]}', schema_hash = 'h1' }, { request_id = 'r1' }).reason, 'needs_the_lost_reply',
  'and names the reason')

-- no evidence, or evidence about another request, keeps the marker
local none = reconciled(nil, { request_id = 'r1' })
eq(none.released, false, 'no retained answer keeps the marker')
eq(none.reason, 'no_retained_answer', 'and says so')
eq(reconciled({ request_id = 'other', ok = false, outcome = 'not_submitted', tool_call_issued = false },
  { request_id = 'r1' }).reason, 'evidence_not_this_request', 'an answer to another request settles nothing')
eq(reconciled({ request_id = 'r1', ok = false, outcome = 'not_submitted', tool_call_issued = false },
  { request_id = 'r2' }).reason, 'evidence_not_this_request', 'a request file that disagrees is refused')

-- a submission that was never issued is definite too
local never = reconciled({ request_id = 'r1', ok = false, outcome = 'not_submitted', tool_call_issued = false },
  { request_id = 'r1' })
eq(never.released, true, 'a not_submitted record reconciles the marker')
eq(never.reason, 'not_submitted', 'with its own reason')

-- a release that is not durable leaves the marker refusing
host.sql_exec = function() return json.encode({ ok = true, changes = 0 }) end
with_evidence({ request_id = 'r1', ok = false, tool_call_issued = true, outcome = 'unknown',
  error = 'mcp_rpc_error:-32002:nope' }, { request_id = 'r1' })
eq(session.reconcile('mcp.read_uncertain.v1:key', '/mcp/requests/r1.json', 'h1').reason, 'reconcile_not_durable',
  'a delete that changed no row is not a release')
host.read_file, host.sql_exec = real_read_file, real_sql_exec
host.http, host.operation = real_http, real_operation

print('test-mcp-session-settlement: '..checks..' checks passed')
