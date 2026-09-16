-- Memory: explicit memories + append-only ledger, all in Lua over host.sqlite.
-- The ledger is source of truth; *_fts is an index; the model never rewrites it.
local json = dofile("lua/vendor/json.lua")
local M = {}

local function decode(raw)
  if type(raw) == "string" then
    local ok, value = pcall(json.decode, raw)
    if ok then raw = value end
  end
  return raw
end

local function check(result)
  if type(result) == "table" and result.error then
    error(result.error, 2)
  end
  return result
end

local function query(sql, params)
  return check(decode(host.sql_query(sql, json.encode(params or {}))))
end

local function exec(sql, params)
  return check(decode(host.sql_exec(sql, json.encode(params or {}))))
end

-- Turn free text into a safe FTS5 AND-of-quoted-terms query.
function M.fts_query(text)
  local terms = {}
  for term in tostring(text or ""):gmatch("[%w_]+") do
    terms[#terms + 1] = '"' .. term .. '"'
  end
  return table.concat(terms, " AND ")
end

local function has_column(table, column)
  for _, row in ipairs(query("PRAGMA table_info(" .. table .. ")")) do
    if row.name == column then return true end
  end
  return false
end

local function add_column(table, column, declaration)
  if not has_column(table, column) then
    exec("ALTER TABLE " .. table .. " ADD COLUMN " .. column .. " " .. declaration)
  end
end

-- Sessions become resumable threads: who, where, how verbose, and the
-- compaction watermark.
local function migrate()
  add_column("sessions", "user_id", "TEXT NOT NULL DEFAULT 'master'")
  add_column("sessions", "node_id", "TEXT NOT NULL DEFAULT ''")
  add_column("sessions", "title", "TEXT NOT NULL DEFAULT ''")
  add_column("sessions", "mode", "TEXT NOT NULL DEFAULT 'default'")
  add_column("sessions", "summary", "TEXT NOT NULL DEFAULT ''")
  add_column("sessions", "summarized_until", "INTEGER NOT NULL DEFAULT 0")
  add_column("sessions", "updated_at", "REAL NOT NULL DEFAULT 0")
  exec("UPDATE sessions SET updated_at=started_at WHERE updated_at=0")
end

function M.setup()
  local schema = (EMBEDDED and EMBEDDED["lua/core/schema.sql"]) or host.read_file("lua/core/schema.sql")
  if not schema then error("schema_missing") end
  exec(schema)
  migrate()
end

-- ---------------------------------------------------------------- memories

function M.remember(content, scope, tags)
  content = tostring(content or "")
  if content == "" then error("memory_empty") end
  if #content > 8000 then error("memory_too_large") end
  scope = scope or "global"
  tags = tags or {}
  local hash = host.sha256(content)
  local existing = query(
    "SELECT id FROM memories WHERE scope=? AND content_sha256=? AND deleted_at IS NULL LIMIT 1",
    {scope, hash})
  if #existing > 0 then return existing[1].id end
  local id = host.uuid()
  local now = host.now()
  exec("INSERT INTO memories(id,scope,content,tags,source,session_id,created_at,updated_at,content_sha256) " ..
       "VALUES(?,?,?,?,?,?,?,?,?)",
       {id, scope, content, json.encode(tags), "user", "", now, now, hash})
  exec("INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
       {content, table.concat(tags, " "), id})
  return id
end

function M.recall(text, limit, scope)
  limit = limit or 10
  local match = M.fts_query(text)
  if match == "" then return {} end
  local sql = "SELECT m.id,m.scope,m.content,m.tags,m.source,m.created_at,m.updated_at," ..
              "bm25(memories_fts) AS rank FROM memories_fts " ..
              "JOIN memories m ON m.id=memories_fts.memory_id " ..
              "WHERE memories_fts MATCH ? AND m.deleted_at IS NULL"
  local params = {match}
  if scope then
    sql = sql .. " AND (m.scope=? OR m.scope='global')"
    params[#params + 1] = scope
  end
  sql = sql .. " ORDER BY rank LIMIT ?"
  params[#params + 1] = limit
  local rows = query(sql, params)
  for _, row in ipairs(rows) do row.tags = json.decode(row.tags) end
  return rows
end

function M.memories(scope, limit)
  limit = limit or 50
  local sql = "SELECT id,scope,content,tags,source,created_at,updated_at FROM memories WHERE deleted_at IS NULL"
  local params = {}
  if scope then sql = sql .. " AND scope=?"; params[#params + 1] = scope end
  sql = sql .. " ORDER BY updated_at DESC LIMIT ?"
  params[#params + 1] = limit
  local rows = query(sql, params)
  for _, row in ipairs(rows) do row.tags = json.decode(row.tags) end
  return rows
end

function M.forget(memory_id)
  local result = exec("UPDATE memories SET deleted_at=?, updated_at=? WHERE id=? AND deleted_at IS NULL",
                      {host.now(), host.now(), memory_id})
  if (result.changes or 0) > 0 then
    exec("DELETE FROM memories_fts WHERE memory_id=?", {memory_id})
  end
  return (result.changes or 0) > 0
end

-- ------------------------------------------------------------------ ledger

function M.ingest_observation(source, payload, device_id)
  local raw = type(payload) == "string" and payload or json.encode(payload)
  local hash = host.sha256(raw)
  exec("INSERT OR IGNORE INTO observations(id,source,device_id,observed_at,payload_sha256,payload,ingested_at) " ..
       "VALUES(?,?,?,?,?,?,?)",
       {hash, source or "unknown", device_id or "", host.now(), hash, raw, host.now()})
  return hash
end

function M.record_message(message)
  local conversation_id = tostring(message.conversation_id or "")
  local message_id = tostring(message.message_id or "")
  if conversation_id == "" or message_id == "" then error("message_identity_required") end
  local body = tostring(message.body or "")
  local now = message.observed_at or host.now()
  exec("INSERT INTO conversations(id,kind,title,created_at,updated_at) VALUES(?,?,?,?,?) " ..
       "ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at",
       {conversation_id, message.kind or "unknown", message.title or "", now, now})
  local existing = query("SELECT body_sha256 FROM messages WHERE conversation_id=? AND message_id=?",
                         {conversation_id, message_id})
  local hash = host.sha256(body)
  if #existing == 0 then
    exec("INSERT INTO messages(conversation_id,message_id,sender_id,direction,sent_at,observed_at," ..
         "body,reply_to,media,source,body_sha256) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
         {conversation_id, message_id, message.sender_id or "", message.direction or "incoming",
          message.sent_at, now, body, message.reply_to, json.encode(message.media or {}),
          message.source or "observer", hash})
    exec("INSERT INTO messages_fts(body,conversation_id,message_id) VALUES(?,?,?)",
         {body, conversation_id, message_id})
  elseif existing[1].body_sha256 ~= hash then
    exec("UPDATE messages SET body=?, body_sha256=?, sender_id=?, direction=?, " ..
         "sent_at=COALESCE(?,sent_at), observed_at=?, reply_to=COALESCE(?,reply_to), media=?, source=? " ..
         "WHERE conversation_id=? AND message_id=?",
         {body, hash, message.sender_id or "", message.direction or "incoming", message.sent_at, now,
          message.reply_to, json.encode(message.media or {}), message.source or "observer",
          conversation_id, message_id})
    exec("DELETE FROM messages_fts WHERE conversation_id=? AND message_id=?",
         {conversation_id, message_id})
    exec("INSERT INTO messages_fts(body,conversation_id,message_id) VALUES(?,?,?)",
         {body, conversation_id, message_id})
  end
end

function M.search_messages(text, conversation_id, limit)
  limit = limit or 20
  local match = M.fts_query(text)
  if match == "" then return {} end
  local sql = "SELECT msg.*, bm25(messages_fts) AS rank FROM messages_fts " ..
              "JOIN messages msg ON msg.conversation_id=messages_fts.conversation_id " ..
              "AND msg.message_id=messages_fts.message_id WHERE messages_fts MATCH ?"
  local params = {match}
  if conversation_id then sql = sql .. " AND msg.conversation_id=?"; params[#params + 1] = conversation_id end
  sql = sql .. " ORDER BY rank LIMIT ?"
  params[#params + 1] = limit
  return query(sql, params)
end

function M.conversation(conversation_id, limit)
  limit = limit or 50
  local rows = query("SELECT * FROM messages WHERE conversation_id=? " ..
                     "ORDER BY COALESCE(sent_at,observed_at) DESC LIMIT ?", {conversation_id, limit})
  local out = {}
  for index = #rows, 1, -1 do out[#out + 1] = rows[index] end
  return out
end

function M.conversations(limit)
  limit = limit or 50
  return query("SELECT c.*, (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id) AS message_count " ..
               "FROM conversations c ORDER BY c.updated_at DESC LIMIT ?", {limit})
end

function M.stats()
  local function count(sql)
    local rows = query(sql)
    return rows[1] and rows[1]["COUNT(*)"] or 0
  end
  return {
    memories = count("SELECT COUNT(*) FROM memories WHERE deleted_at IS NULL"),
    conversations = count("SELECT COUNT(*) FROM conversations"),
    messages = count("SELECT COUNT(*) FROM messages"),
    observations = count("SELECT COUNT(*) FROM observations"),
    sessions = count("SELECT COUNT(*) FROM sessions"),
    turns = count("SELECT COUNT(*) FROM turns"),
    runs = count("SELECT COUNT(*) FROM runs"),
  }
end

-- ---------------------------------------------------------------- sessions
-- A session is a resumable thread. `mode` is 'default' (compacted: user,
-- assistant and one-line tool traces, pruned after N days) or 'debug' (everything
-- verbatim, kept forever) so a failing task can be reproduced and turned into a
-- fixture.

function M.start_session(route_id, objective, opts)
  opts = opts or {}
  local id = host.uuid()
  local now = host.now()
  exec("INSERT INTO sessions(id,route_id,objective,started_at,user_id,node_id,title,mode,updated_at) " ..
       "VALUES(?,?,?,?,?,?,?,?,?)",
       {id, route_id or "", objective or "", now, opts.user_id or "master",
        opts.node_id or "", opts.title or objective or "", opts.mode or "default", now})
  return id
end

-- Reuse the newest open session for this (user, node) pair, or start one.
function M.ensure_session(user_id, node_id, title)
  user_id = user_id or "master"
  node_id = node_id or ""
  local rows = query(
    "SELECT id FROM sessions WHERE user_id=? AND node_id=? AND ended_at IS NULL " ..
    "ORDER BY started_at DESC LIMIT 1", {user_id, node_id})
  if #rows > 0 then return rows[1].id end
  return M.start_session(node_id, title or "chat", { user_id = user_id, node_id = node_id, title = title or "chat" })
end

function M.session(session_id)
  local rows = query("SELECT * FROM sessions WHERE id=?", {session_id})
  return rows[1]
end

function M.list_sessions(user_id, limit)
  limit = limit or 30
  local sql = "SELECT s.*, (SELECT COUNT(*) FROM turns t WHERE t.session_id=s.id) AS turn_count " ..
              "FROM sessions s"
  local params = {}
  if user_id and user_id ~= "" then sql = sql .. " WHERE s.user_id=?"; params[#params + 1] = user_id end
  sql = sql .. " ORDER BY s.updated_at DESC LIMIT ?"
  params[#params + 1] = limit
  return query(sql, params)
end

function M.set_session_mode(session_id, mode)
  mode = (mode == "debug") and "debug" or "default"
  exec("UPDATE sessions SET mode=?, updated_at=? WHERE id=?", {mode, host.now(), session_id})
  return mode
end

function M.set_session_summary(session_id, until_seq, summary)
  exec("UPDATE sessions SET summarized_until=?, summary=?, updated_at=? WHERE id=?",
       {until_seq, summary or "", host.now(), session_id})
end

function M.finish_session(session_id)
  exec("UPDATE sessions SET ended_at=?, updated_at=? WHERE id=? AND ended_at IS NULL",
       {host.now(), host.now(), session_id})
end

-- ------------------------------------------------------------------- turns

function M.next_seq(session_id)
  local rows = query("SELECT COALESCE(MAX(seq),0)+1 AS seq FROM turns WHERE session_id=?", {session_id})
  return rows[1] and rows[1].seq or 1
end

function M.append_turn(session_id, turn)
  local seq = turn.seq or M.next_seq(session_id)
  local id = turn.id or host.uuid()
  exec("INSERT INTO turns(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name," ..
       "tokens,ms,ok,debug,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
       {id, session_id, seq, turn.role or "user", turn.content or "",
        json.encode(turn.tool_calls or {}), turn.tool_call_id or "", turn.tool_name or "",
        turn.tokens or 0, turn.ms or 0, turn.ok == false and 0 or 1,
        turn.debug and 1 or 0, json.encode(turn.trace or {}), host.now()})
  exec("INSERT INTO turns_fts(content,session_id,turn_id) VALUES(?,?,?)",
       {turn.content or "", session_id, id})
  exec("UPDATE sessions SET updated_at=? WHERE id=?", {host.now(), session_id})
  return seq
end

function M.session_turns(session_id, opts)
  opts = opts or {}
  local sql = "SELECT * FROM turns WHERE session_id=?"
  local params = {session_id}
  if opts.after_seq then sql = sql .. " AND seq>?"; params[#params + 1] = opts.after_seq end
  sql = sql .. " ORDER BY seq ASC LIMIT ?"
  params[#params + 1] = opts.limit or 200
  local rows = query(sql, params)
  for _, row in ipairs(rows) do
    row.tool_calls = json.decode(row.tool_calls)
    row.trace = json.decode(row.trace)
  end
  return rows
end

function M.search_turns(text, user_id, limit)
  limit = limit or 20
  local match = M.fts_query(text)
  if match == "" then return {} end
  local sql = "SELECT t.*, s.user_id, s.title, bm25(turns_fts) AS rank FROM turns_fts " ..
              "JOIN turns t ON t.id=turns_fts.turn_id JOIN sessions s ON s.id=t.session_id " ..
              "WHERE turns_fts MATCH ?"
  local params = {match}
  if user_id and user_id ~= "" then sql = sql .. " AND s.user_id=?"; params[#params + 1] = user_id end
  sql = sql .. " ORDER BY rank LIMIT ?"
  params[#params + 1] = limit
  return query(sql, params)
end

-- Retention: default sessions keep 100% of traces for 7 days; debug sessions
-- are kept forever (they are the fixtures we evolve from).
function M.prune(days)
  days = days or 7
  local cutoff = host.now() - (days * 86400)
  local result = exec(
    "DELETE FROM turns WHERE created_at < ? AND session_id IN " ..
    "(SELECT id FROM sessions WHERE mode <> 'debug')", {cutoff})
  exec("DELETE FROM turns_fts WHERE turn_id NOT IN (SELECT id FROM turns)")
  return result.changes or 0
end

-- A fixture: everything needed to reproduce a session, for regression tests.
function M.session_fixture(session_id)
  local session = M.session(session_id)
  if not session then return nil end
  return {
    schema = "wasm-agent.session_fixture.v1",
    session = session,
    turns = M.session_turns(session_id, { limit = 10000 }),
  }
end

function M.record_run(run_id, session_id, status, outcome, reply)
  exec("INSERT INTO runs(id,session_id,turn_id,status,outcome,reply,started_at) VALUES(?,?,?,?,?,?,?) " ..
       "ON CONFLICT(id) DO UPDATE SET status=excluded.status, outcome=excluded.outcome, reply=excluded.reply",
       {run_id, session_id, run_id, status or "", outcome or "", reply or "", host.now()})
end

return M
