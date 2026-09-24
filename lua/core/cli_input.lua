-- The reader's input, read by the host while this interpreter is somewhere else.
--
-- Why this is not `io.read("*l")`. `wa chat` reads a line, runs a turn, then reads the next one -
-- and a turn blocks this interpreter inside the model call for as long as it takes. Nothing reads
-- stdin during that time, so a reader typing their next message typed into a stream nobody was
-- looking at: the terminal echoed the characters, and the line was then either read by a REPL that
-- had already moved on, or was lost with the process. "You cannot write to me while I work" was
-- therefore true here, and it is not true of pi or codex, which is what a reader compared it to.
--
-- The fix is a reader of its own, in the host (`host.input_start` / `input_take` / `input_stop`),
-- for the life of the process. It cannot be here: Lua is blocked inside the run, so the side that
-- must keep reading is the one that is not blocked - the same structural reason the status line's
-- timer lives in the host (`docs/HOST.md`, "Drawing while Lua is blocked").
--
-- What this module is: one line at a time, plus the lines that arrived while the caller was busy.
-- `input_take` answers with everything buffered, so a reader who typed three lines during a run
-- gets all three here, in order, the moment the run ends - no polling and no keystroke lost.
--
-- The console is left in the terminal's own mode. This does not put stdin into raw mode and echoes
-- nothing itself: line editing, the echo and Enter stay the terminal's, as they are for a shell.
-- What changes is only who reads the line, and that the line is not dropped while the interpreter
-- is elsewhere. Per-key editing, an interrupt key and multi-line input need the terminal handed
-- over (raw mode, a frame) and are deliberately not this change.
--
-- The capability may be missing - an older binary, or a test - and `host.input_*` answers a JSON
-- *string* like every host capability that pushes a table, so both absences are handled here: a
-- caller that cannot be read for falls back to the blocking read this module replaced, and the CLI
-- behaves exactly as it did before.

local json = dofile("lua/vendor/json.lua")

local M = {}

-- How long a single wait lasts before the caller looks up again. Long on purpose: a shorter wait
-- would have to redraw the prompt to stay honest about "still waiting", and redrawing it erases
-- whatever the reader has typed so far - the prompt and their typing are on the same row.
M.WAIT_MS = 1800000

-- A host function by name, or nil when this binary does not have it.
local function host_fn(name)
  if type(host) ~= "table" then return nil end
  local fn = host[name]
  if type(fn) ~= "function" then return nil end
  return fn
end

-- Every host capability that hands back a table hands back its JSON text, so nil (the capability
-- is absent) and an unreadable answer are the same answer here: not a table to work with.
local function decode(raw)
  if type(raw) ~= "string" then return nil end
  local ok, value = pcall(json.decode, raw)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

-- Is there a reader thread to be had? False on a binary older than this module.
function M.available()
  return host_fn("input_start") ~= nil and host_fn("input_take") ~= nil
end

-- Start the host reading stdin. Idempotent - the host has one reader per process - and false when
-- the capability is not there, which is a condition and not an error.
function M.start(deps)
  deps = deps or {}
  local start = deps.start or host_fn("input_start")
  if not start then return false end
  local ok, raw = pcall(start)
  if not ok then return false end
  return decode(raw) ~= nil
end

-- Stop the host reading stdin, on the way out. Not required for correctness (the thread dies with
-- the process) and not a join: see `host.input_stop`.
function M.stop(deps)
  deps = deps or {}
  local stop = deps.stop or host_fn("input_stop")
  if not stop then return false end
  return pcall(stop)
end

-- What has arrived and not been taken: the lines, and whether the input has ended.
--
-- `lines` is nil - not an empty table - when there is nothing to ask, so the caller can tell
-- "this binary cannot do it" from "nothing was typed yet". Both are ordinary outcomes.
function M.arrived(timeout_ms, deps)
  deps = deps or {}
  local take = deps.take or host_fn("input_take")
  if not take then return nil end
  local ok, raw = pcall(take, timeout_ms or 0)
  if not ok then return nil end
  local answer = decode(raw)
  if not answer then return nil end
  local lines = {}
  if type(answer.lines) == "table" then
    for _, line in ipairs(answer.lines) do lines[#lines + 1] = tostring(line) end
  end
  return lines, answer.eof and true or false, answer.running and true or false
end

local METHODS = {}

-- One line, or nil at the end of input. Empty lines are lines: a reader who presses Enter sends
-- one, and the REPL has always treated that as "keep prompting" rather than as an exit.
--
-- `read_line` and `deps` are injectable, because the rule worth testing - lines typed during a run
-- are all handed over, in order, and a capability that is absent falls back instead of hanging -
-- is not a rule that needs a terminal to test.
function M.new(opts)
  opts = opts or {}
  local self = {
    pending = {},
    eof = false,
    supported = false,
    deps = opts.deps or {},
    read_line = opts.read_line or function() return io.read("*l") end,
  }
  self.supported = M.start(self.deps)
  return setmetatable(self, { __index = METHODS })
end

-- Wait for the next line. Returns `line` on a line, and `nil, true` when the input has ended.
-- A wait that produces nothing returns `nil, false`, which is not the end of anything.
function METHODS:poll(timeout_ms)
  if #self.pending > 0 then return table.remove(self.pending, 1), self.eof end
  if self.eof then return nil, true end
  if not self.supported then
    -- No reader thread: the blocking read this module replaced, so an older binary is exactly
    -- the CLI it was rather than a CLI that hangs waiting for a capability it does not have.
    local line = self.read_line()
    if line == nil then
      self.eof = true
      return nil, true
    end
    return line, false
  end
  local lines, eof = M.arrived(timeout_ms or M.WAIT_MS, self.deps)
  if not lines then
    -- The capability stopped answering: fall back rather than spin on it.
    self.supported = false
    return self:poll(timeout_ms)
  end
  -- Everything the host handed over, kept in order. This is the whole of "a line typed while the
  -- agent was working is not lost": the run does not read, this does, and the run's end is when
  -- the caller comes back for it.
  for _, line in ipairs(lines) do self.pending[#self.pending + 1] = line end
  if eof then self.eof = true end
  if #self.pending > 0 then return table.remove(self.pending, 1), self.eof end
  return nil, self.eof
end

-- How many lines are waiting, without taking one. The REPL uses it to say so.
function METHODS:waiting()
  return #self.pending
end

function METHODS:stop()
  M.stop(self.deps)
end

return M
