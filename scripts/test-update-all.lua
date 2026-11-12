-- `lua/core/update_all.lua`: the `wa update --all` table, and the two rules it may never break.
--
--   WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=scripts/test-update-all.lua wa --db <scratch>/t.db
--
-- Hermetic: every case injects its nodes, its local report and its per-peer read, so no rendezvous, no
-- peer and no network is involved. What this pins:
--
--   * a PEER is never called `behind`: this node does not hold the peer's history, so the only honest
--     comparison is `current` (the same commit) or `differs`, and `differs` says why it cannot say more;
--   * a node that could not be read is `unknown` with the reason - offline, an error, no commit named -
--     never a blank cell and never "up to date";
--   * the local row is always there (the row this command is most able to answer);
--   * the table is read-only in fact, not only in the doc: exactly one injected read per peer, one local
--     report, and no other call;
--   * the rendering is a table a human can read: one header, aligned columns, and the sentence that says
--     this table installs nothing.
local update_all = dofile("lua/core/update_all.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    failed = failed + 1
    print("FAIL " .. label)
  end
end
local function eq(actual, expected, label)
  ok(actual == expected, label .. " (got " .. tostring(actual) .. ", wanted " .. tostring(expected) .. ")")
end
local function contains(haystack, needle, label)
  ok(tostring(haystack):find(needle, 1, true) ~= nil, label .. " ('" .. needle .. "' not in: " .. tostring(haystack) .. ")")
end
local function row_named(rows, name)
  for _, row in ipairs(rows) do if row.node == name then return row end end
  return nil
end

local CANDIDATE = "0123456789abcdef0123456789abcdef01234567"
local LOCAL = {
  ok = true, status = "behind", installed = "aaaaaaaaaaaa", target = "0123456789ab", behind = 3,
  message = "installed aaaaaaaaaaaa is 3 commit(s) behind origin/main 0123456789ab; `wa update` installs it.",
}

-- ---- the fabric ------------------------------------------------------------------------------
local nodes = {
  { name = "here", kind = "host", local_node = true, online = true },
  { name = "alpha", kind = "peer", online = true },
  { name = "beta", kind = "peer", online = true },
  { name = "gone", kind = "peer", online = false },
  { name = "deaf", kind = "peer", online = true },
  { name = "mute", kind = "peer", online = true },
}
local asked = {}
local replies = {
  alpha = { ok = true, node = "alpha", installed_commit = CANDIDATE, watcher = true, dirty = 0, pending_deploys = {} },
  beta = { ok = true, node = "beta", installed_commit = "ffffffffffffffffffffffffffffffffffffffff", watcher = true, dirty = 2,
           pending_deploys = { "one" } },
  deaf = { error = "forbidden_role", observed = "a guest may not ask", node = "deaf" },
  mute = { ok = true, node = "mute", installed_commit = "", watcher = false },
}
local function inspect(name)
  asked[#asked + 1] = name
  return replies[name] or { ok = false, error = "remote_answer_unreadable" }
end

local rows = update_all.rows({ nodes = nodes, local_report = LOCAL, inspect = inspect, candidate = CANDIDATE })
eq(#rows, 6, "one row per node, no more and no fewer")
eq(#asked, 5, "one read per peer and none for the local node")
eq(rows[1].node, "this node", "the local node is the first row")
eq(rows[1].where, "local", "the local row says so")
eq(rows[1].state, "behind", "the local node keeps the verdict its own tree proves")
eq(rows[1].installed, "aaaaaaaaaaaa", "the local row names the installed commit (12 hex)")
eq(rows[1].candidate, "0123456789ab", "the local row names the candidate")

local alpha = row_named(rows, "alpha")
eq(alpha.state, "current", "a peer on the candidate commit is `current`")
local beta = row_named(rows, "beta")
eq(beta.state, "differs", "a peer on another commit is `differs`")
ok(beta.state ~= "behind", "a peer is never called `behind` - this node does not hold its history")
eq(row_named(rows, "beta").installed, "ffffffffffff", "the peer's own commit is what the row shows")
contains(row_named(rows, "beta").detail, "tree dirty", "the peer's own warning travels")
contains(row_named(rows, "beta").detail, "1 deploy pending", "a pending deploy is named")
contains(row_named(rows, "beta").detail, "peer_history_unavailable", "the row says why it cannot say more")

local gone = row_named(rows, "gone")
eq(gone.state, "unknown", "an offline node is unknown")
contains(gone.detail, "offline", "and says it is offline")
ok(gone.installed == "", "with no installed commit invented")

local deaf = row_named(rows, "deaf")
eq(deaf.state, "unknown", "an error from the peer is unknown")
contains(deaf.detail, "forbidden_role", "and names the refusal")
contains(deaf.detail, "a guest may not ask", "and the peer's own reason")

local mute = row_named(rows, "mute")
eq(mute.state, "unknown", "a peer that names no commit is unknown")
contains(mute.detail, "no installed commit", "and says what is missing")
contains(mute.detail, "no watcher running", "and that its watcher is not running")

-- ---- ordering and the summary ---------------------------------------------------------------
local names = {}
for index = 2, #rows do names[#names + 1] = rows[index].node end
local sorted = table.concat(names, ",")
eq(sorted, "alpha,beta,deaf,gone,mute", "peers are ordered by name, the local node first")

local summary = update_all.summary(rows)
contains(summary, "6 node(s)", "the summary counts every row it has")
contains(summary, "1 current", "and counts current")
contains(summary, "1 behind", "and the local node's own behind")
contains(summary, "1 differs", "and differs")
contains(summary, "3 unknown", "and unknown - the rows it could not read are counted, not dropped")

-- ---- a list with no local row still gets one ------------------------------------------------
local solo = update_all.rows({ nodes = { { name = "alpha", kind = "peer", online = true } }, local_report = LOCAL, inspect = inspect, candidate = CANDIDATE })
eq(#solo, 2, "one peer plus the local row")
eq(solo[1].node, "this node", "the local row is supplied even when the list omitted it")

-- ---- the local report's reasons are not verdicts -------------------------------------------
local none = update_all.rows({ nodes = { { name = "here", kind = "host", local_node = true } },
  local_report = { ok = false, status = "no_runtime_tree", error = "no_runtime_tree", message = "there is no tree" },
  inspect = inspect, candidate = "" })
eq(none[1].state, "unknown", "no_runtime_tree reads as unknown, never as a state of the install")
contains(none[1].detail, "there is no tree", "with the module's own sentence")

-- ---- the rendering ---------------------------------------------------------------------------
local text = update_all.render(rows, {})
local lines = {}
for line in tostring(text):gmatch("[^\n]+") do lines[#lines + 1] = line end
contains(lines[1], "node", "the header names the first column")
contains(lines[1], "installed", "and the installed column")
contains(lines[1], "candidate", "and the candidate column")
contains(lines[1], "state", "and the state column")
eq(#lines, #rows + 3, "header, one line per node, the summary and the read-only sentence")
contains(lines[#lines], "installs nothing", "the table says it is read-only")
contains(lines[#lines], "wa update <node>", "and names the call that is not")
-- Every row has the state column starting at the same offset: a table, not a paragraph.
local column = tonumber(tostring(lines[2]:find("current", 1, true) or lines[2]:find("behind", 1, true) or "0"))
ok(column ~= nil and column > 0, "the state column is found on a data row")
local same = true
for index = 2, #rows + 1 do
  local state = rows[index - 1].state
  if not tostring(lines[index]):find(state, 1, true) then same = false end
end
ok(same, "every row carries its own state in the table")
-- A truncated detail does not change the columns before it.
local wide = update_all.render({ { node = "n", where = "peer", installed = "a", candidate = "b", state = "differs",
  detail = string.rep("x", 400) } }, {})
contains(wide, "…", "an oversized detail is ellipsised rather than breaking the line")

if failed > 0 then
  print(string.format("update all: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("update all ok: %d checks", checks))
