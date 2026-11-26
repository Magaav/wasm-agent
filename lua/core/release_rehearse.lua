-- `wa release rehearse` (Fable 26/11): run the cut own gates against the real fleet, and change NOTHING.
--
-- The v0.1.2 cut met five gate defects in a row and found each one mid-cut: the deploy-wait read, the deploy wait
-- calling a finished install unknown, release-update on a tree-less node, a refusal read as no_data, and the
-- CLI-vs-serving-node reads. Every one was in the gate, not the product. This module runs the reads a cut runs -
-- each ring node own record (the deploy-wait read) and every canary - and prints the report in the shape of the
-- cut canary step, so those defects surface BEFORE a tag exists.
--
-- READ-ONLY BY CONSTRUCTION: it calls remote_update.status (a status read, never a request), the roster, and
-- `wa features canary json` on a node. It does not build, tag, publish, push or deploy, and it never asks a node
-- to update itself - a rehearsal that moved the fleet would be the thing it exists to prevent. (The row greps this
-- file for that call, so a comment must not name it either.)
local M = {}

M.TASK_DEADLINE_S = 300

local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end

-- The ring this rehearsal reads, read-only: this node first, then the roster peers. An unreadable roster is
-- NOT an empty fleet - it is a refusal, because a rehearsal that asked nobody must never be green.
function M.ring(options)
  options = type(options) == "table" and options or {}
  if type(options.ring) == "table" then return options.ring end
  local loaded, nodes = pcall(dofile, "lua/core/nodes.lua")
  if not loaded or type(nodes) ~= "table" then
    return nil, "the roster (lua/core/nodes.lua) could not be read, so no node was read"
  end
  local ring = { { node = "this node", mode = "local" } }
  local listed = (type(nodes.list) == "function" and nodes.list({}))
    or (type(nodes.peers) == "function" and nodes.peers({})) or {}
  for _, entry in ipairs(type(listed) == "table" and listed or {}) do
    local name = tostring((type(entry) == "table" and (entry.name or entry.node)) or entry or "")
    if trim(name) ~= "" and trim(name) ~= "this node" then
      ring[#ring + 1] = { node = name, mode = tostring((type(entry) == "table" and entry.mode) or "peer") }
    end
  end
  return ring
end

-- One row of the report: the node state, the commit it names, and whether the read answered at all. A refused
-- read is `unknown` with the error kept, never a silent blank.
function M.record_row(node, status)
  status = type(status) == "table" and status or {}
  local row = { node = tostring(node), state = tostring(status.state or "unknown") }
  row.commit = trim(status.installed_commit or status.commit or "")
  row.error = trim(status.error or "")
  if row.error ~= "" then
    row.relation = "unknown"
    row.detail = "the read was refused: " .. row.error
  elseif row.commit == "" then
    row.relation = "unknown"
    row.detail = "the node answered no commit"
  else
    row.relation = "named"
    row.detail = "the node names " .. row.commit:sub(1, 12)
  end
  return row
end

-- THE MODE PREFLIGHT (26/11, Fable, from the v0.1.2 (c) stop). Two refusals a cut meets AFTER the deploy step has
-- started are decided BEFORE it starts, from the node own facts and never from a guess:
--
--   no_runtime_tree  a tree-less node asked for tree mode (lua/core/remote_update.lua:578): it must be asked
--                    for release mode - the published binary - or the deploy refuses before doing anything.
--   canonical_busy   a tree node whose HEAD is not exactly origin/main (scripts/deploy.sh:600): a tree deploy
--                    refuses until the checkout IS main, which is exactly what stopped v0.1.2 (c) while a train
--                    landing moved main to ec7525e0 under a cut that targets T5 4c6557f4. Release mode does not
--                    read the checkout at all, so it is the answer for that node.
--
-- A fact the node answer does not carry is `unchecked`, and unchecked is never green.
-- <ring>, <facts_of(node) -> { mode, tree, head, origin_main } | nil> -> { rows, red }
function M.mode_preflight(ring, facts_of)
  local rows, red = {}, {}
  for _, entry in ipairs(type(ring) == "table" and ring or {}) do
    local node = tostring((type(entry) == "table" and entry.node) or entry or "?")
    local mode = tostring((type(entry) == "table" and entry.mode) or "tree")
    local facts = nil
    if type(facts_of) == "function" then
      local ok, answer = pcall(facts_of, node)
      facts = ok and type(answer) == "table" and answer or nil
    end
    local row = { node = node, mode = tostring(facts and facts.mode or mode) }
    local allowed = { tree = true, release = true, binary = true, rollback = true }
    if not allowed[row.mode] then
      row.verdict, row.error = "refuse", "mode_unknown"
      row.detail = "the ring names mode " .. row.mode .. " and a node accepts only tree, binary, release or rollback"
    elseif row.mode == "release" then
      row.verdict = "ok"
      row.detail = "release install: the published binary, no checkout read, no tree moved"
    elseif not facts then
      row.verdict = "unchecked"
      row.detail = "the node answer did not carry its tree and HEAD, so the " .. row.mode .. " mode was not judged"
    elseif not facts.tree or tostring(facts.tree) == "" then
      row.verdict, row.error = "refuse", "no_runtime_tree"
      row.detail = "this node has no tree, so tree mode cannot deploy it; ask it for release mode (wa update " .. node .. " --release --commit <sha>)"
      red[#red + 1] = node .. " (no_runtime_tree)"
    elseif tostring(facts.head or "") ~= "" and tostring(facts.origin_main or "") ~= "" then
      if tostring(facts.head) ~= tostring(facts.origin_main) then
        row.verdict, row.error = "refuse", "canonical_busy"
        row.detail = "its HEAD is " .. tostring(facts.head):sub(1, 12) .. ", not origin/main " .. tostring(facts.origin_main):sub(1, 12)
          .. " - a tree deploy refuses (scripts/deploy.sh:600); release mode does not read the checkout"
        red[#red + 1] = node .. " (canonical_busy)"
      else
        row.verdict = "ok"
        row.detail = "its HEAD is origin/main, so tree mode can deploy it"
      end
    else
      row.verdict = "unchecked"
      row.detail = "its HEAD and origin/main were not both reported, so canonical_busy was not judged"
    end
    rows[#rows + 1] = row
  end
  table.sort(red)
  return { rows = rows, red = red }
end
-- THE TWO INSTALL HAZARDS (26/11, Fable, from the ring-mode answer). Both are consequences of what a RELEASE
-- install does NOT do, and both are checked here by name so a rehearsal cannot be green while either is true:
--
-- 1. lua_core_shadows_release - REFUSE. A release install lays down the binary and nothing else of the Lua tree
--    (upgrade.sh / release-install.sh never stage lua-core; that is deploy.sh:1566-1831). So an <install>/lua-core
--    left by an earlier deploy keeps outranking the embedded copy, as long as its manifest verifies against the
--    new binary (rust/wa-host/src/main.rs:75-100: manifest sha256s + equal capability digest). The node then runs
--    OLD Lua on NEW bytes - the exact opposite of what "install T5" means.
--
-- 2. release_update_reads_tree - WARN, never silent. build_status.relation compares the BINARY with the TREE
--    whenever a tree is readable; only the tree-less branch (r4) reads the install record. A release-installed
--    node that still has a checkout therefore answers `stale` in the release-update canary while running exactly
--    the release it was given. The bytes are right and the JUDGE is wrong, so this is named and listed as a
--    warning, not a refusal - a rehearsal that went red on the judge would be crying wolf about a healthy node.
--
-- A fact the answer does not carry is `unchecked`, and unchecked is never green.
-- <ring>, <facts_of(node) -> table | nil> -> { rows, red, warned }
function M.install_checks(ring, facts_of)
  local rows, red, warned = {}, {}, {}
  for _, entry in ipairs(type(ring) == "table" and ring or {}) do
    local node = tostring((type(entry) == "table" and entry.node) or entry or "?")
    local facts = nil
    if type(facts_of) == "function" then
      local ok, answer = pcall(facts_of, node)
      facts = ok and type(answer) == "table" and answer or nil
    end
    local row = { node = node }
    if not facts then
      row.verdict, row.detail = "unchecked", "the node answer carried neither its install dir nor its tree"
    else
      local lua_core = facts.lua_core
      local from_release = tostring(facts.installed_from or "") == "release"
      if lua_core == nil then
        row.verdict, row.detail = "unchecked", "the node did not say whether <install>/lua-core is present"
      elseif from_release and (lua_core == true or tostring(lua_core) == "present") then
        row.verdict, row.error = "refuse", "lua_core_shadows_release"
        row.detail = "a release install does not stage <install>/lua-core, and the copy left by an earlier deploy"
          .. " outranks the embedded Lua when its manifest still verifies (main.rs:75-100): this node would run OLD"
          .. " Lua on the NEW binary. Remove it (deploy.sh keeps lua-core.prev) or stage lua-core from the bundle"
        red[#red + 1] = node .. " (lua_core_shadows_release)"
      else
        row.verdict = "ok"
        row.detail = from_release and "release install with no <install>/lua-core to outrank the embedded copy"
          or "this node is not a release install, so the embedded copy is not the one that would be shadowed"
      end
      -- hazard 2, only where a tree is readable AND the node was installed from a release
      local binary = tostring(facts.binary_commit or "")
      local tree = tostring(facts.tree_commit or "")
      if from_release and tostring(facts.tree or "") ~= "" and binary ~= "" and tree ~= "" and binary ~= tree then
        row.canary = "release_update_reads_tree"
        warned[#warned + 1] = node .. " (release_update_reads_tree: binary " .. binary:sub(1, 12)
        warned[#warned] = warned[#warned] .. " vs tree " .. tree:sub(1, 12) .. ")"
      end
    end
    rows[#rows + 1] = row
  end
  table.sort(red); table.sort(warned)
  return { rows = rows, red = red, warned = warned }
end
-- <options> -> { lines, ok, rows, answers, failed, off, listed, cutting, red, unreachable }
--   options.ring          the ring to read (default: this node + the roster)
--   options.read(node)    a status answer for one node (default: remote_update.status)
--   options.canaries(node) -> { features = {...} } (default: `wa features canary json` on that node)
--   options.local_results this node own canary results (default: feature_canary.run_all)
function M.rehearse(options)
  options = type(options) == "table" and options or {}
  local canaries = dofile("lua/core/feature_canary.lua")
  local land = dofile("lua/core/land.lua")
  local ring, why = M.ring(options)
  if not ring then
    return { ok = false, lines = { "rehearse: RED - " .. tostring(why) }, red = { tostring(why) },
      failed = {}, listed = {}, cutting = {}, rows = {} }
  end
  -- THE MESH SEAM (one place a fixture replaces, as land does for the deploy step): the default read and the
  -- default canary ask both go through it, so a row can drive the REAL default path against a scratch ring.
  local mesh = options.remote_call or M.remote_call
  local read = options.read
  if type(read) ~= "function" then
    local remote_update = dofile("lua/core/remote_update.lua")
    local call = options.call or mesh
    if type(call) ~= "function" then
      local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
      call = ok and nodes.remote_call or nil
    end
    read = function(node) return remote_update.status(call, node, {}) end
  end
  local ask = options.canaries
  if type(ask) ~= "function" then
    ask = function(node)
      local ok, nodes = pcall(dofile, "lua/core/nodes.lua")
      if not ok or type(nodes.remote_call) ~= "function" then return nil end
      local caller = mesh or nodes.remote_call
      local answer = caller(node, "bash", { command = "wa features canary json" }, {})
      if type(answer) ~= "table" then return nil end
      local text = answer.stdout or answer.output or answer.text
      if type(text) ~= "string" then return nil end
      local ok_json, document = pcall(dofile("lua/vendor/json.lua").decode, text)
      return ok_json and document or nil
    end
  end
  local local_answer = options.local_results
  if type(local_answer) ~= "table" then
    local ran, results = canaries.run_all({ cutting = true })
    local_answer = { results = type(results) == "table" and results or (type(ran) == "table" and ran) or {} }
  end

  local rows, answers, unreachable = {}, {}, {}
  answers[1] = { node = "this node", results = type(local_answer.results) == "table" and local_answer.results or {} }
  for _, entry in ipairs(ring) do
    local name = tostring((type(entry) == "table" and entry.node) or entry or "?")
    local row
    if name == "this node" then
      -- THIS NODE IS NOT ASKED OVER THE MESH (a peer call to itself answers unknown_node): its row comes from the
      -- binary it runs and the record it was installed with - the same identity the cut reads on a release node.
      local build = dofile("lua/core/build_status.lua")
      local ok_local, local_status = pcall(build.status)
      local mine = ok_local and type(local_status) == "table" and local_status or {}
      row = M.record_row(name, { state = tostring(mine.relation or "unknown"),
        installed_commit = tostring(build.recorded_commit() or "") })
      row.relation = tostring(mine.relation or row.relation)
      if tostring(mine.why or "") ~= "" then row.detail = tostring(mine.why) end
    else
      local ok_read, status = pcall(read, name)
      row = M.record_row(name, ok_read and status or nil)
      if not ok_read then unreachable[#unreachable + 1] = name .. " (the read raised)" end
      local ok_ask, document = pcall(ask, name)
      if ok_ask and type(document) == "table" and type(document.features) == "table" then
        answers[#answers + 1] = { node = name, results = document.features }
      else
        unreachable[#unreachable + 1] = name .. " (its canaries did not arrive)"
      end
    end
    row.mode = tostring((type(entry) == "table" and entry.mode) or (name == "this node" and "local") or "peer")
    rows[#rows + 1] = row
  end

  local aggregated = canaries.aggregate(answers)
  local not_proven = land.release_not_proven(aggregated)
  local passed, off = 0, #aggregated.off
  for _, answer in ipairs(answers) do
    for _, one in ipairs(answer.results or {}) do
      if one.ok and not one.skipped then passed = passed + 1 end
    end
  end

  local lines = {}
  lines[#lines + 1] = string.format(
    "rehearse: %d node(s) read; canaries %d passed, %d failed, %d off, %d not proven (listed), %d cutting not proven",
    #rows, passed, #aggregated.failed, off, #not_proven.listed, #not_proven.cutting)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("  %-18s %-7s %-12s %s%s", row.node, row.mode, row.state,
      row.commit ~= "" and row.commit:sub(1, 12) or "-", row.detail and (" - " .. row.detail) or "")
  end
  for _, line in ipairs(canaries.lines(answers[1].results or {})) do lines[#lines + 1] = line end
  if #not_proven.listed > 0 then
    lines[#lines + 1] = "NOT PROVEN ON ANY NODE"
    for _, line in ipairs(not_proven.listed) do lines[#lines + 1] = "  " .. line end
  end

  -- THE MODES ARE JUDGED BEFORE THE DEPLOY STEP (26/11): a node that cannot take the mode the ring names is
  -- named here, not 186 s into a deploy (canonical_busy) or after the node refused a tree it does not have.
  -- THE TWO INSTALL HAZARDS, by name (26/11, Fable): see M.install_checks.
  local install = M.install_checks(ring, options.facts_of)
  for _, row in ipairs(install.rows) do
    if row.verdict ~= "ok" then
      lines[#lines + 1] = string.format("  install %-18s %s - %s", row.node, row.verdict, tostring(row.detail or ""))
    end
  end
  if #install.warned > 0 then
    lines[#lines + 1] = "WARNINGS (named, not red: the bytes are right and the judge is wrong)"
    for _, entry in ipairs(install.warned) do lines[#lines + 1] = "  " .. entry end
  end
  local preflight = M.mode_preflight(ring, options.facts_of)
  for _, row in ipairs(preflight.rows) do
    if row.verdict ~= "ok" then
      lines[#lines + 1] = string.format("  mode %-8s %-18s %s - %s", row.mode, row.node, row.verdict, tostring(row.detail or ""))
    end
  end
  local red = {}
  for _, entry in ipairs(unreachable) do red[#red + 1] = entry end
  for _, entry in ipairs(aggregated.failed) do red[#red + 1] = entry end
  for _, entry in ipairs(not_proven.cutting) do red[#red + 1] = entry end
  for _, entry in ipairs(preflight.red) do red[#red + 1] = entry end
  for _, entry in ipairs(install.red) do red[#red + 1] = entry end
  -- A READ THAT WAS REFUSED IS NOT A GREEN NODE: the rehearsal may not claim a fleet it could not read.
  for _, row in ipairs(rows) do
    if row.error ~= "" then red[#red + 1] = row.node .. " (" .. row.error .. ")" end
  end
  table.sort(red)
  local ok = #red == 0
  lines[#lines + 1] = ok and "rehearse: GREEN - the cut gates pass on this fleet"
    or ("rehearse: RED - " .. table.concat(red, "; "))
  return { ok = ok, lines = lines, rows = rows, answers = answers, failed = aggregated.failed,
    off = aggregated.off, listed = not_proven.listed, cutting = not_proven.cutting, red = red,
    unreachable = unreachable }
end

-- `wa release rehearse` - the report and an exit code. `--json` prints the same verdict as JSON.
function M.run(argv, options)
  argv = type(argv) == "table" and argv or {}
  local want_json = false
  for _, arg in ipairs(argv) do if tostring(arg) == "--json" then want_json = true end end
  local answer = M.rehearse(options)
  if want_json then
    print(dofile("lua/vendor/json.lua").encode({ ok = answer.ok, red = answer.red, failed = answer.failed,
      listed = answer.listed, cutting = answer.cutting, rows = answer.rows }))
  else
    for _, line in ipairs(answer.lines) do print(line) end
  end
  return answer.ok and 0 or 1
end

return M
