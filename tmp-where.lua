-- Where does the per-call prompt come from? Compare rounds early vs late in one session, and
-- check whether the fixed overhead (AGENTS.md + skills + tools) dominates a small turn.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

-- The single biggest session: my own interrupted-recovery thread.
local sid = "4ef4e372-8d84-4eff-b3e3-7f48f2a3c939"
local rows = memory.session_turns(sid, { limit = 4000 })
local first, last, n = nil, nil, 0
local prompts = {}
for _, t in ipairs(rows) do
  local tr = t.trace
  if type(tr) == "table" then
    for _, e in ipairs(tr) do
      if e.kind == "llm" and e.tokens and e.tokens.prompt then
        n = n + 1
        prompts[#prompts + 1] = e.tokens.prompt
      end
    end
  end
end
print("llm calls in that session: " .. n)
if n > 0 then
  print("  first call prompt:  " .. prompts[1])
  print("  min prompt:         " .. math.min(table.unpack(prompts)))
  print("  max prompt:         " .. math.max(table.unpack(prompts)))
  local sum = 0
  for _, p in ipairs(prompts) do sum = sum + p end
  print("  mean prompt:        " .. math.floor(sum / n))
end

-- What does ONE call cost when the turn is trivial? That isolates the fixed overhead.
print("")
print("=== trivial turns: what is the floor? ===")
for _, s in ipairs(memory.list_sessions("master", 40)) do
  local rs = memory.session_turns(s.id, { limit = 50 })
  local tot, cnt = 0, 0
  for _, t in ipairs(rs) do
    if type(t.trace) == "table" then
      for _, e in ipairs(t.trace) do
        if e.kind == "llm" and e.tokens and e.tokens.prompt then tot = tot + e.tokens.prompt; cnt = cnt + 1 end
      end
    end
  end
  if cnt > 0 and cnt <= 3 then
    print(string.format("  %-38s calls=%d mean_prompt=%d  %s", s.id:sub(1,36), cnt, math.floor(tot/cnt), (s.title or ""):sub(1,28)))
  end
end
