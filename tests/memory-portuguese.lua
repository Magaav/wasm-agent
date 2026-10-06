-- Recall works on accented (pt-BR) words, and a one-letter word does not match the whole store.
-- Run: WA_SCRIPT=tests/memory-portuguese.lua wa (with a throwaway HOME).
local memory = dofile("lua/core/memory.lua")
memory.setup()
memory.remember("A configuração do serviço usa a porta 8799", "global")
memory.remember("O café da manhã é às sete", "global")
memory.remember("unrelated note about o", "global")
local function contents(rows) local t = {} for _, r in ipairs(rows) do t[#t + 1] = r.content end return t end
local hits = contents(memory.recall("configuração do serviço"))
assert(#hits == 1 and hits[1]:find("8799"), "accented query finds its fact, got " .. table.concat(hits, " | "))
local folded = contents(memory.recall("configuracao"))
assert(#folded == 1, "diacritics fold on both sides, got " .. #folded)
local wide = contents(memory.recall("qual é a porta do serviço?"))
assert(#wide >= 1 and wide[1]:find("8799"), "a question still finds the fact first")
for _, c in ipairs(wide) do assert(not c:find("unrelated"), "a one-letter word must not pull unrelated rows") end
print("memory portuguese ok")
