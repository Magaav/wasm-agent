-- Memory: explicit memories + append-only ledger, all in Lua over host.sqlite.
-- The ledger is source of truth; *_fts is an index; the model never rewrites it.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
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
-- Terms for an FTS5 MATCH expression, each quoted so that arbitrary user text
-- cannot be read as FTS syntax, and deduplicated so a repeated word does not
-- skew the ranking.
local function fts_terms(text)
  local terms, seen = {}, {}
  for term in tostring(text or ""):gmatch("[%w_]+") do
    local key = term:lower()
    if not seen[key] then
      seen[key] = true
      terms[#terms + 1] = '"' .. term .. '"'
    end
  end
  return terms
end

function M.fts_query(text)
  return table.concat(fts_terms(text), " AND ")
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

-- Interruption classification. Declared here because `list_sessions` reports a
-- session's state and is defined earlier in the file than the section those
-- helpers belong to; an earlier function body cannot see a `local` declared
-- below it, it would resolve to a global and be nil at call time.
local decode_calls, classify, ago, detail_of

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
  -- Interruptions: a thread that was cut off mid-answer (see the section on
  -- derived state below). A hard kill cannot write these - that is the point of
  -- deriving the *current* state from the ledger - but the *history* has to be
  -- written down somewhere, or resuming the thread would erase the only trace
  -- that anything went wrong.
  add_column("sessions", "interrupted_at", "REAL")
  add_column("sessions", "interrupted_seq", "INTEGER NOT NULL DEFAULT 0")
  add_column("sessions", "interrupted_reason", "TEXT NOT NULL DEFAULT ''")
  add_column("sessions", "interrupted_count", "INTEGER NOT NULL DEFAULT 0")
  -- Images attached to a user turn. A JSON array of
  -- {mime, sha256, name, bytes}; the bytes live on disk as base64 under
  -- attachments/ (content-addressed by sha256), never in `content`. Content is
  -- FTS-indexed, so putting base64 there would poison every text search and
  -- bloat the index by three orders of magnitude.
  add_column("turns", "images", "TEXT NOT NULL DEFAULT '[]'")
  -- What the turn changed on disk: a JSON summary of {files:[{path,added,removed,...}],
  -- added, removed}, so the diff topic can be rebuilt from the ledger alone. The *bodies*
  -- (the previous text undo restores) are not here and must not be: this column is read
  -- into every transcript view, and a file's contents do not belong in a transcript any
  -- more than base64 images do. An older turn's `{}` means "nothing recorded", which
  -- reads as no topic rather than an empty one.
  add_column("turns", "changes", "TEXT NOT NULL DEFAULT '{}'")
  -- Rows written before the state was renamed kept the wording of the claim we used to
  -- make: "died after a tool result", "died right after a compaction". Nobody observed
  -- those deaths - a live run was reported as interrupted fourteen times in a row - so
  -- the stored detail is corrected rather than preserved. The facts (seq, time, count)
  -- are in their own columns and are untouched. Idempotent: a second run matches nothing.
  exec("UPDATE sessions SET interrupted_reason = replace(interrupted_reason, 'died after a tool result', 'stopped after a tool result') WHERE interrupted_reason LIKE '%died after a tool result%'")
  exec("UPDATE sessions SET interrupted_reason = replace(interrupted_reason, 'died right after a compaction', 'stopped right after a compaction') WHERE interrupted_reason LIKE '%died right after a compaction%'")
  exec("UPDATE sessions SET interrupted_reason = replace(interrupted_reason, 'died after a decision', 'stopped after a decision') WHERE interrupted_reason LIKE '%died after a decision%'")
end

function M.setup()
  local schema = (EMBEDDED and EMBEDDED["lua/core/schema.sql"]) or host.read_file("lua/core/schema.sql")
  if not schema then error("schema_missing") end
  exec(schema)
  migrate()
  -- Threads that predate naming are all called "chat", which tells the reader nothing and makes a
  -- list of them unusable. Name them from their first user message, once: after this the name
  -- belongs to the thread, and only a thread without one gets named again.
  for _, row in ipairs(query("SELECT id FROM sessions WHERE title='' OR title='chat'")) do
    local first = query("SELECT content FROM turns WHERE session_id=? AND role='user' ORDER BY seq ASC LIMIT 1", {row.id})
    if first[1] then M.name_session(row.id, first[1].content or "") end
  end
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
  M.journal("memory", id, {
    id = id, scope = scope, content = content, tags = tags, source = "user",
    created_at = now, updated_at = now, content_sha256 = hash,
  })
  return id
end

local function query_memories(match, limit, scope)
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

-- Recall is searched twice on purpose. All terms present is the precise case
-- (a query naming a fact), so it is tried first. A conversational question -
-- "what did I ask you to remember?" - shares no complete term set with the note
-- it is about, so requiring every term returns nothing, and returning nothing
-- here is what made the agent tell the user the memory store was empty while the
-- fact was sitting in it. The second pass matches any term and lets bm25 rank.
function M.recall(text, limit, scope)
  limit = limit or 10
  local terms = fts_terms(text)
  if #terms == 0 then return {} end
  local rows = query_memories(table.concat(terms, " AND "), limit, scope)
  if #rows == 0 and #terms > 1 then
    rows = query_memories(table.concat(terms, " OR "), limit, scope)
  end
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
  M.journal("session", id, M.session(id))
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

-- The most recently used session for this (user, node) pair, open or finished.
-- `wa chat --continue` resumes the thread the user was last in: a session ends
-- when its process exits, so filtering to open ones would never find anything.
function M.latest_session(user_id, node_id)
  local rows = query(
    "SELECT * FROM sessions WHERE user_id=? AND node_id=? " ..
    "ORDER BY updated_at DESC, started_at DESC LIMIT 1",
    { user_id or "master", node_id or "" })
  return rows[1]
end

-- `opts.states` adds each session's derived state (see "interruptions" below) to
-- the row: the engine view lists threads, and a thread that died mid-answer must
-- be distinguishable from a settled one without opening it.
function M.list_sessions(user_id, limit, opts)
  opts = opts or {}
  limit = limit or 30
  local sql = "SELECT s.*, (SELECT COUNT(*) FROM turns t WHERE t.session_id=s.id) AS turn_count"
  if opts.states then
    -- The last turn per session, in the same query: one row per thread, no N+1.
    sql = sql .. ", l.role AS last_role, l.ok AS last_ok, l.tool_calls AS last_tool_calls, " ..
                "l.created_at AS last_at, l.seq AS last_seq"
  end
  sql = sql .. " FROM sessions s"
  if opts.states then
    sql = sql .. " LEFT JOIN turns l ON l.session_id=s.id " ..
                 "AND l.seq=(SELECT MAX(seq) FROM turns WHERE session_id=s.id)"
  end
  local params = {}
  if user_id and user_id ~= "" then sql = sql .. " WHERE s.user_id=?"; params[#params + 1] = user_id end
  sql = sql .. " ORDER BY s.updated_at DESC LIMIT ?"
  params[#params + 1] = limit
  local rows = query(sql, params)
  if opts.states then
    for _, row in ipairs(rows) do
      local last = row.last_seq and { role = row.last_role, ok = row.last_ok,
        tool_calls = row.last_tool_calls, created_at = row.last_at } or nil
      row.state = classify(last)
      row.state_detail = detail_of(row.state, last, nil)
    end
  end
  return rows
end

function M.set_session_mode(session_id, mode)
  mode = (mode == "debug") and "debug" or "default"
  exec("UPDATE sessions SET mode=?, updated_at=? WHERE id=?", {mode, host.now(), session_id})
  M.journal("session", session_id, M.session(session_id))
  return mode
end

function M.set_session_summary(session_id, until_seq, summary)
  exec("UPDATE sessions SET summarized_until=?, summary=?, updated_at=? WHERE id=?",
       {until_seq, summary or "", host.now(), session_id})
  M.journal("session", session_id, M.session(session_id))
end

function M.finish_session(session_id)
  exec("UPDATE sessions SET ended_at=?, updated_at=? WHERE id=? AND ended_at IS NULL",
       {host.now(), host.now(), session_id})
  M.journal("session", session_id, M.session(session_id))
end

-- ------------------------------------------------------------------- turns

local cached_origin = nil
local function origin()
  if cached_origin == nil then
    local ok, raw = pcall(host.node_identity)
    local identity = ok and raw and json.decode(raw) or nil
    cached_origin = (identity and identity.node_id) or ""
  end
  return cached_origin
end

-- Append a mutation to the replication journal. Every write that should reach
-- peers goes through here; applying a remote entry does NOT journal it again.
function M.journal(kind, entity_id, payload)
  exec("INSERT INTO journal(kind,entity_id,op,origin,payload,created_at) VALUES(?,?,?,?,?,?)",
       {kind, entity_id, "upsert", origin(), json.encode(payload), host.now()})
end

-- -------------------------------------------------------------------- images
-- Attached images live on disk, content-addressed by sha256, and are referenced
-- from a turn by identity. Three reasons it is a file and not a column:
--   1. `turns.content` is FTS-indexed; base64 there would poison every search.
--   2. The same screenshot pasted twice is stored once.
--   3. The path is stable, so replays and fixtures can resolve it.
--
-- The bytes are stored base64 *as text*, because the host's read_file/write_file
-- are UTF-8 text only (rust/wa-host/src/host.rs). Encoding is therefore part of
-- the on-disk format, not an implementation detail to change casually.

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64_decode(text)
  if type(text) ~= "string" or text == "" then return "" end
  text = text:gsub("%s", ""):gsub("=+$", "")
  local out, buffer, bits = {}, 0, 0
  for i = 1, #text do
    local char = text:sub(i, i)
    local value = BASE64_ALPHABET:find(char, 1, true)
    if value then
      buffer = buffer * 64 + (value - 1)
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        -- Take the top byte and *discard* the bits it used. Keeping them would
        -- let `buffer` grow without bound: past ~13 symbols it exceeds the
        -- exact-integer range, and every later byte is silently wrong (the
        -- length stays correct, so only a byte comparison catches it).
        out[#out + 1] = string.char(math.floor(buffer / (2 ^ bits)) % 256)
        buffer = buffer % (2 ^ bits)
      end
    end
  end
  return table.concat(out)
end

function M.base64_encode(bytes)
  if type(bytes) ~= "string" or bytes == "" then return "" end
  local out = {}
  local function symbol(index) return BASE64_ALPHABET:sub(index + 1, index + 1) end
  for i = 1, #bytes, 3 do
    local remaining = #bytes - i + 1
    local a, b, c = bytes:byte(i), bytes:byte(i + 1), bytes:byte(i + 2)
    -- Pad the group to three bytes of bits, then take four 6-bit symbols. The
    -- final group's spare symbols become '='; taking them from a zeroed byte
    -- would emit a real character and corrupt the output by length alone.
    out[#out + 1] = symbol(math.floor(a / 4))
    out[#out + 1] = symbol((a % 4) * 16 + math.floor((b or 0) / 16))
    out[#out + 1] = remaining > 1 and symbol((b % 16) * 4 + math.floor((c or 0) / 64)) or "="
    out[#out + 1] = remaining > 2 and symbol(c % 64) or "="
  end
  return table.concat(out)
end

-- Extensions we accept, mapped to the mime types the provider will echo back.
-- The gateway itself accepts webp/png/jpeg/gif and rejects anything else, so the
-- check happens here rather than being discovered as a 400 mid-turn.
local IMAGE_TYPES = {
  ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/webp"] = "webp",
  ["image/gif"] = "gif",
}

function M.image_mime_supported(mime)
  return IMAGE_TYPES[tostring(mime or ""):lower()] ~= nil
end

-- Store an image and return the reference recorded on the turn.
-- A data URL or bare base64 is accepted; the sha256 is taken over the *decoded*
-- bytes so that the same picture in two encodings has one identity.
function M.store_image(entry)
  local raw = tostring(entry.data or entry.b64 or "")
  local mime = tostring(entry.mime or ""):lower()
  -- Strip a data URL envelope if one was supplied.
  local header, payload = raw:match("^data:([^;,]+);base64,(.*)$")
  if header then
    mime = header:lower()
    raw = payload
  end
  if not M.image_mime_supported(mime) then
    return nil, "unsupported_image_type: " .. (mime ~= "" and mime or "unknown")
  end
  local bytes = M.base64_decode(raw)
  if bytes == "" then return nil, "empty_image" end
  -- Hash the *base64 text*, never the decoded bytes.
  --
  -- host.sha256() reaches Lua through `CStr::from_ptr` (rust/wa-host/src/lua.rs),
  -- which stops at the first NUL. A PNG has a NUL at byte 9 of 70, so hashing
  -- the decoded binary hashed an 8-byte prefix: a silent, truncated content
  -- address, where two different images sharing a head would collide. The
  -- encoded form is ASCII by construction, so it hashes in full, and it is also
  -- exactly what we write to disk - so identity and stored bytes agree.
  local encoded_bytes = M.base64_encode(bytes)
  local digest = host.sha256(encoded_bytes)
  local extension = IMAGE_TYPES[mime]
  local directory = paths.data() .. "/attachments/" .. digest:sub(1, 2)
  local path = directory .. "/" .. digest .. "." .. extension
  -- Content-addressed: identical bytes already on disk are already correct.
  if not (host.read_file and host.read_file(path)) then
    local ok = host.write_file and host.write_file(path, encoded_bytes)
    if not ok then return nil, "attachment_write_failed: " .. path end
  end
  return {
    mime = mime,
    sha256 = digest,
    path = path,
    name = tostring(entry.name or (digest:sub(1, 8) .. "." .. extension)),
    bytes = #bytes,
  }
end

-- Read an image back for a provider request: {mime, b64, path, missing}.
function M.load_image(reference)
  local mime = tostring(reference.mime or "image/png")
  local path = tostring(reference.path or "")
  if path == "" and reference.sha256 then
    local extension = IMAGE_TYPES[mime] or "png"
    path = paths.data() .. "/attachments/" .. reference.sha256:sub(1, 2)
      .. "/" .. reference.sha256 .. "." .. extension
  end
  local text = host.read_file and host.read_file(path)
  if not text or text == "" then
    return { mime = mime, path = path, missing = true }
  end
  -- Stored already base64; hand it back as-is so a replay does not re-encode.
  return { mime = mime, path = path, b64 = text }
end

function M.next_seq(session_id)
  local rows = query("SELECT COALESCE(MAX(seq),0)+1 AS seq FROM turns WHERE session_id=?", {session_id})
  return rows[1] and rows[1].seq or 1
end

function M.append_turn(session_id, turn)
  local seq = turn.seq or M.next_seq(session_id)
  local id = turn.id or host.uuid()
  exec("INSERT INTO turns(id,session_id,seq,role,content,images,tool_calls,tool_call_id,tool_name," ..
       "tokens,ms,ok,debug,trace,changes,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
       {id, session_id, seq, turn.role or "user", turn.content or "",
        json.encode(turn.images or {}),
        json.encode(turn.tool_calls or {}), turn.tool_call_id or "", turn.tool_name or "",
        turn.tokens or 0, turn.ms or 0, turn.ok == false and 0 or 1,
        turn.debug and 1 or 0, json.encode(turn.trace or {}),
        json.encode(turn.changes or {}), host.now()})
  exec("INSERT INTO turns_fts(content,session_id,turn_id) VALUES(?,?,?)",
       {turn.content or "", session_id, id})
  exec("UPDATE sessions SET updated_at=? WHERE id=?", {host.now(), session_id})
  M.journal("turn", id, {
    id = id, session_id = session_id, seq = seq, role = turn.role or "user",
    content = turn.content or "", images = turn.images or {}, tool_calls = turn.tool_calls or {},
    tool_call_id = turn.tool_call_id or "", tool_name = turn.tool_name or "",
    tokens = turn.tokens or 0, ms = turn.ms or 0,
    ok = turn.ok == false and 0 or 1, debug = turn.debug and 1 or 0,
    trace = turn.trace or {}, created_at = host.now(),
  })
  -- A thread is named after the first thing asked in it, the way a chat is named after its opening
  -- message. Set once and never rewritten: a name that drifts as the conversation moves is worse
  -- than no name, because the reader cannot use it to find the thread they remember.
  if (turn.role or "user") == "user" then M.name_session(session_id, turn.content or "") end
  return seq
end

-- A name has to survive being read in a list and typed into a search box: one line, no markdown
-- furniture, and short. The first line, not the first sentence: a name that ends mid-thought reads
-- as a different name, and picking a sentence boundary needs punctuation rules nobody agrees on.
local function title_from(text)
  local first = tostring(text or ""):gsub("\r", ""):match("^[^\n]*") or ""
  local line = first:gsub("```[%s%S]-```", " ")
  line = line:gsub("[#*_`>|]+", " ")
  line = line:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  -- Removing a backtick leaves a space where it was, and "chat ?" is not how anyone writes it.
  line = line:gsub("%s+([%?%.,:;!%%%)%]}])", "%1"):gsub("%s+$", "")
  if line == "" then return "" end
  if #line > 60 then
    local cut = line:sub(1, 60)
    local space = cut:match("^.*()%s")
    if space and space > 30 then cut = cut:sub(1, space - 1) end
    line = cut .. "\u{2026}"
  end
  return line
end

-- Name a session from its first user message, unless it already has a name. "chat" is the
-- placeholder every session starts with, so it does not count as one.
function M.name_session(session_id, text)
  local rows = query("SELECT title FROM sessions WHERE id=?", {session_id})
  local current = tostring((rows[1] or {}).title or "")
  if current ~= "" and current ~= "chat" then return current end
  local title = title_from(text)
  if title == "" then return nil end
  exec("UPDATE sessions SET title=? WHERE id=?", {title, session_id})
  return title
end

-- Turns are read as a *window*, and the window is the newest ones. The old shape -
-- ORDER BY seq ASC LIMIT ? - returned the oldest 200 of a 367-turn thread and said
-- nothing about it, so a reader looking for the end of a run got its opening moves,
-- and a model asking about a long session's state got its ancient history as if it
-- were current. Nobody wants the head of a window; they want the tail.
--
-- `limit` bounds the window and `after_seq` moves its start. To know whether rows
-- were dropped, compare with M.turn_count(session_id) - the tool that shows a session
-- to the model says so in words, because a silent truncation is a memory bug.
function M.session_turns(session_id, opts)
  opts = opts or {}
  local limit = opts.limit or 200
  local sql, params
  if opts.after_seq then
    sql = "SELECT * FROM (SELECT * FROM turns WHERE session_id=? AND seq>? " ..
      "ORDER BY seq DESC LIMIT ?) ORDER BY seq ASC"
    params = {session_id, opts.after_seq, limit}
  else
    sql = "SELECT * FROM (SELECT * FROM turns WHERE session_id=? " ..
      "ORDER BY seq DESC LIMIT ?) ORDER BY seq ASC"
    params = {session_id, limit}
  end
  local rows = query(sql, params)
  for _, row in ipairs(rows) do
    row.tool_calls = json.decode(row.tool_calls)
    row.trace = json.decode(row.trace)
    if row.images then row.images = decode(row.images) end
    -- An older row has `{}` rather than a summary, and `{}` decodes to an empty table
    -- that is truthy in Lua - so turn it into nil here. Otherwise every turn written
    -- before this column existed would claim a diff topic and render an empty one.
    row.changes = decode(row.changes)
    if type(row.changes) ~= "table" or row.changes.files == nil then row.changes = nil end
  end
  return rows
end

-- One turn, by id, with its `changes` decoded the same way session_turns decodes it.
--
-- Undo works from a turn id rather than from a position: the reader clicks a topic in the
-- transcript, and what identifies that topic has to survive a reload, a compaction and a
-- second reader. A sequence number would not - the window moves - and the id is what the
-- journal already replicates, so a peer's turn resolves here too.
function M.turn(turn_id)
  if not turn_id or turn_id == "" then return nil end
  local rows = query("SELECT * FROM turns WHERE id=?", {turn_id})
  local row = rows[1]
  if not row then return nil end
  row.tool_calls = json.decode(row.tool_calls)
  row.trace = json.decode(row.trace)
  if row.images then row.images = decode(row.images) end
  row.changes = decode(row.changes)
  if type(row.changes) ~= "table" or row.changes.files == nil then row.changes = nil end
  return row
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

-- ------------------------------------------------------------- interruptions
-- A thread that was cut off mid-answer looks exactly like a thread whose answer
-- is still coming: the transcript just ends. A killed process cannot write a flag
-- saying it died - the exit path that would set one does not run - so the state is
-- *derived* from the ledger instead, which is appended to as the turn proceeds.
-- The last turn is therefore an exact record of how far the process got:
--
--   empty        nothing was said yet
--   answered     last turn is a reply: the thread is settled
--   failed       last turn is an assistant turn with ok=0, i.e. the model call
--                errored. That is a landed outcome, not an interruption, and
--                conflating the two would send a reader looking for lost work
--                that was never started.
--   unfinished   last turn is a question, a tool result, or a decision whose tools
--                have no recorded result. The process that was working on it may
--                have stopped, or it may still be working - the ledger cannot tell
--                those apart, so nothing here claims a death.
--
-- This state was called `interrupted`, and the word cost real credibility: a live
-- 426-turn run was reported as interrupted on every poll while it was demonstrably
-- writing turns. A name that asserts something we cannot observe is a claim the code
-- should not make. The durable history (`mark_unfinished`) is the part that *is*
-- observable: a thread was picked up again after being left unfinished.
--
-- Derivations are cheap and always current, but they forget: once the thread is
-- resumed the tail is an answer again and nothing says the answer came after a stop.
-- So the first time an unfinished tail is *observed* it is also recorded on the
-- session - the interrupted_* columns keep their old names to avoid a migration,
-- and hold the count and reason of those observations.

function decode_calls(raw)
  if type(raw) == "string" then
    local ok, value = pcall(json.decode, raw)
    raw = ok and value or {}
  end
  return (type(raw) == "table") and raw or {}
end

function classify(last)
  if not last then return "empty" end
  if last.role == "assistant" then
    if last.ok == 0 or last.ok == false then return "failed" end
    if #decode_calls(last.tool_calls) > 0 then return "unfinished" end
    return "answered"
  end
  return "unfinished"
end

function ago(at)
  if not at then return "at an unknown time" end
  local seconds = math.floor(host.now() - at)
  if seconds < 0 then seconds = 0 end
  if seconds < 60 then return seconds .. "s ago" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "min ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end

-- `pending` is the names of the tool calls with no recorded result. When it is
-- not known (the listing, where checking every call would be one query per
-- session) all of the last turn's calls are named, and the wording says "tool
-- call(s) never reported" rather than claiming they never ran.
function detail_of(state, last, pending)
  if state == "empty" then return "no turns yet" end
  if state == "answered" then return "settled - the last turn is a reply" end
  if state == "failed" then return "the last turn failed (the model call errored)" end
  if not last then return "nothing is recorded after the last turn" end
  if last.role == "user" then return "an unanswered question, " .. ago(last.created_at) end
  if last.role == "summary" then return "stopped after a compaction, " .. ago(last.created_at) end
  if last.role == "assistant" then
    local names = pending
    if names == nil then
      names = {}
      for _, call in ipairs(decode_calls(last.tool_calls)) do
        names[#names + 1] = ((call["function"] or {}).name or "?")
      end
    end
    return string.format("%d tool call(s) with no recorded result: %s, %s",
      #names, #names > 0 and table.concat(names, ", ") or "unnamed", ago(last.created_at))
  end
  -- The tail is a tool result: something did report, so the interesting fact is
  -- which calls of that same decision did not.
  if pending and #pending > 0 then
    return string.format("stopped after a tool result; %d call(s) of that batch have no recorded result: %s, %s",
      #pending, table.concat(pending, ", "), ago(last.created_at))
  end
  return "stopped after a tool result with no next decision, " .. ago(last.created_at)
end

-- Which calls of the tail's own decision never reported a result. Returns the
-- pending names and how many calls the decision had (nil when there is no such
-- decision), because "1 of 2 never reported" and "1 of 1 never reported" are
-- different facts about the same tail.
--
-- The tail is not always the decision: a batched decision writes one turn per
-- call, so a process killed between two calls leaves a *tool* turn on top with
-- its sibling never run. That is the sharpest thing recovery can tell a reader -
-- which of the batch is missing - and it is only visible by looking the decision
-- up, not at the tail.
function M.pending_calls(session_id)
  local rows = query("SELECT tool_calls FROM turns WHERE session_id=? AND role='assistant' " ..
                     "AND tool_calls <> '[]' ORDER BY seq DESC LIMIT 1", {session_id})
  local decision = rows[1]
  if not decision then return nil, nil end
  local answered = {}
  for _, row in ipairs(query("SELECT tool_call_id FROM turns WHERE session_id=? AND role='tool'",
                             {session_id})) do
    answered[row.tool_call_id] = true
  end
  local calls, pending = decode_calls(decision.tool_calls), {}
  for _, call in ipairs(calls) do
    if not answered[call.id or ""] then
      pending[#pending + 1] = ((call["function"] or {}).name or "?")
    end
  end
  return pending, #calls
end

-- Facts about one thread's last turn: the state, where it stopped, and what was
-- left unfinished. Read-only - nothing here writes, so a report can never be the
-- thing that "fixes" what it reports.
function M.session_state(session_id)
  local session = M.session(session_id)
  if not session then return nil end
  local rows = query("SELECT * FROM turns WHERE session_id=? ORDER BY seq DESC LIMIT 1", {session_id})
  local last = rows[1]
  local state = classify(last)
  local pending = nil
  if state == "unfinished" and last and (last.role == "assistant" or last.role == "tool") then
    local total
    pending, total = M.pending_calls(session_id)
    -- A tool tail whose result matches none of the decision's calls: the ledger
    -- says a result arrived but not which call it answered, so the batch's state
    -- is unknown. Claiming "2 of 2 never reported" there would be a lie.
    if last.role == "tool" and pending and total and #pending == total then pending = nil end
  end
  return {
    session_id = session_id,
    title = session.title or "",
    state = state,
    seq = last and tonumber(last.seq) or 0,
    role = last and last.role or "",
    at = last and last.created_at or nil,
    pending = pending or {},
    question = (state == "unfinished" and last and last.role == "user") and (last.content or "") or "",
    detail = detail_of(state, last, pending),
    recorded_at = session.interrupted_at,
    recorded_seq = tonumber(session.interrupted_seq) or 0,
    recorded_reason = session.interrupted_reason or "",
    interruptions = tonumber(session.interrupted_count) or 0,
  }
end

function M.turn_count(session_id)
  local rows = query("SELECT COUNT(*) AS n FROM turns WHERE session_id=?", {session_id})
  return tonumber(rows[1] and rows[1].n) or 0
end

-- Write down that a thread was picked up while unfinished, once per point where
-- that happened. Re-running the detection for the same tail must not inflate the
-- count: an agent that resumes a thread three times picked it up once at that tail.
function M.mark_unfinished(session_id, opts)
  opts = opts or {}
  local session = M.session(session_id)
  if not session then return nil end
  local state = M.session_state(session_id)
  local seq = opts.seq or (state and state.seq) or 0
  if (tonumber(session.interrupted_seq) or 0) == seq and (session.interrupted_at or 0) > 0 then
    return nil
  end
  local reason = opts.reason or (state and state.detail) or "unfinished"
  exec("UPDATE sessions SET interrupted_at=?, interrupted_seq=?, interrupted_reason=?, " ..
       "interrupted_count=COALESCE(interrupted_count,0)+1 WHERE id=?",
       {host.now(), seq, reason, session_id})
  M.journal("session", session_id, M.session(session_id))
  return reason
end

-- Threads with no recorded answer, most recent first. This is what a user (or the
-- resumed agent) needs to see, and it is derived, so a process that stops without a
-- chance to say so shows up here without anyone running a command that could notice.
function M.unfinished(user_id, limit)
  local found = {}
  for _, row in ipairs(M.list_sessions(user_id, limit or 40, { states = true })) do
    if row.state == "unfinished" then
      local state = M.session_state(row.id)
      if state then
        state.turns = tonumber(row.turn_count) or 0
        found[#found + 1] = state
      end
    end
  end
  return found
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
  M.journal("run", run_id, {
    id = run_id, session_id = session_id, turn_id = run_id, status = status or "",
    outcome = outcome or "", reply = reply or "", started_at = host.now(),
  })
end

-- ---------------------------------------------------------------- replication

function M.journal_head()
  local rows = query("SELECT COALESCE(MAX(id),0) AS head FROM journal")
  return rows[1] and rows[1].head or 0
end

function M.journal_since(cursor, limit)
  local rows = query("SELECT * FROM journal WHERE id>? ORDER BY id ASC LIMIT ?",
                     {cursor or 0, limit or 200})
  for _, row in ipairs(rows) do row.payload = json.decode(row.payload) end
  return rows
end

function M.cursor(peer_id)
  local rows = query("SELECT cursor FROM sync_cursors WHERE peer_id=?", {peer_id})
  return rows[1] and rows[1].cursor or 0
end

function M.set_cursor(peer_id, cursor)
  exec("INSERT INTO sync_cursors(peer_id,cursor,updated_at) VALUES(?,?,?) " ..
       "ON CONFLICT(peer_id) DO UPDATE SET cursor=excluded.cursor, updated_at=excluded.updated_at",
       {peer_id, cursor, host.now()})
end

function M.sync_peers()
  return query("SELECT peer_id, cursor, updated_at FROM sync_cursors ORDER BY updated_at DESC")
end

-- Idempotent: safe to apply the same entry twice. Never journals what it applies.
function M.apply_entry(entry)
  local payload = entry.payload
  if type(payload) == "string" then
    local ok, decoded = pcall(json.decode, payload)
    if not ok then return false end
    payload = decoded
  end
  if type(payload) ~= "table" then return false end

  if entry.kind == "turn" then
    exec("INSERT OR REPLACE INTO turns(id,session_id,seq,role,content,tool_calls,tool_call_id," ..
         "tool_name,tokens,ms,ok,debug,trace,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
         {payload.id, payload.session_id, payload.seq, payload.role, payload.content or "",
          json.encode(payload.tool_calls or {}), payload.tool_call_id or "", payload.tool_name or "",
          payload.tokens or 0, payload.ms or 0, payload.ok or 1, payload.debug or 0,
          json.encode(payload.trace or {}), payload.created_at or host.now()})
    exec("DELETE FROM turns_fts WHERE turn_id=?", {payload.id})
    exec("INSERT INTO turns_fts(content,session_id,turn_id) VALUES(?,?,?)",
         {payload.content or "", payload.session_id, payload.id})
  elseif entry.kind == "session" then
    local local_rows = query("SELECT updated_at FROM sessions WHERE id=?", {payload.id})
    if #local_rows == 0 or (payload.updated_at or 0) >= (local_rows[1].updated_at or 0) then
      -- Every position needs a concrete value: a nil would leave a hole in the
      -- params array and the JSON encoder rejects sparse arrays.
      exec("INSERT OR REPLACE INTO sessions(id,route_id,objective,parent_session_id,started_at," ..
           "ended_at,user_id,node_id,title,mode,summary,summarized_until,updated_at) " ..
           "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
           {payload.id, payload.route_id or "", payload.objective or "",
            payload.parent_session_id or "", payload.started_at or host.now(),
            payload.ended_at or 0, payload.user_id or "master",
            payload.node_id or "", payload.title or "", payload.mode or "default",
            payload.summary or "", payload.summarized_until or 0, payload.updated_at or host.now()})
    end
  elseif entry.kind == "memory" then
    exec("INSERT OR IGNORE INTO memories(id,scope,content,tags,source,session_id,created_at," ..
         "updated_at,content_sha256) VALUES(?,?,?,?,?,?,?,?,?)",
         {payload.id, payload.scope or "global", payload.content or "",
          type(payload.tags) == "table" and json.encode(payload.tags) or (payload.tags or "[]"),
          payload.source or "replica", payload.session_id or "", payload.created_at or host.now(),
          payload.updated_at or host.now(), payload.content_sha256 or ""})
    exec("DELETE FROM memories_fts WHERE memory_id=?", {payload.id})
    exec("INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)",
         {payload.content or "", payload.tags or "", payload.id})
  elseif entry.kind == "run" then
    exec("INSERT OR REPLACE INTO runs(id,session_id,turn_id,status,outcome,reply,started_at,ended_at) " ..
         "VALUES(?,?,?,?,?,?,?,?)",
         {payload.id, payload.session_id or "", payload.turn_id or "", payload.status or "",
          payload.outcome or "", payload.reply or "", payload.started_at or host.now(),
          payload.ended_at or 0})
  else
    return false
  end
  return true
end

return M
