-- Turn feed, the operator's door (`wa turns ...`).
--
-- WHY. The `<turn>` note every session ends with is the best evidence this fleet has about its own
-- harness - every real fix began with one - and it was readable only by opening a transcript. This is
-- the reader: collect the notes (this node's own, and every peer's that answers), group the ones that
-- describe the same problem, rank the groups by frequency x cost x recency, and print a mission brief
-- skeleton per group. The engine is `lua/core/turnfeed.lua`; this file is only the words, the flags and
-- the exit status.
--
-- Nothing here is a plan or a promise: it prints what the notes say and measures whether a group has
-- gone quiet since the commit that claims to have fixed it. A group is marked fixed by the operator or
-- the session that landed the fix (`wa turns fixed <id> --sha <commit>`), and the marker is stored on
-- this node (`<config>/turns/fixed.json`), not in a repository.
local json = dofile("lua/vendor/json.lua")
local core = dofile("lua/core/turnfeed.lua")

local M = {}

local USAGE = [==[
wa turns - the model's own harness complaints, grouped into a queue

  wa turns [--since 24h] [--top N] [--json] [--no-peers] [--no-digest] [--nodes a,b]
  wa turns --day YYYY-MM-DD [--top N] [--json]   one day's themes and counts, from the run journal
  wa turns --gate [--since 24h] [--build SHA12] [--json]
                                                 the capture rate: state-changing turns, and how many
                                                 called done_criteria (change/done-gate-trial, item 3)
  wa turns digest [--since 24h]
  wa turns fixed <cluster> --sha <commit> [--note TEXT]
  wa turns unfixed <cluster>
  wa turns markers

Every session ends with a `<turn>` note (what hurt / what it buys / focus). This reads them out of the
ledger - here and, over the mesh, on every peer that answers - and prints the top groups: how many
notes, which nodes, what they name, one quoted line, and a brief (problem / evidence / acceptance).
A group marked fixed shows whether new notes about it are still arriving after that commit.
Notes are redacted at collection: quoted third-party text, addresses, numbers and connector payloads
never reach the report, the digest or a peer.
]==]

local function flag(args, name)
  for index = 2, #args do
    if args[index] == name then return args[index + 1], index end
  end
  return nil
end

local function has(args, name)
  for index = 2, #args do if args[index] == name then return true end end
  return false
end

-- The words that are not an option and not an option's value, in order: the positional arguments.
local function positionals(args, value_flags, from)
  local out = {}
  local index = from or 2
  while index <= #args do
    local token = args[index]
    if value_flags[token] then
      index = index + 2
    elseif token:sub(1, 2) == "--" then
      index = index + 1
    else
      out[#out + 1] = token
      index = index + 1
    end
  end
  return out
end

local function refused(message)
  print("wa turns: " .. message)
  return 2
end

local VALUED = { ["--since"] = true, ["--top"] = true, ["--nodes"] = true, ["--sha"] = true,
  ["--note"] = true, ["--day"] = true, ["--limit"] = true, ["--build"] = true }

-- One collection, shared by every verb that reports: the local notes plus every peer that answered.
local function collect(args)
  local since_text = flag(args, "--since")
  local since, problem = core.parse_since(since_text, host.now())
  if problem then return nil, nil, nil, problem end
  local nodes_wanted = nil
  local picked = flag(args, "--nodes")
  if picked and picked ~= "" then
    nodes_wanted = {}
    for name in tostring(picked):gmatch("[^,]+") do nodes_wanted[(name:gsub("^%s+", ""):gsub("%s+$", ""))] = true end
  end
  local limit = tonumber(flag(args, "--limit") or "") or core.MAX_NOTES
  local notes = core.notes({ since = since, limit = limit })
  local failures = {}
  if not has(args, "--no-peers") then
    local peer_notes, peer_failures = core.peer_notes({ since = since, since_text = since_text,
      limit = limit, nodes = nodes_wanted })
    for _, note in ipairs(peer_notes) do notes[#notes + 1] = note end
    failures = peer_failures or {}
  end
  table.sort(notes, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    if a.session ~= b.session then return a.session < b.session end
    return a.seq < b.seq
  end)
  return notes, failures, since_text, nil
end

local function node_names(notes)
  local set = {}
  for _, note in ipairs(notes) do set[note.node] = true end
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  table.sort(list)
  return list
end

local function ranked(args)
  local notes, failures, since_text, problem = collect(args)
  if problem then return nil, problem end
  local markers = core.fixed()
  local clusters = core.rank(core.clusters_of(notes), {})
  return { notes = notes, failures = failures, since_text = since_text, markers = markers,
    clusters = clusters, nodes = node_names(notes) }, nil
end

local function report(args)
  local bundle, problem = ranked(args)
  if not bundle then return refused(problem) end
  local top = tonumber(flag(args, "--top") or "") or 10
  local lines = core.report({
    clusters = bundle.clusters, markers = bundle.markers, note_count = #bundle.notes,
    nodes = bundle.nodes, failures = bundle.failures, since_text = bundle.since_text, top = top,
  })
  if flag(args, "--json") then
    local records = {}
    for index, cluster in ipairs(bundle.clusters) do
      if index <= top then
        local status = core.status(cluster, bundle.markers)
        records[#records + 1] = {
          id = cluster.id, count = cluster.count, nodes = cluster.nodes, cost = cluster.cost,
          score = cluster.score, recency = cluster.recency, newest = cluster.newest,
          named = cluster.named, files = cluster.files,
          quote = cluster.notes[#cluster.notes].quote,
          sessions = cluster.sessions,
          status = status.state, after = status.after, sha = status.sha,
        }
      end
    end
    print(json.encode({ schema = core.SCHEMA, node = core.node_name(), notes = #bundle.notes,
      nodes_seen = bundle.nodes, clusters = records, failures = bundle.failures }))
  else
    for _, line in ipairs(lines) do print(line) end
  end
  if not has(args, "--no-digest") then
    local path, written = core.digest({ clusters = bundle.clusters, markers = bundle.markers,
      note_count = #bundle.notes, nodes = bundle.nodes, since_text = bundle.since_text })
    if written then
      print("digest: " .. path)
    else
      print("digest: not written (" .. tostring(path) .. ")")
    end
  end
  return 0
end

local function digest(args)
  local bundle, problem = ranked(args)
  if not bundle then return refused(problem) end
  local path, written = core.digest({ clusters = bundle.clusters, markers = bundle.markers,
    note_count = #bundle.notes, nodes = bundle.nodes, since_text = bundle.since_text })
  if not written then return refused("digest not written: " .. tostring(path)) end
  print(path)
  return 0
end

local function markers_list()
  local store = core.fixed()
  local ids = {}
  for id in pairs(store) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then
    print("(no cluster is marked fixed: wa turns fixed <cluster> --sha <commit>)")
    return 0
  end
  for _, id in ipairs(ids) do
    local marker = store[id]
    print(string.format("%-10s %s  %s  %s", id, string.sub(tostring(marker.sha or "?"), 1, 12),
      core.when(marker.at), tostring(marker.note or "")))
  end
  return 0
end

local function fixed(args)
  local words = positionals(args, VALUED, 3)
  local cluster = words[1]
  if not cluster then return markers_list() end
  local sha = flag(args, "--sha")
  if not sha then return refused("fixed needs the commit that claims it: --sha <commit>") end
  local marker, problem = core.mark_fixed(cluster, sha, { note = flag(args, "--note") })
  if not marker then return refused(problem or "the marker could not be written") end
  print(string.format("%s marked fixed by %s (%s, %s)", marker.cluster, string.sub(marker.sha, 1, 12),
    core.when(marker.at), marker.at_source == "commit" and "commit time" or "mark time: no repository here"))
  return 0
end

local function unfixed(args)
  local words = positionals(args, VALUED, 3)
  local cluster = words[1]
  if not cluster then return refused("unfixed needs a cluster id (wa turns markers lists them)") end
  local ok, problem = core.unmark_fixed(cluster)
  if not ok then return refused(problem or "the marker could not be removed") end
  print(cluster .. " is no longer marked fixed")
  return 0
end

-- change/done-gate-trial, item 3: the capture rate, and the side of the 30% rule it falls on.
--
-- The threshold is printed WITH the number, because the number is only worth what it is compared to,
-- and it is printed as the rule's own words: fewer than 30% deletes the gate, 30% or more keeps it
-- reduced to what is used. This verb does not decide anything - the operator's rule is applied by the
-- orchestrator after a day of missions - it measures.
local function gate_report(args)
  local since_text = flag(args, '--since')
  local since, problem = core.parse_since(since_text, host.now())
  if problem then return refused(problem) end
  local build = flag(args, '--build')
  local stats = core.gate_stats({ since = since, build = build })
  local window = since_text and since_text ~= '' and since_text or 'all time'
  if build and build ~= '' then window = window .. ', build ' .. tostring(build) end
  if stats.changed == 0 then
    -- Unknown is not zero: no event is not the same as a measured 0%, and the rule deletes a gate on
    -- evidence, so this says which fact is missing rather than printing a number.
    if has(args, '--json') then
      print(json.encode({ available = stats.available, since = window, events = stats.events,
        changed = 0, called = 0, percent = nil, reason = 'no_state_changing_turn' }))
    else
      print(string.format('wa turns --gate (%s): no state-changing turn recorded yet', window))
      if build and build ~= '' then
        -- Review r1, fix 5: a build filter that matched nothing must not read like a measured zero, and
        -- it must say what it excluded - a turn with no build stamp is unknown, not this build.
        print(string.format('  %d event(s) read; %d carried no build stamp and %d were another build',
          stats.events, stats.skipped_unknown_build or 0, stats.mismatched_build or 0))
      end
      print('the run journal holds ' .. tostring(stats.events) .. ' gate event(s); the capture rate is unmeasured, not 0%')
    end
    return 0
  end
  local percent = stats.percent
  local verdict = percent < 30 and 'below 30%' or '30% or more'
  if has(args, '--json') then
    print(json.encode({ available = true, since = window, events = stats.events, changed = stats.changed,
      called = stats.called, percent = math.floor(percent * 10 + 0.5) / 10, sessions = stats.sessions,
      threshold = 30, side = verdict, build = stats.build,
      skipped_unknown_build = stats.skipped_unknown_build, mismatched_build = stats.mismatched_build }))
    return 0
  end
  local lines = {}
  lines[#lines + 1] = string.format('wa turns --gate (%s): %d state-changing turn(s) from %d session(s)',
    window, stats.changed, stats.sessions)
  lines[#lines + 1] = string.format('  %d called done_criteria: %.1f%%', stats.called, percent)
  lines[#lines + 1] = '  rule: fewer than 30% deletes the done gate; 30% or more keeps it, reduced to what is used'
  lines[#lines + 1] = '  this run is ' .. verdict
  print(table.concat(lines, "\n"))
  return 0
end

-- One day's notes from the RUN JOURNAL (#33), as themes and counts: what the models said hurt the
-- harness on that day, grouped by the words they used, plus the build/mode they said it on. This is
-- the roll-up docs/evolution is written from, and it reads the journal rather than the transcripts so
-- it answers even for a session whose rows were compacted.
local function day_report(args)
  local day = flag(args, "--day")
  local journal = dofile("lua/core/turn_journal.lua")
  local from, problem = journal.day_bounds(day)
  if not from then return refused(problem or "turn_day_must_be_YYYY-MM-DD") end
  local limit = tonumber(flag(args, "--limit") or "") or 500
  local notes = journal.recent({ day = day, limit = limit })
  if #notes == 0 then
    print(string.format("wa turns --day %s: no note in the run journal for that day", day))
    return 0
  end
  -- Item 4: a bounded page is not the whole day. Asking the store for the exact count is what lets
  -- the report SAY it stopped, instead of presenting 500 of 5000 notes as the day's themes.
  local total = journal.count_day(day) or #notes
  local stopped = total > #notes
  -- The themes: the words the notes used, counted once per note, with the words that are the shape of
  -- prose removed. Not a clustering engine - the grouping lives in lua/core/turnfeed.lua - this is the
  -- day's vocabulary so a reader can see what the day was about before opening a mission.
  local STOP = {}
  -- gmatch, not a bare string: a generic for needs an iterator function, and passing the word list
  -- itself raised "attempt to call a string value" on the first run of this verb (found 19/11 while
  -- checking item 2 - the report had never been executed, only written).
  for word in ([[the a an and or but if then than that this these those it its is are was were be been
    being of to in on at for with from by as not no nor so such only also just very more most less least
    i we you they he she them us our your my me his her their there here what which who whom whose when
    where why how all any both each few many some own same too can will would should could may might must
    do does did doing done have has had having one two three first next last step steps turn turns round
    rounds token tokens context line lines code block blocks file files wasm agent harness]]):gmatch("%S+") do STOP[word] = true end
  local themes, order = {}, {}
  local by_build, by_mode, by_session = {}, {}, {}
  for _, row in ipairs(notes) do
    local text = tostring(row.hurts or "") .. " " .. tostring(row.focus or "")
    local seen = {}
    for word in text:lower():gmatch("[%a][%w_%-%./]+") do
      local key = word:gsub("[%.,;:]+$", "")
      if #key >= 4 and not STOP[key] and not seen[key] then
        seen[key] = true
        if not themes[key] then themes[key] = 0; order[#order + 1] = key end
        themes[key] = themes[key] + 1
      end
    end
    local build = tostring(row.build or "")
    by_build[build ~= "" and build or "(unknown build)"] = (by_build[build ~= "" and build or "(unknown build)"] or 0) + 1
    local mode = tostring(row.mode or "")
    by_mode[mode ~= "" and mode or "(no code mode)"] = (by_mode[mode ~= "" and mode or "(no code mode)"] or 0) + 1
    by_session[tostring(row.session_id or "")] = true
  end
  local ranked = {}
  for _, key in ipairs(order) do ranked[#ranked + 1] = { word = key, count = themes[key] } end
  table.sort(ranked, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.word < b.word
  end)
  local sessions = 0
  for _ in pairs(by_session) do sessions = sessions + 1 end
  local function counts(map)
    local list = {}
    for key, value in pairs(map) do list[#list + 1] = { key = key, count = value } end
    table.sort(list, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.key < b.key end)
    return list
  end
  -- has(), not flag(): flag() answers the argument AFTER the name, so a trailing --json read as nil
  -- and the text report was printed instead (found 19/11 while checking item 2).
  if has(args, "--json") then
    print(json.encode({ day = day, notes = #notes, total = total, truncated = stopped or nil,
      sessions = sessions, themes = ranked, builds = counts(by_build), modes = counts(by_mode) }))
    return 0
  end
  local lines = {}
  lines[#lines + 1] = string.format("wa turns --day %s: %d note(s) from %d session(s)", day, #notes, sessions)
  if stopped then
    lines[#lines + 1] = string.format(
      "read the newest %d of %d note(s) that day (--limit raises the page, up to 500)", #notes, total)
  end
  if #ranked == 0 then
    -- Item 4: a day whose notes carry no countable word is a day, not a crash. The old loop indexed
    -- ranked[1] and failed with "attempt to index a nil value" on a note of only stop words.
    lines[#lines + 1] = "themes: none (no word in these notes survived the stop list)"
  else
    local top = math.max(1, math.min(tonumber(flag(args, "--top") or "") or 15, #ranked))
    lines[#lines + 1] = "themes (a word counted once per note):"
    for index = 1, top do
      lines[#lines + 1] = string.format("  %3d  %s", ranked[index].count, ranked[index].word)
    end
  end
  lines[#lines + 1] = "builds:"
  for _, entry in ipairs(counts(by_build)) do lines[#lines + 1] = string.format("  %3d  %s", entry.count, entry.key) end
  lines[#lines + 1] = "modes:"
  for _, entry in ipairs(counts(by_mode)) do lines[#lines + 1] = string.format("  %3d  %s", entry.count, entry.key) end
  print(table.concat(lines, "\n"))
  return 0
end

function M.run(args)
  local verb = args[2]
  -- --day is a verb in disguise, and it has to be answered before the "no verb" branch below: that
  -- branch takes every leading -- to the all-time report, which is how "wa turns --day 2026-11-18"
  -- used to print the whole ledger and never the day (review 19/11, item 2).
  if has(args, "--gate") or verb == "gate" then
    if has(args, "--help") or has(args, "-h") then print(USAGE); return 0 end
    return gate_report(args)
  end
  if has(args, "--day") or verb == "day" then
    if has(args, "--help") or has(args, "-h") then print(USAGE); return 0 end
    return day_report(args)
  end
  if verb == nil or verb:sub(1, 2) == "--" then
    if has(args, "--help") or has(args, "-h") then print(USAGE); return 0 end
    return report(args)
  end
  if verb == "help" then print(USAGE); return 0 end
  if verb == "digest" then return digest(args) end
  if verb == "fixed" then return fixed(args) end
  if verb == "unfixed" then return unfixed(args) end
  if verb == "markers" then return markers_list() end
  return refused("unknown verb '" .. tostring(verb) .. "': turns [--since ...] | digest | fixed | unfixed | markers")
end

M.USAGE = USAGE

return M
