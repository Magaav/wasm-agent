-- The backup verbs as an operator runs them, no model in the loop:
--
--   wa backup                      take one snapshot now (label 'manual') and print where it went
--   wa backup list                 every snapshot, newest first, with its stores and whether it is usable
--   wa backup restore --from DIR   put a snapshot back (script: backup.restore)
--   wa restore --from DIR          the same thing under the name an operator reaches for first
--
-- The one rule this file exists to keep: 'restore' without a directory that holds a manifest is a
-- REFUSAL by name, never a guess at which snapshot was meant and never a partial write. The checks and
-- the move are in lua/core/backup.lua (restore_cmd there is the only writer); this is the argument
-- parsing and the printing, so the shell face and any test share one implementation.
local json = dofile('lua/vendor/json.lua')
local M = {}

local function say(text) print(text) end

-- --from DIR, --dry-run, --json: the whole surface, and an unknown flag is a named refusal.
local function parse(args)
  local opts = {}
  local i = 1
  while i <= #args do
    local arg = tostring(args[i])
    if arg == '--from' then
      opts.from = args[i + 1]
      if opts.from == nil or opts.from == '' then return nil, 'restore_from_required: --from needs the snapshot directory to restore' end
      i = i + 2
    elseif arg == '--dry-run' then opts.dry_run = true; i = i + 1
    elseif arg == '--json' then opts.json = true; i = i + 1
    elseif arg:sub(1, 1) == '-' then return nil, 'unknown_flag: ' .. arg .. ' (backup takes list; restore takes --from DIR, --dry-run, --json)'
    else
      if opts.from == nil and arg ~= 'list' then opts.from = arg else return nil, 'unexpected_argument: ' .. arg end
      i = i + 1
    end
  end
  return opts
end

local function print_list(list)
  if #list == 0 then say('(no snapshots)'); return end
  for _, snapshot in ipairs(list) do
    if snapshot.manifest then
      say(string.format('%s  %-9s %d store(s)  %s', snapshot.stamp or snapshot.name, snapshot.label or '-', snapshot.stores, snapshot.dir))
    else
      say(string.format('%-24s unusable (%s)  %s', snapshot.name, snapshot.reason or 'no manifest', snapshot.dir))
    end
  end
end

-- The entry point. `verb` is 'backup' or 'restore'; the rest is the command line after it.
function M.run(verb, args)
  local backup = dofile('lua/core/backup.lua')
  if verb == 'backup' then
    local opts, why = parse(args)
    if not opts then say('wa backup: ' .. why); return 2 end
    if opts.from == 'list' or (args[1] == 'list') then print_list(backup.list()); return 0 end
    if opts.json and opts.from == nil then print(json.encode({ snapshots = backup.list() })); return 0 end
    if opts.from ~= nil then
      -- `wa backup restore --from ...` is accepted: it is the same verb, and an operator who says it
      -- that way means the same thing.
      return M.run('restore', args)
    end
    local ok, result = pcall(backup.run, 'manual')
    if not ok then say('wa backup: refused(backup_failed): ' .. tostring(result)); return 1 end
    say(string.format('backup: %d store(s) snapshotted and checked in %s', #result.stores, result.dir))
    for _, skipped in ipairs(result.skipped or {}) do say('backup: ' .. skipped.line) end
    say('backup: restore it with: wa restore --from ' .. result.dir)
    return 0
  end
  if verb == 'restore' then
    local opts, why = parse(args)
    if not opts then say('wa restore: ' .. why); return 2 end
    if not opts.from then
      say('wa restore: refused(restore_from_required): name the snapshot -- wa restore --from <dir> (wa backup list prints them). Nothing was changed.')
      return 2
    end
    local ok, result = pcall(backup.restore, opts.from, { dry_run = opts.dry_run })
    if not ok then
      say('wa restore: refused(restore_failed): ' .. tostring(result) .. ' - nothing was changed')
      return 1
    end
    if opts.json then print(json.encode(result)); return result.ok == false and 1 or 0 end
    if result.ok == false then
      say('wa restore: refused(' .. tostring(result.error) .. '): ' .. tostring(result.detail))
      return 1
    end
    if result.dry_run then
      say('restore: dry run - ' .. #result.would_restore .. ' store(s) would be put back, nothing was moved')
      for _, item in ipairs(result.would_restore) do say('  ' .. item.source) end
      return 0
    end
    say(string.format('restore: %d store(s) put back from %s', #result.restored, result.dir))
    if result.reopen_required then
      -- The bytes are back; the process reading them is not. Said plainly, because a node that kept
      -- serving the old ledger while the file said otherwise is exactly the "it worked" nobody can trust.
      say('restore: the ledger this command opened (' .. table.concat(result.reopen, ', ')
        .. ') was restored on disk and an OPEN process keeps its old view: restart the node before it reads these bytes')
    end
    for _, item in ipairs(result.restored) do
      -- 'previous kept at' is printed only for a file this restore MOVED ASIDE and then found there:
      -- backup.lua sets `previous` after checking the move, so the line cannot promise a way back that
      -- does not exist (item 2 of the node-ops round).
      say('  ' .. item.source .. (item.previous and ('  (previous kept at ' .. item.previous .. ')') or '  (no previous file)'))
      for _, note in ipairs(item.journal or {}) do say('    ' .. note) end
    end
    return 0
  end
  say('unknown verb: ' .. tostring(verb) .. ' (backup | restore)')
  return 2
end

return M
