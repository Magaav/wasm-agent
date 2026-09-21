-- The checker for the append race. Reads what every writer left and asserts the invariants the
-- non-transactional `MAX(seq)+1` could break: no two messages share a seq, the seqs are contiguous, and
-- every turn's user message precedes its own assistant message.
local json = dofile("lua/vendor/json.lua")

local procs = tonumber(host.getenv("RACE_PROCS") or "1")
local count = tonumber(host.getenv("RACE_N") or "10")
local expected = procs * count * 2

local rows = json.decode(host.sql_query(
  "SELECT seq, role, content FROM messages WHERE session_id='append-race' ORDER BY seq ASC", "[]"))
assert(#rows == expected, "expected " .. expected .. " messages, found " .. #rows)

local seen, user_seq, assistant_seq = {}, {}, {}
for _, row in ipairs(rows) do
  assert(not seen[row.seq], "duplicate seq " .. tostring(row.seq))
  seen[row.seq] = true
  local proc, index = tostring(row.content):match("^[ua]:(%d+):(%d+)$")
  assert(proc and index, "unexpected content: " .. tostring(row.content))
  local key = proc .. ":" .. index
  if row.role == "user" then
    user_seq[key] = row.seq
  elseif row.role == "assistant" then
    assistant_seq[key] = row.seq
  else
    error("unexpected role " .. tostring(row.role))
  end
end

for seq = 1, expected do
  assert(seen[seq], "gap in seq at " .. seq)
end
for key, useq in pairs(user_seq) do
  local aseq = assistant_seq[key]
  assert(aseq, "no assistant message for " .. key)
  assert(useq < aseq, "assistant before its own user message for " .. key .. ": " .. useq .. " vs " .. aseq)
end

print("append race ok")
