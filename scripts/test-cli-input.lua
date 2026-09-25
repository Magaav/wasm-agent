-- Input typed while this interpreter is blocked is not lost.
--
-- The bug this pins: `wa chat` read its input with `io.read("*l")` between turns, so while a run
-- was in flight nothing read stdin at all. A reader typing their next message typed into a stream
-- nobody was looking at - the terminal echoed it, and the line got no further. pi and codex do not
-- lock their input, and the reader compared them to this.
--
-- Observed through a real child process, like `scripts/test-cli-ticker.lua` and for the same
-- reason: the reader is a thread, so the only honest evidence is what that process does. The
-- producer on its stdin writes the second line *while this script is asleep* - which is the one
-- arrangement that tells a reader thread apart from a read in the REPL. With `io.read` that line
-- would have arrived to nobody, and no assertion below could have passed.
local cli_input = dofile("lua/core/cli_input.lua")

local failed = 0
local checks = 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end

-- The capability is there at all. Without this, every assertion below would be satisfied by the
-- fallback read and the test would pass on the binary it is supposed to fail on.
ok(cli_input.available(), "this binary reads stdin for its caller")

local input = cli_input.new()

-- The line the producer writes immediately.
local first = input:poll(2000)
ok(first == "first", "the line already typed comes back, got " .. tostring(first))

-- Blocked the way a run blocks. Nothing on this side reads stdin for three seconds; the producer
-- writes the next line into exactly that window.
host.sleep(3000)

-- What the host collected while this interpreter was elsewhere. This is the assertion the whole
-- change exists for: the line is here, in order, and nobody lost it.
local arrived = cli_input.arrived(0)
ok(type(arrived) == "table" and arrived[1] == "typed while blocked",
  "a line typed while this process was blocked is waiting for it, got "
  .. tostring(type(arrived) == "table" and arrived[1] or arrived))

-- The producer has closed the pipe by now. The end of input is an answer - nil plus `eof` - and
-- never a hang, because a REPL that cannot be told the input ended cannot ever exit cleanly.
local line, eof = input:poll(1000)
ok(line == nil and eof == true, "a closed stdin reads as the end of input")

input:stop()

-- The native editor is an opt-in for a real terminal; a pipe stays line-oriented.
local selected = cli_input.new({ editor = true, deps = {
  start = function(enabled) return '{"started":true,"editor":' .. (enabled == 1 and 'true' or 'false') .. '}' end,
  take = function() return '{"lines":[],"eof":true,"running":false}' end,
} })
ok(selected.editor == true, "a terminal can request the native editor")
local pipe = cli_input.new({ deps = {
  start = function(enabled) return '{"started":true,"editor":' .. (enabled == 1 and 'true' or 'false') .. '}' end,
} })
ok(pipe.editor == false, "a pipe does not request terminal raw mode")

-- A line the reader sends that is empty is a line, not an exit: the REPL treats it as "keep
-- prompting". Asserted on the queue rather than on a terminal, which needs no terminal at all.
local blank = cli_input.new({ deps = {
  start = function() return "{\"started\":true}" end,
  take = function() return "{\"lines\":[\"\"],\"eof\":false,\"running\":true}" end,
} })
local kept, closed = blank:poll(0)
ok(kept == "" and closed == false, "an empty line is a line, not the end of input")

-- A running model only takes complete ordinary lines. Commands remain for the
-- REPL, and nothing behind a command is allowed to jump ahead of it.
local supplied = 0
local steering = cli_input.new({ deps = {
  start = function() return '{"started":true}' end,
  take = function()
    supplied = supplied + 1
    if supplied == 1 then return '{"lines":["first note","  ","/new","after command"],"eof":false,"running":true}' end
    return '{"lines":[],"eof":false,"running":true}'
  end,
} })
local notes = steering:take_steering()
ok(#notes == 1 and notes[1] == "first note", "a waiting message steers the next model round")
ok(steering:poll(0) == "/new" and steering:poll(0) == "after command",
  "commands and later text stay ordered for the REPL")

-- An older binary: no capability, no reader thread, and the blocking read this replaced. The
-- condition is not an error, and it must not hang waiting for something that will never answer.
-- The stub runs out of lines the way a real stdin does, so the end of input is asserted too.
local remaining = { "from the fallback" }
local fallback = cli_input.new({ deps = { start = function() return nil end },
  read_line = function() return table.remove(remaining, 1) end })
ok(cli_input.start({ start = function() error("no capability") end }) == false,
  "a capability that raises is absent, not fatal")
ok(fallback:poll(0) == "from the fallback", "and an absent capability reads the old way")
local no_more, closed = fallback:poll(0)
ok(no_more == nil and closed == true, "and the old read answering nil ends the input, not the REPL's wait")

if failed > 0 then
  print(string.format("cli input: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("cli input ok (%d checks)", checks))
