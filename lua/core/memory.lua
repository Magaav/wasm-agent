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

function M.setup()
  local schema = host.read_file("lua/core/schema.sql")
  if not schema then error("schema_missing") end
  exec(schema)
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
    runs = count("SELECT COUNT(*) FROM runs"),
  }
end

-- ---------------------------------------------------------------- sessions

function M.start_session(route_id, objective)
  local id = host.uuid()
  exec("INSERT INTO sessions(id,route_id,objective,started_at) VALUES(?,?,?,?)",
       {id, route_id or "", objective or "", host.now()})
  return id
end

function M.finish_session(session_id)
  exec("UPDATE sessions SET ended_at=? WHERE id=? AND ended_at IS NULL", {host.now(), session_id})
end

function M.record_run(run_id, session_id, status, outcome, reply)
  exec("INSERT INTO runs(id,session_id,turn_id,status,outcome,reply,started_at) VALUES(?,?,?,?,?,?,?) " ..
       "ON CONFLICT(id) DO UPDATE SET status=excluded.status, outcome=excluded.outcome, reply=excluded.reply",
       {run_id, session_id, run_id, status or "", outcome or "", reply or "", host.now()})
end

return M
