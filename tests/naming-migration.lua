-- The naming migration (ARCHITECTURE.md section 6) against a database built the OLD way.
--
-- Two properties, and neither is visible from a fresh install - which is the database every other test
-- uses, so both of these can be broken while the suite stays green:
--
--   1. an existing database is upgraded exactly once, with its rows intact. The rename runs *before*
--      the schema on purpose: `schema.sql` creates `messages`, so a rename arriving after it would find
--      the name taken, skip, and strand every old row in a table nothing reads - silent data loss.
--   2. running it again changes nothing. A migration that renames twice, or that fires on an
--      already-migrated database, is a migration that corrupts the second time it runs.
--
-- The old shape is written out here by hand rather than read from a fixture file: it is what the live
-- database looked like at the moment of the rename, and a fixture that quietly follows the new schema
-- would test nothing.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

local failures = 0
local function check(condition, label)
  if condition then print("ok   " .. label) else print("FAIL " .. label); failures = failures + 1 end
end

local function exec(statement, params)
  local raw = host.sql_exec(statement, json.encode(params or {}))
  return type(raw) == "string" and json.decode(raw) or raw
end
local function rows(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  local value = type(raw) == "string" and json.decode(raw) or raw
  return value or {}
end
local function one(statement, params)
  return rows(statement, params)[1] or {}
end
local function exists(name)
  return (tonumber(one("SELECT COUNT(*) AS n FROM sqlite_master WHERE name=?", {name}).n) or 0) > 0
end
local function has_column(table, column)
  for _, row in ipairs(rows("PRAGMA table_info(" .. table .. ")")) do
    if row.name == column then return true end
  end
  return false
end
local function count(table)
  return tonumber(one("SELECT COUNT(*) AS n FROM " .. table).n) or 0
end

-- ---------------------------------------------------------------- the old shape, by hand
exec([[CREATE TABLE sessions (
  id TEXT PRIMARY KEY, route_id TEXT NOT NULL DEFAULT '', objective TEXT NOT NULL DEFAULT '',
  parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL)]])
exec([[CREATE TABLE turns (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '', tool_calls TEXT NOT NULL DEFAULT '[]',
  tool_call_id TEXT NOT NULL DEFAULT '', tool_name TEXT NOT NULL DEFAULT '',
  tokens INTEGER NOT NULL DEFAULT 0, ms INTEGER NOT NULL DEFAULT 0, ok INTEGER NOT NULL DEFAULT 1,
  debug INTEGER NOT NULL DEFAULT 0, trace TEXT NOT NULL DEFAULT '[]', created_at REAL NOT NULL)]])
exec("CREATE INDEX turns_session_idx ON turns(session_id, seq)")
exec([[CREATE VIRTUAL TABLE turns_fts USING fts5(
  content, session_id UNINDEXED, turn_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')]])
exec([[CREATE TABLE messages (
  conversation_id TEXT NOT NULL, message_id TEXT NOT NULL, sender_id TEXT NOT NULL DEFAULT '',
  direction TEXT NOT NULL DEFAULT 'incoming', sent_at REAL, observed_at REAL NOT NULL,
  body TEXT NOT NULL DEFAULT '', reply_to TEXT, media TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL DEFAULT 'observer', body_sha256 TEXT NOT NULL,
  PRIMARY KEY (conversation_id, message_id))]])
exec("CREATE INDEX messages_time_idx ON messages(observed_at)")
exec("CREATE INDEX messages_conversation_idx ON messages(conversation_id, observed_at)")
exec([[CREATE VIRTUAL TABLE messages_fts USING fts5(
  body, conversation_id UNINDEXED, message_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')]])
exec([[CREATE TABLE runs (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, turn_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '', outcome TEXT NOT NULL DEFAULT '', reply TEXT NOT NULL DEFAULT '',
  started_at REAL NOT NULL, ended_at REAL)]])
exec([[CREATE TABLE harness_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL,
  turn_id TEXT NOT NULL, span_id TEXT NOT NULL, kind TEXT NOT NULL, phase TEXT NOT NULL,
  at REAL NOT NULL, payload TEXT NOT NULL)]])

-- Rows, so "the data survived" is a claim with evidence rather than an assertion about an empty table.
exec("INSERT INTO sessions(id,started_at) VALUES('s-old',1.0)")
exec("INSERT INTO turns(id,session_id,seq,role,content,created_at) VALUES('m-user','s-old',1,'user','where is the ledger kept',1.0)")
exec("INSERT INTO turns(id,session_id,seq,role,content,created_at) VALUES('m-assistant','s-old',2,'assistant','in ledger_messages',2.0)")
exec("INSERT INTO turns_fts(content,session_id,turn_id) VALUES('where is the ledger kept','s-old','m-user')")
exec([[INSERT INTO messages(conversation_id,message_id,observed_at,body,body_sha256)
       VALUES('c1','x1',1.0,'an external message','sha')]])
exec("INSERT INTO messages_fts(body,conversation_id,message_id) VALUES('an external message','c1','x1')")
exec("INSERT INTO runs(id,session_id,turn_id,started_at) VALUES('r1','s-old','r1',1.0)")
exec([[INSERT INTO harness_events(id,session_id,turn_id,span_id,kind,phase,at,payload)
       VALUES('e1','s-old','r1','sp1','turn_span','start',1.0,'{}')]])

check(count("turns") == 2 and count("messages") == 1, "the old database starts with rows in both tables")

-- ---------------------------------------------------------------- the migration, run by setup()
memory.setup()

check(exists("messages") and not exists("turns"), "the transcript is now `messages`, and `turns` is gone")
check(count("messages") == 2, "both transcript rows survived", "messages has " .. count("messages"))
check(tonumber(one("SELECT COUNT(*) AS n FROM messages WHERE id='m-user' AND content='where is the ledger kept'").n) == 1,
  "a surviving row kept its id and content")
check(tonumber(one("SELECT COUNT(*) AS n FROM messages_fts WHERE messages_fts MATCH 'ledger'").n) == 1,
  "the full-text index was rebuilt with the rows, not dropped and forgotten")
check(has_column("messages_fts", "message_id") and not has_column("messages_fts", "turn_id"),
  "the index's column is `message_id` (a virtual table cannot rename a column, so it is rebuilt)")

check(exists("ledger_messages") and not has_column("ledger_messages", "session_id"),
  "the external inbox is `ledger_messages`, and it is the ledger - not the transcript")
check(count("ledger_messages") == 1, "the ledger row survived", "ledger has " .. count("ledger_messages"))
check(tonumber(one("SELECT COUNT(*) AS n FROM ledger_messages_fts WHERE ledger_messages_fts MATCH 'external'").n) == 1,
  "the ledger's full-text index moved with it")
check(has_column("ledger_messages_fts", "conversation_id"), "and it is still the ledger's index")
-- Both tables end up with an index called `messages_time_idx` in the old naming, so the check has to be
-- about which table each one belongs to, not about the name existing.
local ledger_index = one("SELECT sql FROM sqlite_master WHERE name='ledger_messages_time_idx'").sql or ""
local transcript_index = one("SELECT sql FROM sqlite_master WHERE name='messages_time_idx'").sql or ""
check(ledger_index:find("ON ledger_messages(", 1, true) ~= nil
      and exists("ledger_messages_conversation_idx") and not exists("messages_conversation_idx"),
  "the ledger's indexes were renamed with their table")
check(transcript_index:find("ON messages(", 1, true) ~= nil and not exists("turns_time_idx"),
  "and the transcript's index belongs to the transcript, not to the ledger")

check(has_column("runs", "run_id") and not has_column("runs", "turn_id"),
  "runs.turn_id is run_id (it always held the run's own id)")
check(has_column("harness_events", "run_id") and not has_column("harness_events", "turn_id"),
  "harness_events.turn_id is run_id")
check(exists("messages_session_idx") and exists("messages_time_idx") and not exists("turns_session_idx"),
  "the transcript's indexes were renamed")

-- ---------------------------------------------------------------- idempotence: run it again
-- The signature is everything a second run could disturb: the object names and the row counts.
local function signature()
  local names, counts = {}, {}
  for _, row in ipairs(rows("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")) do
    names[#names + 1] = row.type .. ":" .. row.name
  end
  for _, table in ipairs({ "messages", "ledger_messages", "messages_fts", "ledger_messages_fts", "runs", "harness_events" }) do
    counts[#counts + 1] = table .. "=" .. count(table)
  end
  return table.concat(names, ",") .. "|" .. table.concat(counts, ",")
end

local before = signature()
memory.setup()
local after = signature()
check(before == after, "a second run changes nothing at all (same objects, same row counts)")
if before ~= after then
  print("     before: " .. before)
  print("     after:  " .. after)
end

-- The names it must NOT have touched: a migration that renames an already-migrated database would have
-- turned the transcript back into the ledger, and the counts above would look plausible.
check(tonumber(one("SELECT COUNT(*) AS n FROM messages WHERE role='user'").n) == 1,
  "the transcript is still the transcript after the second run")
check(tonumber(one("SELECT COUNT(*) AS n FROM ledger_messages WHERE conversation_id='c1'").n) == 1,
  "and the ledger is still the ledger")

-- A peer can replay a journal written before the column was renamed. New
-- entries carry both keys until older peers are upgraded too.
check(memory.apply_entry({kind="run",payload={id="r-legacy",session_id="s-old",
  turn_id="r-legacy",status="completed",outcome="answered"}}),
  "a pre-migration run journal entry still replays")
check(one("SELECT run_id FROM runs WHERE id='r-legacy'").run_id == "r-legacy",
  "replaying a legacy entry preserves the run identifier")
memory.record_run("r-new", "s-old", "completed", "answered", "")
local outgoing
for _, entry in ipairs(memory.journal_since(0, 100)) do
  if entry.kind == "run" and entry.entity_id == "r-new" then outgoing = entry.payload end
end
check(outgoing and outgoing.run_id == "r-new" and outgoing.turn_id == "r-new",
  "new run entries retain a legacy wire alias for older peers")

-- The journal's vocabulary boundary: entries written before the rename say `turn`, entries after say
-- `message`, and a reader accepts both, because the log is durable and is never rewritten. The boundary
-- is recorded rather than inferred, so a later reader splits the log by era instead of guessing from the
-- commit graph. Nothing is pruned: the journal never enters a prompt, so its old words cannot mislead an
-- agent, and the log is the record of what happened.
local function meta(key) return (one("SELECT value FROM meta WHERE key=?", {key}) or {}).value end
check(meta("journal_kind") == "message", "the journal's current kind is recorded")
check(meta("journal_kind_legacy") == "turn", "and the kind its older entries were written with")
check(tonumber(meta("journal_kind_changed_at")) > 0, "with the moment they changed")

-- And a pre-rename entry still replays, which is what the recorded era is for.
check(memory.apply_entry({kind="turn", payload={id="m-legacy", session_id="s1", seq=99, role="user",
  content="written before the rename", created_at=1}}), "a pre-rename journal entry still replays")
check(tonumber(one("SELECT COUNT(*) AS n FROM messages WHERE id='m-legacy'").n) == 1,
  "and its row lands in the transcript")
check(not memory.apply_entry({kind="nonsense", payload={id="x"}}), "an unknown kind is still refused")

if failures == 0 then print("ALL PASS") else print("FAILED (" .. failures .. ")") end
