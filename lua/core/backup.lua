-- Consistent, checked snapshots of every SQLite store the node keeps.
--
-- `scripts/backup-db.lua` copied memory.db alone and never checked the copy, and nothing took a backup
-- before an update migrated the schema (MEMORY.md asked the operator to remember). This finds every
-- store under the node's data and config directories (memory, graph, jobs, resource claims, the run
-- journal), snapshots each with `VACUUM INTO` through this connection (an attached store is vacuumed
-- by name, so the WAL is included and no store is copied mid-write), checks each copy with
-- `PRAGMA integrity_check`, and preserves every recoverable snapshot.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local M = {}


local function sql(statement, params)
  local raw = host.sql_exec(statement, json.encode(params or {}))
  local result = type(raw) == "string" and json.decode(raw) or raw
  if type(result) == "table" and result.error then error(tostring(result.error), 0) end
  return result
end

local function query(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  local rows = type(raw) == "string" and json.decode(raw) or raw
  if type(rows) == "table" and rows.error then error(tostring(rows.error), 0) end
  return rows or {}
end

local function list(dir)
  local ok, raw = pcall(host.list_dir, dir)
  if not ok then error('backup_inventory_failed: '..dir..': '..tostring(raw),0) end
  local value = type(raw) == "string" and json.decode(raw) or raw
  if type(value) ~= "table" or value.error then error('backup_inventory_failed: '..dir..': '..tostring(type(value)=='table' and value.error or raw),0) end
  return value.entries or value
end

local function is_store(name)
  if name:find("%.lease%.sqlite$") or name:find("%-journal$") or name:find("%-wal$") or name:find("%-shm$") then
    return false
  end
  return name:find("%.db$") ~= nil or name:find("%.sqlite$") ~= nil
end

local function main_db()
  for _, row in ipairs(query("PRAGMA database_list")) do
    if row.name == "main" then return tostring(row.file or "") end
  end
  return ""
end

-- Every store file one level down from the data/config roots (stores live in the root or in one
-- subdirectory such as resources/ or jobs/), never inside a previous backup.
function M.stores()
  local found, seen = {}, {}
  for _, root in ipairs({ paths.data(), paths.config() }) do
    local function scan(dir, depth)
      for _, entry in ipairs(list(dir)) do
        local name = tostring(entry.name or "")
        local path = dir .. "/" .. name
        if entry.kind == "dir" and depth == 0 and name ~= "backups" and name ~= "changes" and name ~= "bin" then
          scan(path, 1)
        elseif entry.kind == "file" and is_store(name) and not seen[path] then
          seen[path] = true
          found[#found + 1] = path
        end
      end
    end
    scan(root, 0)
  end
  -- The live database can be anywhere (`wa --db PATH`); it is always included.
  local main = main_db()
  if main ~= "" and not seen[main] then found[#found + 1] = main end
  table.sort(found)
  return found
end

-- Snapshot every store into <config>/backups/<stamp>/ and check each copy. Returns
-- {ok, dir, stores = {{source, copy, check}}} or raises with the first failure.
function M.run(label)
  local stamp = os.date("!%Y%m%dT%H%M%SZ") .. '-' .. host.uuid() .. (label and label ~= "" and ("-" .. label:gsub("[^%w_-]", "")) or "")
  local dir = paths.config() .. "/backups/" .. stamp
  assert(host.write_file(dir .. "/.keep", ""),'backup_directory_write_failed')
  local results, main = {}, main_db()
  for index, source in ipairs(M.stores()) do
    local copy = dir .. "/" .. source:gsub("^.*[/\\\\]", ""):gsub("^(.*)$", function(name) return index .. "-" .. name end)
    if source == main then
      sql("VACUUM INTO ?", { copy })
    else
      sql("ATTACH DATABASE ? AS wa_backup_source", { source })
      local ok, problem = pcall(sql, "VACUUM wa_backup_source INTO ?", { copy })
      sql("DETACH DATABASE wa_backup_source")
      if not ok then error("backup_failed: " .. source .. ": " .. tostring(problem), 0) end
    end
    sql("ATTACH DATABASE ? AS wa_backup_check", { copy })
    local rows = query("PRAGMA wa_backup_check.integrity_check")
    sql("DETACH DATABASE wa_backup_check")
    local verdict = rows[1] and (rows[1].integrity_check or rows[1][1]) or "unknown"
    if verdict ~= "ok" then error("backup_corrupt: " .. copy .. ": " .. tostring(verdict), 0) end
    results[#results + 1] = { source = source, copy = copy, check = verdict }
  end
  M.prune()
  return { ok = true, dir = dir, stores = results }
end

-- A newer snapshot does not prove an older recovery source obsolete. Keep all
-- snapshots; evidence-aware, explicitly scoped maintenance owns retirement.
function M.prune()
  return { skipped = 'recovery_evidence_preserved' }
end

return M
