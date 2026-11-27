-- wa update requests: what this node's update requests say, and the sweep that closes the ones no install will serve.
--
-- Text is operator-facing. It prints the RECORD FILES (the same ones a caller's wait reads), so "is anything still
-- queued?" is answered by the thing that was wrong on openclaw (78 queued records about installs that worked).
--
--   wa update requests                  id, state, age, reason - newest first
--   wa update requests --sweep          close what no install will serve, by name; deletes nothing
--   wa update requests --sweep --dry-run   the same, printing what it WOULD close
--   wa update requests --max-age 86400  the age the sweep calls expired (seconds; default one day)
local json = dofile('lua/vendor/json.lua')

local M = {}

-- host.list_dir answers a JSON ENVELOPE ({entries = {{name = ...}}}), not a list of names - MEASURED: this verb first
-- iterated the answer directly and listed nothing, so "no update requests" was printed over four existing records.
local function names_in(dir)
  local ok, raw = pcall(host.list_dir, dir)
  local names = {}
  if not ok or type(raw) ~= 'string' then return names end
  local decoded_ok, listing = pcall(json.decode, raw)
  if not decoded_ok or type(listing) ~= 'table' then return names end
  for _, entry in ipairs(listing.entries or {}) do
    local name = tostring(entry.name or entry or '')
    if name:match('%.json$') then names[#names + 1] = name end
  end
  return names
end

local function age_text(seconds)
  if not seconds then return '-' end
  seconds = tonumber(seconds) or 0
  if seconds >= 86400 then return string.format('%.1fd', seconds / 86400) end
  if seconds >= 3600 then return string.format('%.1fh', seconds / 3600) end
  return string.format('%dm', math.floor(seconds / 60))
end

function M.run(argv)
  local remote = dofile('lua/core/remote_update.lua')
  local args = {}
  for _, value in ipairs(argv or {}) do args[#args + 1] = value end
  -- the command word may still be in the table (init.lua hands the same args through)
  if args[1] == 'update' then table.remove(args, 1) end
  if args[1] == 'requests' then table.remove(args, 1) end
  local sweep, dry, max_age = false, false, 86400
  local rest = {}
  for i = 1, #args do
    local a = tostring(args[i])
    if a == '--sweep' then sweep = true
    elseif a == '--dry-run' then dry = true
    elseif a == '--max-age' and args[i + 1] then max_age = tonumber(args[i + 1]) or max_age
    else rest[#rest + 1] = a end
  end
  if sweep then
    local result = remote.sweep({ max_age_seconds = max_age, dry_run = dry })
    if type(result) ~= 'table' or result.error then
      print('update requests: ' .. tostring(result and result.error or 'the sweep did not run'))
      return 1
    end
    print(string.format('%s: scanned %d record(s), %d to close, %d kept (max age %s)',
      dry and 'would sweep' or 'swept', result.scanned or 0, #(result.closed or {}), result.kept or 0, age_text(max_age)))
    for _, entry in ipairs(result.closed or {}) do
      print(string.format('  %s  %s  age %s', entry.id, entry.reason, age_text(entry.age_seconds)))
    end
    return 0
  end
  local listing = remote.read_status({}, { node_id = '' })
  -- list every record on this node, newest first, as files (a reader of the record sees what a wait sees)
  local dir = remote.dir()
  local names = names_in(dir)
  if #names == 0 then print('no update requests on this node'); return 0 end
  table.sort(names)
  local now = math.floor(host.now())
  for _, name in ipairs(names) do
    local record = remote.record((tostring(name):gsub('%.json$', '')))
    if record then
      local age = tonumber(record.requested_at or 0) or 0
      print(string.format('  %-28s %-10s age %-6s %s', tostring(record.id or name), tostring(record.state or '?'),
        age_text(age > 0 and (now - age) or nil), tostring(record.closed_reason or record.detail or '')))
    end
  end
  return 0
end

return M
