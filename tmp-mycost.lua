-- My own cost profile, from my own ledger. No estimates: every number is read from a stored trace.
--
-- The question is whether this harness leaks efficiency, so the measurement has to be the one the
-- trace actually recorded - prompt/completion tokens per llm call, tool counts per turn - rather than
-- anything I could recall about how a run "felt".
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")

local sessions = memory.list_sessions("master", 40)
print("sessions found: " .. #sessions)

local grand_prompt, grand_completion, grand_tools, grand_turns, grand_llm = 0, 0, 0, 0, 0
local worst = {}

for _, s in ipairs(sessions) do
  local rows = memory.session_turns(s.id, { limit = 4000 }) or {}
  local prompt, completion, llm, tools, tool_ms = 0, 0, 0, 0, 0
  local cached = 0
  for _, t in ipairs(rows) do
    local entries = t.trace
    if type(entries) == "string" and entries ~= "" and entries ~= "[]" then
      local ok, decoded = pcall(json.decode, entries)
      entries = ok and decoded or nil
    end
    if type(entries) == "table" then
      for _, e in ipairs(entries) do
        if e.kind == "llm" and e.tokens then
          prompt = prompt + (e.tokens.prompt or 0)
          completion = completion + (e.tokens.completion or 0)
          cached = cached + (e.tokens.cached or 0)
          llm = llm + 1
        elseif e.kind == "tool" then
          tools = tools + 1
          tool_ms = tool_ms + (e.ms or 0)
        end
      end
    end
  end
  if llm > 0 or tools > 0 then
    grand_prompt = grand_prompt + prompt
    grand_completion = grand_completion + completion
    grand_tools = grand_tools + tools
    grand_turns = grand_turns + #rows
    grand_llm = grand_llm + llm
    worst[#worst + 1] = { id = s.id, prompt = prompt, completion = completion,
      llm = llm, tools = tools, turns = #rows, cached = cached, title = s.title or "" }
  end
end

table.sort(worst, function(a, b) return a.prompt > b.prompt end)
print("")
print(string.format("%-38s %9s %7s %6s %7s %6s", "session", "prompt_tk", "comp_tk", "llms", "tools", "turns"))
for i = 1, math.min(12, #worst) do
  local w = worst[i]
  print(string.format("%-38s %9d %7d %6d %7d %6d  %s", w.id:sub(1, 36), w.prompt, w.completion, w.llm, w.tools, w.turns, (w.title or ""):sub(1, 30)))
end

print("")
print("=== my totals across " .. #worst .. " sessions with traces ===")
print(string.format("  prompt tokens:     %d", grand_prompt))
print(string.format("  completion tokens: %d", grand_completion))
print(string.format("  llm calls:         %d", grand_llm))
print(string.format("  tool calls:        %d", grand_tools))
print(string.format("  turns recorded:    %d", grand_turns))
if grand_llm > 0 then
  print(string.format("  mean prompt/call:  %.0f tokens  <- the context re-sent every round", grand_prompt / grand_llm))
  print(string.format("  mean comp/call:    %.0f tokens", grand_completion / grand_llm))
end
if grand_tools > 0 and grand_turns > 0 then
  print(string.format("  tools per turn:    %.2f", grand_tools / grand_turns))
end
