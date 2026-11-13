-- `wa clean`: one command over the node's one root (`docs/ONEROOT.md`).
--
-- WHY. One morning of agents on wa-desktop left ~100 GB behind: worktrees ~45 GB scattered as `~/wt-*`,
-- per-mission build dirs ~25 GB, `/tmp` 3.3 GB, mission logs 0.8 GB - while the node's own state was
-- 0.4 GB. Nothing cleaned up, and no command could even say what was reclaimable. The rule that fixes
-- it is one root, one command, one cap: everything an agent creates lives under `<home>/.wasm-agent`,
-- this command is what reclaims it, and a cap refuses new heavy work instead of filling the disk.
--
-- The rules live in Rust (`rust/wa-capabilities/src/disk.rs`, capability `disk`) because a deletion
-- policy must not be something a script or a model can re-implement. This file is the CLI: argument
-- parsing, the table the operator reads, and the one config write `--cap` makes.
local json = dofile("lua/vendor/json.lua")

local M = {}

-- ---- measuring for the reader ----------------------------------------------------------------
local function bytes(n)
  n = tonumber(n) or 0
  if n >= 1024 ^ 3 then return string.format("%.1fG", n / 1024 ^ 3) end
  if n >= 1024 ^ 2 then return string.format("%.1fM", n / 1024 ^ 2) end
  if n >= 1024 then return string.format("%.1fk", n / 1024) end
  return string.format("%d", n)
end

local function when_epoch(epoch)
  epoch = tonumber(epoch)
  if not epoch then return "unknown" end
  -- The record is written in epoch seconds by the host; the reader gets UTC, labelled as such.
  return os.date("!%Y-%m-%d %H:%M UTC", epoch)
end

local function ask(action, args)
  if type(host) ~= "table" or host.disk == nil then
    return nil, "this host has no host.disk(): it predates the one root (docs/ONEROOT.md)"
  end
  local ok, result = pcall(host.disk, action, json.encode(args or {}))
  if not ok then return nil, tostring(result) end
  if type(result) == "string" then
    local decoded_ok, decoded = pcall(json.decode, result)
    if not decoded_ok then return nil, "host.disk answered text that is not JSON" end
    result = decoded
  end
  if type(result) ~= "table" then return nil, "host.disk answered no table" end
  if result.ok == false then return nil, tostring(result.error or "unknown error") end
  return result
end

-- ---- the line `wa status` prints -------------------------------------------------------------
--
-- The facts rule 4 asks a node to publish about itself: how big the root is, how full its filesystem
-- is against the cap, and when the last clean ran and what it freed. One line, because `wa status` is
-- a page of one-line facts.
function M.status_line()
  local answer, err = ask("status")
  if not answer then return "unavailable - " .. tostring(err) end
  local parts = { string.format("%s in %s", bytes(answer.bytes), tostring(answer.root)) }
  local disk = answer.disk
  if type(disk) == "table" then
    parts[#parts + 1] = string.format("disk %.0f%% of %s (cap %.0f%%%s)", tonumber(disk.used_percent) or 0,
      bytes(disk.total_bytes), tonumber(answer.cap_percent) or 0, answer.over_cap and ", OVER" or "")
  else
    parts[#parts + 1] = "disk unmeasured (" .. tostring(answer.disk_reason or "no reason given") .. ")"
  end
  local last = answer.last_clean
  if type(last) == "table" then
    parts[#parts + 1] = string.format("last clean %s, freed %s", when_epoch(last.at), bytes(last.freed_bytes))
  else
    parts[#parts + 1] = "last clean never"
  end
  return table.concat(parts, "  \194\183  ")
end

-- ---- the cap write ----------------------------------------------------------------------------
--
-- The cap is read from the node's own config file (`<config>/env`, KEY=VALUE, read at startup), so
-- `--cap` edits that one key and nothing else, and says when it takes effect. A cap that only applied
-- to the process that typed it would be a cap that never protected a build.
local CAP_KEY = "WASM_AGENT_DISK_CAP"

function M.set_cap(percent)
  local paths = dofile("lua/core/paths.lua")
  local file = paths.config_file()
  local text = (host.read_file and host.read_file(file)) or ""
  local lines, found = {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" and not found and text == "" then
      -- nothing to carry over
    elseif line:match("^%s*" .. CAP_KEY .. "%s*=") then
      lines[#lines + 1] = CAP_KEY .. "=" .. tostring(percent)
      found = true
    else
      lines[#lines + 1] = line
    end
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  if not found then lines[#lines + 1] = CAP_KEY .. "=" .. tostring(percent) end
  local written = table.concat(lines, "\n") .. "\n"
  local ok, err = pcall(host.write_file, file, written)
  if not ok then return nil, "cannot write " .. file .. ": " .. tostring(err) end
  return file
end

-- ---- the session guard ------------------------------------------------------------------------
--
-- A new session is new work (`docs/ONEROOT.md`, rule 4). Called from `wa` before a chat starts: under
-- the cap it costs one measurement; over it the node runs this same clean first and says so; if that
-- cannot get under the cap, the session is refused by name.
function M.guard(trigger)
  local answer, err = ask("guard", { trigger = trigger or "session" })
  if answer then
    if answer.cleaned then
      print(string.format("wa: the root was %.0f%% full (cap %.0f%%); cleaned %s before this %s",
        tonumber(answer.used_percent_before) or 0, tonumber(answer.cap_percent) or 0,
        bytes(answer.freed_bytes), trigger or "session"))
      if answer.note then print("    " .. tostring(answer.note)) end
    end
    return true
  end
  print("wa: " .. tostring(err))
  print("    wa clean --dry-run    what is left, and why it is kept")
  return false
end

-- ---- the command ------------------------------------------------------------------------------
local function print_status(answer)
  print(string.format("root        %s  %s  %d files", bytes(answer.bytes), tostring(answer.root), tonumber(answer.files) or 0))
  local disk = answer.disk
  if type(disk) == "table" then
    print(string.format("disk        %.1f%% used of %s, %s free  (cap %.0f%%%s)",
      tonumber(disk.used_percent) or 0, bytes(disk.total_bytes), bytes(disk.free_bytes),
      tonumber(answer.cap_percent) or 0, answer.over_cap and ", OVER the cap" or ""))
  else
    print("disk        unmeasured: " .. tostring(answer.disk_reason or "no reason given"))
  end
  local groups = answer.groups or {}
  local names = {}
  for name in pairs(groups) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local group = groups[name]
    print(string.format("  %-18s %8s  %d files  %s", name, bytes(group.bytes), tonumber(group.files) or 0, tostring(group.path)))
  end
  local pins = answer.pins or {}
  print(string.format("pins        %d%s", #pins, #pins > 0 and ("  (" .. table.concat(pins, ", ") .. ")") or ""))
  print(string.format("retention   %d days  (WASM_AGENT_CLEAN_DAYS, or wa clean --days N)", tonumber(answer.days) or 0))
  local last = answer.last_clean
  if type(last) == "table" then
    print(string.format("last clean  %s  freed %s  (%s, %d removed, %d kept)", when_epoch(last.at),
      bytes(last.freed_bytes), last.dry_run and "dry run" or "real run", tonumber(last.deleted) or 0, tonumber(last.kept) or 0))
  else
    print("last clean  never")
  end
end

local function print_plan(answer)
  local untouched = answer.dry_run and "would delete" or "deleted"
  local groups = answer.groups or {}
  local shown = 0
  for _, group in ipairs(groups) do
    local delete_entries = tonumber(group.delete_entries) or 0
    local delete_bytes = tonumber(group.delete_bytes) or 0
    local entries = tonumber(group.entries) or 0
    if delete_entries > 0 then
      print(string.format("%s  %s in %d of %d entr(ies) %s", group.name, bytes(delete_bytes), delete_entries, entries,
        answer.dry_run and "would go" or "went"))
      for _, row in ipairs(group.rows or {}) do
        if row.delete then
          print(string.format("  %s %8s  %-64s  %s", untouched, bytes(row.bytes), tostring(row.path), tostring(row.reason)))
          shown = shown + 1
        end
      end
      local more = delete_entries - #(group.rows or {})
      if more > 0 then print(string.format("  ... and %d more in %s", more, group.name)) end
    elseif entries > 0 then
      print(string.format("%s  nothing to delete (%d entr(ies), %s kept)", group.name, entries, bytes(tonumber(group.bytes) or 0)))
    end
    -- Why the rest stays, as counts and not as one line per file: 4000 lease files are one reason.
    for _, item in ipairs(group.kept_reasons or {}) do
      print(string.format("  keep %5d x  %s", tonumber(item.count) or 0, tostring(item.reason)))
    end
  end
  if shown == 0 and (#groups == 0) then print("(nothing in the root to judge)") end
  for _, refusal in ipairs(answer.refused or {}) do
    print(string.format("refused   %s  %s", tostring(refusal.path), tostring(refusal.reason)))
  end
  -- The scattered directories that PREDATE the root: reported here and never touched.
  local outside = answer.outside
  if type(outside) == "table" and (outside.entries or 0) > 0 then
    print(string.format("\noutside the root (reported, never touched): %s in %d entr(ies)%s",
      bytes(outside.bytes), tonumber(outside.entries) or 0, outside.complete and "" or ", at least"))
    for _, row in ipairs(outside.rows or {}) do
      local label = row.entries and string.format("%d entr(ies)", tonumber(row.entries) or 0) or ""
      print(string.format("  report %8s%s  %-64s  %s", bytes(row.bytes), row.complete and " " or "+", tostring(row.path), label))
    end
  end
  if answer.dry_run then
    print(string.format("dry run: %s would be freed; %d entr(ies) would go. Nothing was deleted; run `wa clean` to do it.",
      bytes(answer.would_free_bytes), tonumber(answer.deleted) or 0))
  else
    print(string.format("freed %s; %d entr(ies) removed, %d kept.", bytes(answer.freed_bytes),
      tonumber(answer.deleted) or 0, tonumber(answer.kept) or 0))
  end
end

function M.run(argv)
  local args = argv or {}
  local dry_run, status_only, as_json, days, pin, unpin, cap = false, false, false, nil, nil, nil, nil
  local index = 2
  while args[index] do
    local word = args[index]
    if word == "--dry-run" then dry_run = true; index = index + 1
    elseif word == "--status" or word == "--report" then status_only = true; index = index + 1
    elseif word == "--json" then as_json = true; index = index + 1
    elseif word == "--days" then days = tonumber(args[index + 1]); index = index + 2
    elseif word == "--pin" then pin = args[index + 1]; index = index + 2
    elseif word == "--unpin" then unpin = args[index + 1]; index = index + 2
    elseif word == "--cap" then cap = tonumber(args[index + 1]); index = index + 2
    elseif word == "-h" or word == "--help" then
      print("wa clean [--dry-run] [--days N] [--pin <path>|--unpin <path>] [--cap <percent>] [--status] [--json]")
      print("  reclaims the node's one root: landed worktrees, and operations/logs/temp older than N days")
      print("  --dry-run  print what would go and how many bytes, grouped; delete nothing")
      print("  --days N   retention for operations, logs and temp (default 7, or WASM_AGENT_CLEAN_DAYS)")
      print("  --pin      never delete this path (or anything inside it); --unpin to release it")
      print("  --cap N    the disk cap: refuse new heavy work past N% (default 85); written to <config>/env")
      print("  --status   the same facts `wa status` prints, without deleting anything")
      print("  Nothing outside the root is ever deleted: the scattered pre-existing dirs are reported, not moved.")
      return 0
    else
      print("wa clean: unknown option " .. tostring(word))
      return 2
    end
  end

  if cap then
    if not cap or cap <= 0 or cap > 100 then
      print("wa clean: --cap takes a percent between 1 and 100")
      return 2
    end
    local file, err = M.set_cap(cap)
    if not file then print("wa clean: " .. tostring(err)); return 1 end
    print(string.format("cap written: %s=%d in %s (read at startup: it applies from the next node start)", CAP_KEY, cap, file))
  end
  if pin or unpin then
    local action = pin and "pin" or "unpin"
    local answer, err = ask(action, { path = pin or unpin })
    if not answer then print("wa clean: " .. tostring(err)); return 1 end
    print(string.format("%s: %s (%d pin(s) now)", action, tostring(answer.path), tonumber(answer.pins) or 0))
    if not dry_run and not status_only and not days then return 0 end
  end

  if status_only then
    local answer, err = ask("status")
    if not answer then print("wa clean: " .. tostring(err)); return 1 end
    if as_json then print(json.encode(answer)) else print_status(answer) end
    return 0
  end

  local request = { dry_run = dry_run }
  if days then request.days = days end
  local answer, err = ask("clean", request)
  if not answer then print("wa clean: " .. tostring(err)); return 1 end
  if as_json then
    print(json.encode(answer))
  else
    print_plan(answer)
  end
  return 0
end

return M
