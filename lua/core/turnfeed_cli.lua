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
  ["--note"] = true }

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

function M.run(args)
  local verb = args[2]
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
