-- One writer in the append race. `scripts/test-append-race.sh` runs several of these in parallel,
-- against the same database and the same session - the worst case "one writer per session" is supposed
-- to prevent, and the case the transaction in `memory.append_turn` has to survive.
--
-- Each writer tags its messages `u:<proc>:<i>` / `a:<proc>:<i>` so the checker can prove not just that
-- seqs are unique, but that a turn's own user message precedes its own assistant message even when the
-- two were written by different processes.
local memory = dofile("lua/core/memory.lua")
memory.setup()

local proc = host.getenv("RACE_PROC") or "0"
local count = tonumber(host.getenv("RACE_N") or "10")
local session = "append-race"

for i = 1, count do
  memory.append_turn(session, { role = "user", content = "u:" .. proc .. ":" .. i })
  memory.append_turn(session, { role = "assistant", content = "a:" .. proc .. ":" .. i })
end
