-- Turn feed: the model's own `<turn>` notes, collected, grouped, ranked, and kept private.
--
-- Why this test exists. `wa turns` turns transcripts into a queue, which means every one of its steps
-- can be wrong in a way that looks right: a note read out of a sentence that merely mentions the tag, a
-- group that merged two different problems, a rank that ignores cost or recency, a "fixed" that never
-- asks whether the problem came back, and - the one that matters most - a digest that quotes somebody
-- else's WhatsApp message. Each of those is a check below, on fixtures written here, with no node, no
-- provider and no network: the peer half is exercised by replacing `dofile` for `nodes.lua` only, so the
-- capability is tested as the capability (a table of notes) rather than as an HTTP call.
--
-- The fixtures are rows in this row's own scratch ledger (`WASM_AGENT_HOME`), the same way
-- `scripts/test-harness-evaluator-privacy.lua` builds its own.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local core = dofile("lua/core/turnfeed.lua")
local cli = dofile("lua/core/turnfeed_cli.lua")

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error("TURN FEED CHECK FAILED: " .. label) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    error(string.format("TURN FEED CHECK FAILED: %s\n  expected: %s\n  actual:   %s", label,
      tostring(expected), tostring(actual)))
  end
end
local function contains(haystack, needle, label)
  checks = checks + 1
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error("TURN FEED CHECK FAILED: " .. label .. " (looked for " .. tostring(needle) .. ")")
  end
end
local function absent(haystack, needle, label)
  checks = checks + 1
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error("TURN FEED CHECK FAILED: " .. label .. " (found " .. tostring(needle) .. ")")
  end
end

local function exec(statement, params)
  local ok, raw = pcall(host.sql_exec, statement, json.encode(params or {}))
  if not ok then error("fixture insert failed: " .. tostring(raw) .. "\n" .. statement) end
  return raw
end

local HOME = host.getenv("WASM_AGENT_HOME") or ""
check(HOME ~= "", "the row runs with a scratch home")

-- --------------------------------------------------------------------------- fixtures
--
-- Four sessions on this node, one peer answered by a stub. The notes are shapes this fleet's models
-- actually wrote: `**what hurt** —`, `- **what hurt** -`, `**focus:**`, and one that says nothing hurt.
local MARK = "pf" .. tostring(math.floor(host.now()))
local session_ids = {}
local function session(id, title, at)
  session_ids[#session_ids + 1] = id
  exec([[INSERT INTO sessions(id,route_id,objective,started_at,user_id,node_id,mode,title)
    VALUES(?,?,?,?,?,?,?,?)]], { id, "", "fixture", at, "master", "fixture-node", "default", title })
end

local seq_of = {}
local function message(sid, role, content, at, extra)
  extra = extra or {}
  seq_of[sid] = (seq_of[sid] or 0) + 1
  local seq = seq_of[sid]
  exec([[INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,tokens,ms,ok,trace,created_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)]],
    { sid .. "-" .. seq, sid, seq, role, content, "[]", "", extra.tool_name or "", extra.tokens or 0, 0,
      extra.ok == false and 0 or 1, extra.trace or "[]", at })
  return seq
end

local function user(sid, text, at) return message(sid, "user", text, at) end
local function tool(sid, name, at, ok)
  return message(sid, "tool", "{}", at, { tool_name = name, ok = ok ~= false })
end
local function assistant(sid, text, at, trace)
  return message(sid, "assistant", text, at, { trace = trace or "[]" })
end

-- Two sessions that hit the SAME problem (an empty connector schema), one older, one newer.
local A = MARK .. "-a"
local B = MARK .. "-b"
-- One session that hit a different one (an edit near-miss).
local C = MARK .. "-c"
-- One session whose note is the "nothing hurt" one-liner.
local D = MARK .. "-d"
local DAY = 86400
local base = math.floor(host.now()) - 10 * DAY
session(A, "connector schemas", base)
session(B, "connector schemas again", base + 5 * DAY)
session(C, "edit near miss", base + 2 * DAY)
session(D, "quiet turn", base + 3 * DAY)

local MODEL = '{"model":"deepseek-v4.1-flash"}'

-- A: three tool calls, one failed - the connector problem cost a redo.
user(A, "why are the connector schemas empty", base + 10)
tool(A, "mcp_whatsapp_read", base + 20)
tool(A, "mcp_whatsapp_read", base + 21, false)
tool(A, "search_messages", base + 22)
assistant(A, table.concat({
  "The connector catalogue answered with empty schemas.",
  "",
  "<turn>",
  "**what hurt** — `mcp_whatsapp_read` came back with an empty schema, so the call was refused as",
  "`json_number_invalid` and I retried it with a guessed argument.",
  "**what it buys** — fewer steps: one call instead of three.",
  "**focus** — the connector catalogue should refuse an empty schema by name instead of serving it.",
  "</turn>",
}, "\n"), base + 30, MODEL)

-- B: the same problem, newer, more calls - this is what makes the group rank first.
user(B, "the whatsapp connector schema is empty again", base + 5 * DAY)
for _ = 1, 6 do tool(B, "mcp_whatsapp_read", base + 5 * DAY + 1, false) end
assistant(B, table.concat({
  "<turn>",
  "- **what hurt** - the `mcp_whatsapp_read` schema was empty again and every call failed.",
  "- **what it buys** - better context: the schema is one fact, not a guess.",
  "- **focus** - an empty connector schema must be refused by name (`empty_connector_schema`).",
  "</turn>",
}, "\n"), base + 5 * DAY + 20, MODEL)

-- C: a different problem, high cost but only one note.
user(C, "the range edit was wrong", base + 2 * DAY)
for _ = 1, 3 do tool(C, "edit", base + 2 * DAY + 1, false) end
tool(C, "read", base + 2 * DAY + 2)
assistant(C, table.concat({
  "<turn>",
  "- **what hurt:** an inaccurate `read` range made the `edit` replace the wrong block, and two of the",
  "three retries were my own repair.",
  "- **what it buys:** fewer steps (5 → 2).",
  "**focus:** a range edit should echo the bytes it replaced.",
  "</turn>",
}, "\n"), base + 2 * DAY + 30, MODEL)

-- D: nothing hurt, one line, still a note (the section asks for exactly this shape).
user(D, "thanks", base + 3 * DAY)
assistant(D, "<turn>\nNothing hurt this turn; no harness change is owed.\n</turn>", base + 3 * DAY + 5, MODEL)

-- --------------------------------------------------------------------------- 1. the note itself
local parse = core.parse
local spellings = {
  ["**what hurt** — a\n**what it buys** — b\n**focus** — c"] = { "a", "b", "c" },
  ["- **what hurt** - a\n- **what it buys** - b\n- **focus** - c"] = { "a", "b", "c" },
  ["**what hurt:** a\n**what it buys:** b\n**focus:** c"] = { "a", "b", "c" },
  ["• what hurt — a\n• what it buys — b\n• focus — c"] = { "a", "b", "c" },
  ["1. **what hurt** — a\n2. **what it buys** — b\n3. **focus** — c"] = { "a", "b", "c" },
}
for body, expected in pairs(spellings) do
  local parsed = parse("<turn>\n" .. body .. "\n</turn>")
  check(parsed ~= nil, "a note is parsed: " .. body)
  if parsed then
    eq(parsed.hurt, expected[1], "what hurt is read out of " .. body)
    eq(parsed.buys, expected[2], "what it buys is read out of " .. body)
    eq(parsed.focus, expected[3], "focus is read out of " .. body)
  end
end
-- A sentence that MENTIONS the tag is not a note: no block, no note.
eq(parse("Every answer ends with a `<turn>` note, which is the point."), nil,
  "a message mentioning the tag in a sentence is not a note")
eq(parse("no tag at all"), nil, "a message without the tag is not a note")
eq(parse(nil), nil, "a missing content is not a note")
local one_liner = parse("<turn>\nNothing hurt this turn.\n</turn>")
check(one_liner ~= nil and one_liner.hurt == "Nothing hurt this turn.",
  "a closed one-line note is a note, with the sentence as what hurt")

-- --------------------------------------------------------------------------- 2. collection
local notes = core.notes({ node = "here" })
eq(#notes, 4, "every fixture note is collected, and only the notes")
local by_session = {}
for _, note in ipairs(notes) do by_session[note.session] = note end
check(by_session[A] ~= nil, "the first session's note is collected")
eq(by_session[A].node, "here", "a record carries the node it came from")
eq(by_session[A].model, "deepseek-v4.1-flash", "the model is read from the turn's trace")
eq(by_session[A].measured.tool_calls, 3, "the turn's tool calls are measured from the ledger")
eq(by_session[A].measured.tool_errors, 1, "the turn's failed tool calls are measured, not guessed")
eq(by_session[A].measured.steps, 1, "the turn's model calls are measured")
-- cost = tool_errors + retries + floor(steps/10) + its own stated delta
eq(by_session[A].cost, 1, "one failed call is one unit of cost")
eq(by_session[B].cost, 6, "six failed calls are six, and the note states no delta")
eq(by_session[C].delta, 3, "a note's own `5 → 2` is read as 3 steps saved")

-- `--since` is a bound on the notes, and it is applied in SQL, not by trimming afterwards.
local since = core.parse_since("24h", host.now())
check(tonumber(since) ~= nil, "24h parses to an epoch")
eq(core.parse_since("all"), nil, "all time is no bound")
eq(select(2, core.parse_since("yesterday")), "invalid_since", "an unparseable window is refused by name")
local recent = core.notes({ since = math.floor(host.now()) - DAY, node = "here" })
eq(#recent, 0, "no fixture note is within the last day")
local older = core.notes({ since = base - DAY, node = "here" })
eq(#older, 4, "every fixture note is inside a window that starts before them")

-- --------------------------------------------------------------------------- 3. grouping
local clusters = core.clusters_of(notes)
eq(#clusters, 3, "four notes that describe three problems make three clusters")
local function cluster_with(token)
  for _, cluster in ipairs(clusters) do
    for _, name in ipairs(cluster.named) do
      if name == token then return cluster end
    end
  end
  return nil
end
local connector = cluster_with("mcp_whatsapp_read")
check(connector ~= nil, "the connector cluster names the tool its notes name")
eq(connector and #connector.notes, 2, "both connector notes are in it - the same problem, two sessions")
local editor = cluster_with("edit")
check(editor ~= nil, "the edit cluster names the tool its note names")
eq(editor and #editor.notes, 1, "the edit note is not merged into the connector cluster")
local quiet = nil
for _, cluster in ipairs(clusters) do
  for _, note in ipairs(cluster.notes) do if note.session == D then quiet = cluster end end
end
check(quiet ~= nil and quiet ~= connector and quiet ~= editor, "the one-line note is its own cluster")

-- The similarity rule, as the rule: a shared named signal plus a fifth of the weight joins; sole
-- agreement on half the words joins; a shared word alone does not.
local function pair(left, right)
  local built = core.clusters_of({
    { node = "n", session = "1", seq = 1, at = 1, hurt = left, buys = "", focus = "", cost = 0, measured = {}, quote = left },
    { node = "n", session = "2", seq = 1, at = 2, hurt = right, buys = "", focus = "", cost = 0, measured = {}, quote = right },
  })
  return #built
end
eq(pair("`mcp_whatsapp_read` answered an empty schema", "`mcp_whatsapp_read` served an empty schema again"),
  1, "two notes naming the same tool are one cluster")
eq(pair("the gate printed a skip with no reason", "an edit replaced the wrong block silently"),
  2, "two notes about different subsystems stay apart")
-- A bare file name that is the tail of exactly one path in the run IS that path: one problem, one
-- spelling of it.
local normalized = core.clusters_of({
  { node = "n", session = "1", seq = 1, at = 1, hurt = "`scripts/fast.sh` reported nothing useful",
    buys = "", focus = "", cost = 0, measured = {}, quote = "" },
  { node = "n", session = "2", seq = 1, at = 2, hurt = "`fast.sh` reported nothing useful again",
    buys = "", focus = "", cost = 0, measured = {}, quote = "" },
})
check(#normalized == 1, "a bare file name and its full path are one signal")
check(normalized[1] and normalized[1].files[1] == "scripts/fast.sh",
  "and the cluster is named by the full path")

-- --------------------------------------------------------------------------- 4. ranking
local ranked = core.rank(clusters, { now = base + 6 * DAY })
eq(ranked[1], connector, "the problem two sessions hit ranks above the one-observation ones")
local order = {}
for _, cluster in ipairs(ranked) do order[#order + 1] = cluster.id end
eq(#order, 3, "every cluster is ranked")
-- The formula, checked against itself: count * (1 + cost) * recency.
for _, cluster in ipairs(ranked) do
  local age = (base + 6 * DAY - cluster.newest) / DAY
  local recency = 1 + 1 / (1 + age / 7)
  local expected = cluster.count * (1 + cluster.cost) * recency
  checks = checks + 1
  if math.abs(cluster.score - expected) > 1e-6 then
    error(string.format("TURN FEED CHECK FAILED: score is frequency x cost x recency (%s: %.6f vs %.6f)",
      cluster.id, cluster.score, expected))
  end
  eq(cluster.count, #cluster.notes, "count is the cluster's notes")
  eq(cluster.cost, (function() local total = 0; for _, n in ipairs(cluster.notes) do total = total + n.cost end; return total end)(),
    "cost is the sum of its notes' measured cost")
end
check(ranked[1].newest >= ranked[#ranked].newest, "a tie in score breaks towards the newer cluster")
-- Recency alone: the same one-note cluster scores higher when its note is newer.
local function score_at(age_days)
  local built = core.clusters_of({ { node = "n", session = "1", seq = 1, at = 1,
    hurt = "the gate skip had no reason", buys = "", focus = "", cost = 0, measured = {}, quote = "" } })
  local now = base + 6 * DAY
  built[1].notes[1].at = now - age_days * DAY
  return core.rank(built, { now = now })[1].score
end
check(score_at(0) > score_at(60), "recency is a factor: a note from today outranks the same note two months old")
check(score_at(0) > 1.9 and score_at(60) < 1.2, "and the weight is bounded (2.0 today, approaching 1.0 with age)")

-- --------------------------------------------------------------------------- 5. fixed / still hurting
--
-- The marker is two facts: which cluster, and the time of the commit that claims it. The comparison is
-- "are there notes newer than that time?", so a marker is written here with a chosen time instead of a
-- real commit era - the git half is checked separately, further down.
local function write_markers(entries)
  host.write_file(core.state_dir() .. "/.keep", "")
  check(host.write_file(core.fixed_path(), json.encode({ version = 1, clusters = entries })) ~= nil,
    "the marker store is written")
end

local connector_id = connector.id
local SHA = "0123456789abcdef0123456789abcdef01234567"
write_markers({})
eq(next(core.fixed()), nil, "an empty store names no cluster")

-- A marker OLDER than both connector notes: the problem came back.
write_markers({ [connector_id] = { cluster = connector_id, sha = SHA, at = base, at_source = "commit" } })
local markers = core.fixed()
check(markers[connector_id] ~= nil, "the marker is read back by id")
local ranked_again = core.rank(core.clusters_of(core.notes({ node = "here" })), { now = base + 6 * DAY })
local marked = nil
for _, cluster in ipairs(ranked_again) do if cluster.id == connector_id then marked = cluster end end
check(marked ~= nil, "the marked cluster is found again in a fresh run (its id is content-derived)")
local still = core.status(marked, markers, base + 6 * DAY)
eq(still.state, "still_hurting", "notes newer than the fix commit mean the problem is still hurting")
eq(still.after, 2, "and the count of notes after the fix is reported")
contains(core.status_line(still), "still hurting", "the report says so in words")
contains(core.status_line(still), string.sub(SHA, 1, 8), "the report names the commit")

-- A marker NEWER than every note: quiet since the fix.
write_markers({ [connector_id] = { cluster = connector_id, sha = SHA, at = base + 6 * DAY, at_source = "commit" } })
local quiet_status = core.status(marked, core.fixed(), base + 8 * DAY)
eq(quiet_status.state, "quiet", "a commit newer than every note means the cluster is quiet")
eq(quiet_status.after, 0, "with no note after it")
contains(core.status_line(quiet_status), "quiet since", "and the report says so in words")
contains(core.status_line(quiet_status), string.sub(SHA, 1, 8), "naming the commit")

-- An unmarked cluster is not "quiet": it is unmarked.
write_markers({})
eq(core.status(marked, core.fixed(), base).state, "unfixed", "a cluster nobody fixed is not reported as quiet")

-- The git half: a real commit in this checkout answers with ITS time, not the mark time.
local tree = host.getenv("WASM_AGENT_LUA_ROOT") or ""
local head = nil
if tree ~= "" then
  local ok, raw = pcall(host.exec, "git rev-parse HEAD", tree, 60)
  local answer = type(raw) == "string" and json.decode(raw) or raw
  if ok and type(answer) == "table" and tonumber(answer.code) == 0 then
    head = (answer.stdout or ""):gsub("%s+$", "")
  end
end
check(head ~= nil, "the row can read this checkout's HEAD (a runner without git skips only this part)")
if head then
  local at = core.commit_time(head)
  check(at ~= nil, "HEAD has a committer time")
  local marker = core.mark_fixed(connector_id, head, { note = "connector schema fixed" })
  check(marker ~= nil, "a cluster can be marked fixed with a real commit")
  eq(marker and marker.at_source, "commit", "and the time recorded is the commit's, not the mark time")
  eq(marker and marker.at, at, "the exact committer time")
  eq(marker and marker.sha, head, "the marker carries the commit")
  check(core.fixed()[connector_id] ~= nil, "the marker persists to the store")
  eq(core.unmark_fixed(connector_id), true, "a marker can be taken back")
  eq(core.fixed()[connector_id], nil, "and is gone from the store")
end
eq(select(2, core.commit_time("not-a-sha")), "invalid_sha", "a sha that does not parse is refused by name")

-- --------------------------------------------------------------------------- 6. privacy
--
-- The rule the digest cannot break: a note that quotes a person's message must reach the report with the
-- message gone and the model's own remark kept. The fixture is a WhatsApp-shaped quotation with a phone
-- number, an address and a long body - the three things that arrive through a connector.
local P = MARK .. "-p"
session(P, "whatsapp quote", base + DAY)
local SECRET_BODY = "Oi Victor, o boleto vence amanha, segue o comprovante anexo"
user(P, "read the last message", base + DAY + 5)
tool(P, "mcp_whatsapp_read", base + DAY + 6)
assistant(P, table.concat({
  "<turn>",
  "**what hurt** — `mcp_whatsapp_read` answered the chat as +55 11 98765-4321 with \"" .. SECRET_BODY .. "\"",
  "and the schema for `mcp_whatsapp_send` was empty, so the reply path needed two probes.",
  "**what it buys** — one call instead of two.",
  "**focus** — the connector schema should be served before a chat is read (contact victor@example.com).",
  "</turn>",
}, "\n"), base + DAY + 20, MODEL)

local private_notes = core.notes({ node = "here" })
local privacy_note = nil
for _, note in ipairs(private_notes) do if note.session == P then privacy_note = note end end
check(privacy_note ~= nil, "the note that quotes a chat is collected")
local as_json = json.encode(privacy_note)
absent(as_json, "boleto", "a quoted chat body never survives collection")
absent(as_json, "98765", "a phone number never survives collection")
absent(as_json, "victor@example.com", "an address never survives collection")
contains(privacy_note.focus, "<email>", "the address is replaced, not dropped silently")
contains(privacy_note.hurt, "mcp_whatsapp_read", "the model's own words about the tool are kept")
contains(privacy_note.hurt, "schema", "and its description of the harness cost")
contains(privacy_note.hurt, "<phone>", "the number is replaced, not left in place")

-- The same text through every surface this feature has: the report, the digest file, and a peer answer.
local report_text = table.concat(core.report({ clusters = core.clusters_of(private_notes),
  note_count = #private_notes, nodes = { "here" }, top = 99 }), "\n")
absent(report_text, "boleto", "the terminal report does not print a quoted chat body")
absent(report_text, "98765", "the terminal report does not print a phone number")
local digest_path, digest_written = core.digest({ clusters = core.clusters_of(private_notes),
  note_count = #private_notes, nodes = { "here" } })
check(digest_written, "the digest is written")
check(digest_path:sub(1, #HOME) == HOME, "the digest lands inside this node's home, never a repository")
local digest_text = host.read_file(digest_path) or ""
contains(digest_text, "Turn feed", "the digest is the turn feed's")
absent(digest_text, "boleto", "the digest does not print a quoted chat body")
absent(digest_text, "98765", "the digest does not print a phone number")
absent(digest_text, "victor@example.com", "the digest does not print an address")
local peer_answer = json.encode(core.serve({ since = "30d" }))
absent(peer_answer, "boleto", "the peer answer carries no quoted chat body either")
absent(peer_answer, "98765", "the peer answer carries no phone number")
contains(peer_answer, "mcp_whatsapp_read", "but it does carry the model's words about the tool")

-- A date and a clock time in the model's own sentence are not phone numbers.
local kept = core.redact("at 2026-11-13 20:22 the timer fired")
contains(kept, "2026-11-13 20:22", "a date and a time are not mistaken for a number")

-- Each rule, on its own shape: the list of rules is documentation, so it is checked against the code.
eq(#core.PRIVACY_RULES, 7, "seven privacy rules, each named")
local jid = core.redact("jid: 5511987654321@s.whatsapp.net asked twice")
absent(jid, "5511987654321", "a chat id in a payload field is stripped")
local field = core.redact("Subject: the invoice for the house")
absent(field, "the invoice for the house", "a mail subject field is stripped")
local json_body = core.redact('{"chat":"x","text":"a message body that is quite long indeed"}')
absent(json_body, "a message body", "a message body in a JSON field is stripped")
local secret = core.redact("the key was sk-live-abcdef0123456789 and the Bearer abcdefgh12345 was sent")
absent(secret, "sk-live-abcdef0123456789", "an api key is stripped")
absent(secret, "abcdefgh12345", "a bearer token is stripped")
local notice = core.redact("[Sentinel notice] deploy finished at 20:22 on wa-desktop")
absent(notice, "deploy finished", "a sentinel notice body is stripped")

-- --------------------------------------------------------------------------- 7. the peer half
--
-- `nodes.lua` is replaced for this section only, so the collection is tested as the capability it is:
-- a table of notes from another node, and a peer that does not answer named rather than skipped.
local real_dofile = dofile
local peer_notes = {
  { schema = 1, node = "peer-one", session = "peer-session-1", message = "m", seq = 1, at = base + 4 * DAY,
    hurt = "`mcp_whatsapp_read` served an empty schema and the call was refused",
    buys = "", focus = "refuse an empty connector schema by name", quote = "refuse an empty connector schema by name",
    quote_field = "focus", cost = 2, delta = 0, measured = {} },
}
local asked = {}
local stub = {
  node_name = function() return "here" end,
  list = function() return {
    { id = "local", node_id = "local", name = "here", local_node = true, online = true },
    { id = "peer-1", node_id = "peer-1", name = "peer-one", online = true },
    { id = "peer-2", node_id = "peer-2", name = "peer-two", online = true },
    { id = "peer-3", node_id = "peer-3", name = "peer-three", online = false },
  } end,
  remote_call = function(node_id, capability, args)
    asked[#asked + 1] = { node = node_id, capability = capability, args = args }
    if node_id == "peer-1" then return { schema = 1, node = "peer-one", notes = peer_notes } end
    return { error = "peer_unreachable" }
  end,
}
dofile = function(path, ...)
  if type(path) == "string" and path:find("nodes.lua", 1, true) then return stub end
  return real_dofile(path, ...)
end
local collected, failures = core.peer_notes({ since_text = "30d" })
dofile = real_dofile
eq(#asked, 2, "every ONLINE peer is asked, and the offline one is not")
eq(asked[1].capability, "turns", "the capability asked for is `turns`")
eq(#collected, 1, "the peer's notes are collected")
eq(collected[1].node, "peer-one", "a peer note keeps the node that answered it")
eq(#failures, 1, "a peer that does not answer is reported")
eq(failures[1].node, "peer-two", "by name")
eq(failures[1].error, "peer_unreachable", "with its own reason")

-- The fleet's queue is one queue: a peer note about the same problem joins this node's cluster.
local fleet = core.notes({ node = "here" })
for _, note in ipairs(collected) do fleet[#fleet + 1] = note end
local fleet_clusters = core.rank(core.clusters_of(fleet), {})
local fleet_connector = nil
for _, cluster in ipairs(fleet_clusters) do
  for _, note in ipairs(cluster.notes) do
    if note.node == "peer-one" then fleet_connector = cluster end
  end
end
check(fleet_connector ~= nil, "the peer's note is in a cluster")
eq(fleet_connector and #fleet_connector.nodes, 2, "and that cluster spans both nodes")

-- --------------------------------------------------------------------------- 8. the command
local real_print = print
local printed = {}
print = function(line) printed[#printed + 1] = tostring(line) end
local code = cli.run({ "turns", "--no-peers", "--top", "3" })
print = real_print
eq(code, 0, "`wa turns` answers with 0")
local text = table.concat(printed, "\n")
contains(text, "turn feed:", "it prints one header line")
contains(text, "brief:", "a cluster prints a brief")
contains(text, "acceptance:", "the brief has an acceptance line")
contains(text, "problem:", "the brief has a problem line")
contains(text, "evidence:", "the brief has an evidence line")
contains(text, "digest:", "and names the digest it wrote")
absent(text, "boleto", "the command's own output is redacted too")

printed = {}
print = function(line) printed[#printed + 1] = tostring(line) end
code = cli.run({ "turns", "--no-peers", "--json", "--no-digest" })
print = real_print
local machine = json.decode(table.concat(printed, "\n"))
check(machine ~= nil, "`wa turns --json` prints one JSON document")
eq(machine.schema, 1, "with its schema")
check(machine.notes >= 4, "and how many notes it read")
local where = nil
for _, record in ipairs(machine.clusters) do
  if record.count > 1 then where = record end
end
check(where ~= nil and where.count >= 2, "a cluster of more than one note is in the machine form")
check(where and where.status == "unfixed", "an unmarked cluster says unfixed in the machine form")

eq(cli.run({ "turns", "fixed", connector_id }), 2, "marking fixed without a commit is refused")
eq(cli.run({ "turns", "nonsense" }), 2, "an unknown verb is refused by name")
eq(cli.run({ "turns", "--top", "1", "--no-peers", "--no-digest" }), 0, "a one-cluster report is still a report")
eq(cli.run({ "turns", "--since", "last tuesday", "--no-peers", "--no-digest" }), 2,
  "an unparseable window is refused by name")

-- --------------------------------------------------------------------------- cleanup
for _, id in ipairs(session_ids) do
  exec("DELETE FROM messages WHERE session_id=?", { id })
  exec("DELETE FROM sessions WHERE id=?", { id })
end
exec("DELETE FROM messages WHERE session_id=?", { P })
exec("DELETE FROM sessions WHERE id=?", { P })

print(string.format("turn feed ok (%d checks)", checks))
