-- `/update`'s ONE LINE ON THE SCREEN (mission update-is-one-line, Fable/Victor 25/11).
--
-- WHAT WAS MEASURED FIRST (this mission, 25/11, scratch node, `wa update` driven through a stub sentinel
-- and a deploy that wrote a 7001-line deploy.out with 411 alarming lines):
--   * a compile install printed 9 lines, a download install 6, a failed deploy 18, an install with a
--     problem 18 - and the 7000 lines of the installer's own output never reached the terminal, they
--     stayed in sentinel/deploy.out. What reached the screen was the plan, three sentences of advice, and
--     one line per phase - each with its own clock - on lines that never moved.
--   * NOTHING was printed for the first 1.2-1.6 s, locally, on a fixture with no network: the whole of
--     `M.facts`, the git fetch, the sentinel round trip and the pre-update backup ran before the first
--     byte. On `work` that is seconds of nothing (Victor: "with wa update it takes long time to print
--     anything").
--   * on a release-installed node, `wa update` printed a plan line that named no binary and then followed
--     a sentinel request that does not exist, ending 1800 s later on a failure it invented.
--
-- So the command owes the person two things and no third: ONE line that moves while it works, and ONE
-- last line that says what happened. This module owns both, and nothing here decides anything: it is
-- handed a body by the follower (`lua/core/update_follow.lua`) and it draws.
--
-- TWO SHAPES, chosen from the process, never from a flag:
--   * a terminal (`host.isatty("stdout")`): one line, rewritten in place with a carriage return and an
--     erase-to-end-of-line, so a phase change replaces the last one instead of adding to it;
--   * a pipe, a mission, a chat turn: NO rewriting - one line per phase change (a change of body, never a
--     change of clock), and the last line. A log that rewrites itself is a log nobody can diff.
-- The last line replaces the moving one in both shapes. Nothing else is printed: the installer's own words
-- go to the deploy's log, which the last line names.
local M = {}

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- `0:07`, `3:10`, `1:02:03`: the shape `mise`/`cargo` print, and seconds are only shown when it is a
-- short wait. The person reads the two numbers that matter (what, and how long) and nothing else.
function M.clock(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s >= 3600 then return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60) end
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- IS STDOUT A TERMINAL? `host.isatty` is the host's own answer (rust/wa-capabilities/src/host.rs,
-- `stream_is_terminal`). An older host that cannot answer is a PIPE: rewriting a line nobody can rewrite
-- would leave carriage returns in a captured log, so unknown is the quiet shape.
function M.terminal()
  if type(host) ~= "table" or type(host.isatty) ~= "function" then return false end
  local ok, answer = pcall(host.isatty, "stdout")
  return ok and answer == true
end

-- ---- the texts a person reads -------------------------------------------------
-- Every one of these goes to Fable for approval before it lands (the mission's rule). The verdict words are
-- the cover branch's (`installed` / `installed_with_problems` / `failed`); this module adds no vocabulary of
-- its own for the outcome, only the sentence around it.
M.START = "checking for updates"

-- The ONE spelling of the version identity (Fable, 25/11): `v0.1.2 · 1857d15` - the version the build
-- declares, then the seven characters of the commit it was built from. A release install's record spells
-- that commit `node-1857d15887c` and a compiled install's build id spells it `va1857d15`; both are the same
-- commit, so the prefix is stripped here and the same spelling is printed for both kinds.
function M.identity(version, commit)
  local sha = trim(commit):gsub("^node-", ""):gsub("^va", ""):sub(1, 8)
  local tag = trim(version)
  if tag ~= "" and tag:sub(1, 1) ~= "v" then tag = "v" .. tag end
  if sha == "" then return tag ~= "" and tag or "" end
  if tag == "" then return sha end
  return tag .. " · " .. sha
end

-- "updated to v0.1.2 · 82f57859 in 0:48". The install FINISHED: the one line that says so exists.
function M.updated(version, commit, seconds)
  local sha = trim(commit):gsub("^node-", ""):gsub("^va", ""):sub(1, 8)
  local tag = trim(version)
  if tag ~= "" and tag:sub(1, 1) ~= "v" then tag = "v" .. tag end
  local who
  if tag ~= "" and sha ~= "" then who = tag .. " (" .. sha .. ")"
  elseif tag ~= "" then who = tag
  elseif sha ~= "" then who = sha
  else who = "the new build" end
  return "updated to " .. who .. " in " .. M.clock(seconds)
end

-- "already up to date (82f57859)": an answer, not a step. The commit is what this node RUNS.
function M.current(commit)
  local sha = trim(commit):gsub("^node-", ""):gsub("^va", "")
  if sha == "" then return "already up to date" end
  return "already up to date (" .. sha:sub(1, 8) .. ")"
end

-- "installed 82f57859, with 1 problem: <the problem>". The install HAPPENED and something else did not:
-- the node serves the new build, and the line says the good news first because it is the true one.
function M.with_problems(commit, problems, detail)
  local sha = trim(commit):gsub("^node-", "") :gsub("^va", "")
  local who = sha ~= "" and sha:sub(1, 8) or "the new build"
  local count = math.max(1, math.floor(tonumber(problems) or 1))
  local what = trim(detail)
  if what == "" then what = "the installer recorded no detail" end
  return "installed " .. who .. ", with " .. tostring(count) .. (count == 1 and " problem: " or " problems: ") .. what
end

-- "not updated: <the reason, one sentence>. Nothing was changed." One sentence, and then the promise the
-- person needs in order to walk away: the node still runs what it ran. A reason that already ends in a
-- full stop does not get a second one.
function M.not_updated(reason)
  local why = trim(reason)
  why = why:gsub("%." .. "$", "")
  if why == "" then why = "the installer did not say why" end
  -- the reason comes from the installer or a refusal sentence, and a sentence can be long: the last line
  -- is ONE line, so anything past the first sentence is dropped rather than wrapped. A sentence ends at a
  -- full stop followed by SPACE (or at the end): a path like `/.wasm-agent/build` carries dots that are not
  -- the end of anything, and the first version cut the reason in half inside one.
  local stop = why:find("%. ", 1, true)
  if stop then why = trim(why:sub(1, stop - 1)) end
  return "not updated: " .. why .. ". Nothing was changed."
end

-- The one line naming where the installer's own words are. Printed after the last line, always - a person
-- who wants the detail should never have to know a path in advance.
function M.log_line(path)
  local value = trim(path)
  if value == "" then return nil end
  return "log: " .. value
end

-- ---- the screen ---------------------------------------------------------------
-- `out` writes bytes with NO newline; `options.out` is a seam (a test hands a table it can read back).
-- `options.tty` forces a shape; nil asks the host. `options.now` is the clock seam.
function M.new(options)
  local o = options or {}
  local self = {
    tty = (o.tty ~= nil) and (o.tty == true) or M.terminal(),
    verbose = o.verbose == true,
    out = o.out or function(bytes)
      io.write(bytes)
      io.flush()
    end,
    now = o.now or function() return tonumber(host.now and host.now() or os.time()) end,
    lines = {},
  }
  self.started = (o.started_at ~= nil) and tonumber(o.started_at) or self.now()
  -- what the moving line currently says, so a rewrite that changes nothing is not a rewrite
  self.body = nil
  self.written = false

  -- The moving line. `body` is the sentence WITHOUT the clock ("compiling 212 of 340"); the clock is added
  -- here, from the one start this screen was given, so every phase carries the same elapsed time.
  function self:phase(body, from)
    local text = trim(body)
    if text == "" then return end
    local seconds = self.now() - (tonumber(from) or self.started)
    if self.tty then
      self.out("\r\27[K" .. text .. "  " .. M.clock(seconds))
      self.written = true
      self.body = text
    elseif text ~= self.body then
      -- a pipe gets a line per CHANGE of what it is doing, never one per tick of the clock
      self.out(text .. "  " .. M.clock(seconds) .. "\n")
      self.lines[#self.lines + 1] = text
      self.body = text
    end
  end

  -- A line that is not the moving line (a note the caller must say once, `--verbose` streaming). On a
  -- terminal it is printed above the moving line and the moving line is redrawn under it.
  function self:line(text)
    local value = trim(text)
    if value == "" then return end
    if self.tty then
      self.out("\r\27[K" .. value .. "\n")
      local body = self.body
      self.body = nil
      if body then self:phase(body) end
    else
      self.out(value .. "\n")
      self.lines[#self.lines + 1] = value
    end
  end

  -- THE LAST LINE, and the one that names the log. The moving line is erased first, so what is left on the
  -- screen is exactly what happened.
  function self:finish(text, log_path)
    local value = trim(text)
    if self.tty and self.written then self.out("\r\27[K") end
    self.written = false
    if value ~= "" then
      self.out(value .. "\n")
      self.lines[#self.lines + 1] = value
    end
    local log = M.log_line(log_path)
    if log then
      self.out(log .. "\n")
      self.lines[#self.lines + 1] = log
    end
    self.done = true
    self.last = value
    return self.lines
  end

  return self
end

return M
