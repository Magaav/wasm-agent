-- Live progress for a long tool call, on the CLI's session-status-content row
-- (docs/TOOL-PROGRESS.md).
--
-- The finding (08/11): the agent ran `cargo test` in its `bash` tool for twenty minutes and the CLI
-- showed only "Running bash" - no output, no movement - so a healthy build and a wedged process
-- looked the same. The row above the status bar already carries the *node rebuild* loader
-- (`lua/core/update_banner.lua`, `rust/wa-term/src/build_status.rs`); this module is the same row for
-- the *tool calls the agent makes*:
--
--   ⟳ bash · 3m10s ▕████░░░░░░░░░░▏ 143/412 building serde_json
--   ⟳ bash · 41s · Downloading numpy-1.26.0-cp311.whl (15.8 MB)
--   ⟳ bash · 4m20s · no output for 3m
--
-- Where the facts come from, and why a file: a foreground `bash` blocks this interpreter inside
-- `host.exec`, so Lua cannot poll and cannot paint. The host's operation wait loop is awake, and it
-- publishes the tail it reads to `<data>/tool-progress.json` (at most four times a second;
-- `rust/wa-capabilities/src/tool_progress.rs`). This module reads that file, and keeps its own tail
-- for the calls it is told about directly (`observe`), so the CLI can say something true even when the
-- file is not there.
--
-- The decision is `rust/wa-tool-progress`'s, in Rust, and this is its Lua twin: the same wording, the
-- same thresholds and the same dialects, pinned against each other by
-- `scripts/test-tool-progress.lua` and the Rust crate's own tests. Two implementations exist because
-- the CLI is Lua and the editor's row is Rust; one *rule* exists because the tests compare them.
--
-- Precedence: this line is the LOWEST claimant of the row. A build loader and the standing update
-- notice both win (`lua/core/chat.lua` resolves that, `lua/core/cli_view.lua` draws it), because they
-- are facts about the node while this is a fact about one call.
local json = dofile('lua/vendor/json.lua')
local redact = dofile('lua/core/redact.lua')
local M = {}

-- A call shorter than this needs no row: the status line already says `Running bash`.
M.MIN_SECONDS = 2
-- No output for this long is worth saying out loud. Not a verdict: a quiet compiler is healthy.
M.STALL_SECONDS = 180
-- A live file older than this is a node that died mid-call, not a running tool.
M.FRESH = 10
-- The bar's width and glyphs: the build loader's, so two loaders on one row cannot look like two
-- features.
M.BAR = 14
local BAR_LEFT, BAR_RIGHT, BAR_FULL, BAR_EMPTY = "\u{2595}", "\u{258F}", "\u{2588}", "\u{2591}"
-- How many of the newest lines the tail keeps, and the longest single line.
local KEEP_LINES = 24
local MAX_LINE = 400

local function getenv(name)
  if not host or not host.getenv then return nil end
  local ok, value = pcall(host.getenv, name)
  return ok and type(value) == 'string' and value or nil
end

-- `<data>/tool-progress.json`, resolved the way the Rust side resolves it: `WASM_AGENT_DATA`, else
-- `WASM_AGENT_HOME/.wasm-agent`, else the host's data directory. `WA_TOOL_PROGRESS` points a test (or
-- an operator) at a fixture and never at this machine's node.
function M.path(options)
  local o = options or {}
  local configured = o.path or getenv("WA_TOOL_PROGRESS")
  if type(configured) == 'string' and configured ~= "" then return (configured:gsub("\\", "/")) end
  local data = getenv("WASM_AGENT_DATA")
  if data and data ~= "" then return (data:gsub("\\", "/")) .. "/tool-progress.json" end
  local home = getenv("WASM_AGENT_HOME")
  if home and home ~= "" then return (home:gsub("\\", "/")) .. "/.wasm-agent/tool-progress.json" end
  local ok, paths = pcall(dofile, 'lua/core/paths.lua')
  local dir = ok and type(paths) == 'table' and paths.data and paths.data() or nil
  if not dir then return "tool-progress.json" end
  return (tostring(dir):gsub("\\", "/")) .. "/tool-progress.json"
end

-- `125` -> `2m05s`, `45` -> `45s`, `3720` -> `1h02m`: `elapsed` in wa-tool-progress, to the second.
function M.elapsed(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
  return s .. "s"
end

-- The stall hint's own clock: `3m` for whole minutes, `3m20s` when the seconds matter.
function M.compact(seconds)
  local s = math.max(0, math.floor(tonumber(seconds) or 0))
  if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 and s % 60 == 0 then return string.format("%dm", math.floor(s / 60)) end
  if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
  return s .. "s"
end

function M.stall(seconds) return "no output for " .. M.compact(seconds) end

function M.bar(fraction)
  local value = tonumber(fraction) or 0
  if value ~= value then value = 0 end
  value = math.max(0, math.min(1, value))
  local filled = math.floor(value * M.BAR + 0.5)
  return BAR_LEFT .. string.rep(BAR_FULL, filled) .. string.rep(BAR_EMPTY, M.BAR - filled) .. BAR_RIGHT
end

-- One line, always: ANSI sequences (a tool that forces colour still writes them), and every other
-- control character, are removed; a tab becomes a space, because a tab is a column count `clip`
-- cannot see.
function M.printable(text)
  local value = tostring(text or "")
  value = value:gsub("\27%[[%d;?]*%a", ""):gsub("\27%][^\7]*\7", ""):gsub("\27.", "")
  value = value:gsub("\t", " ")
  value = value:gsub("%c", "")
  return value
end

-- ---- the dialects -------------------------------------------------------------------
-- A percentage or an `n/m` pair on a line: `{ done, total, percent }`, or nil.
local function numbers(line)
  local done, total = line:match("(%d+)%.?%d*%s*/%s*(%d+)")
  if done and total and tonumber(total) > 0 then
    return { done = tonumber(done), total = tonumber(total), percent = false }
  end
  local percent = line:match("(%d+)%%")
  if percent and tonumber(percent) <= 100 then
    return { done = tonumber(percent), total = 100, percent = true }
  end
  return nil
end

-- The detail a line carries, as `{ kind = "bar", label, done, total, percent }` or
-- `{ kind = "text", text }`; nil when no dialect recognizes it.
function M.dialect(raw)
  local line = M.printable(raw):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return nil end
  local lower = line:lower()
  -- cargo: `Building [=====>      ] 143/412: serde_json, syn` - the bar and the count.
  if lower:sub(1, 10) == "building [" then
    local pair = numbers(lower:sub(10))
    local label = line:match(": ([^:]+)$")
    label = label and (label:gsub("%s+$", "")) or ""
    local first = label:match("^([^,]+)") or ""
    if pair and pair.total > 0 then
      return { kind = "bar", done = pair.done, total = pair.total, percent = false,
        label = first ~= "" and ("building " .. first) or "building" }
    end
    return { kind = "text", text = "building" }
  end
  if line:sub(1, 10) == "Compiling " then
    local name = line:match("^Compiling%s+(%S+)") or ""
    return { kind = "text", text = name ~= "" and ("compiling " .. name) or "compiling" }
  end
  if line:sub(1, 9) == "Finished " then
    local took = line:match(" in (.+)$")
    return { kind = "text", text = took and ("finished in " .. took) or "finished" }
  end
  -- npm / pnpm: `Progress: resolved 143, reused 120, downloaded 23, added 0`
  if lower:sub(1, 9) == "progress:" or lower:sub(1, 9) == "progress " then
    local count = lower:match("resolved%s+(%d+)")
    return { kind = "text", text = count and ("resolved " .. count .. " packages") or line }
  end
  local reify = lower:find("reify:", 1, true)
  if reify then
    local name = line:sub(reify):match("^(reify:[^:]+)") or "reify"
    return { kind = "text", text = name }
  end
  -- pip
  if lower:sub(1, 12) == "downloading " or lower:sub(1, 11) == "collecting " or lower:sub(1, 11) == "installing " then
    local text = line:sub(1, 120)
    return { kind = "text", text = text:sub(1, 1):lower() .. text:sub(2) }
  end
  -- pip's own bar: `  45%|████▌     | 45.0/100.0 [00:03<00:04, 12.3MB/s]`
  local pair = numbers(line)
  if pair then
    local words = ""
    if lower:find("receiving objects", 1, true) then words = "receiving objects"
    elseif lower:find("resolving deltas", 1, true) then words = "resolving deltas"
    elseif lower:find("counting objects", 1, true) then words = "counting objects"
    elseif lower:find("compressing objects", 1, true) then words = "compressing objects"
    elseif lower:find("download", 1, true) then words = "downloading" end
    local shaped = pair.percent or words ~= "" or lower:find("|", 1, true) ~= nil
      or lower:find("resolved", 1, true) ~= nil or lower:find("compiling", 1, true) ~= nil
    if shaped then
      return { kind = "bar", label = words, done = pair.done, total = pair.total, percent = pair.percent }
    end
  end
  -- git
  for _, entry in ipairs({ { "receiving objects:", "receiving objects" }, { "resolving deltas:", "resolving deltas" },
      { "counting objects:", "counting objects" }, { "compressing objects:", "compressing objects" },
      { "remote: compressing objects:", "compressing objects" }, { "remote: counting objects:", "counting objects" } }) do
    local prefix, words = entry[1], entry[2]
    if lower:sub(1, #prefix) == prefix then
      local rest = numbers(lower:sub(#prefix + 1))
      if rest then return { kind = "bar", label = words, done = rest.done, total = rest.total, percent = rest.percent } end
      return { kind = "text", text = words }
    end
  end
  if lower:sub(1, 13) == "cloning into " or lower:sub(1, 21) == "remote: enumerating" then
    return { kind = "text", text = line:sub(1, 1):lower() .. line:sub(2) }
  end
  return nil
end

-- How far back a dialect line may still speak for the call: the newest four non-empty lines. A build's
-- bar must not outlive the build - `cargo test` finishes compiling and then prints its results, and a
-- bar frozen at `143/412` while the tests run would be a moving picture of a finished thing.
M.RECENT = 4

-- The detail of a tail (oldest line first): the newest dialect line among the newest `M.RECENT`
-- non-empty lines, else the last line.
function M.detail(lines)
  local recent = {}
  for index = #lines, 1, -1 do
    local line = tostring(lines[index] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      recent[#recent + 1] = line
      if #recent >= M.RECENT then break end
    end
  end
  for _, line in ipairs(recent) do
    local found = M.dialect(line)
    if found then return found end
  end
  if recent[1] then return { kind = "text", text = recent[1] } end
  return nil
end

-- Redact a row: the node's own secret *values* first (`redact.secrets`, exact replacement), then the
-- credential *shapes* (`redact.text`: `sk-...`, `Bearer ...`, a JWT). `options.secrets` adds values a
-- caller already knows about (the vault's, a value it just read) - the row is the last place a value
-- read from a file should be able to appear.
local function scrub(text, extra)
  local cleaned = select(1, redact.secrets(text))
  for _, value in ipairs(extra or {}) do
    if type(value) == 'string' and #value >= 8 then
      cleaned = cleaned:gsub((value:gsub("%p", "%%%0")), "<redacted>")
    end
  end
  return redact.text(cleaned)
end
M.scrub = scrub

-- The row's text, from its parts. The one place the wording lives.
function M.row_text(tool, elapsed_seconds, detail, silent_seconds)
  local name = tostring(tool or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = "tool" end
  local text = "\u{27F3} " .. name .. " \u{00B7} " .. M.elapsed(elapsed_seconds)
  if (tonumber(silent_seconds) or 0) >= M.STALL_SECONDS then
    return text .. " \u{00B7} " .. M.stall(silent_seconds)
  end
  if type(detail) ~= 'table' then return text end
  if detail.kind == "bar" then
    local total = tonumber(detail.total) or 0
    local done = tonumber(detail.done) or 0
    local count = detail.percent and (done .. "%") or (done .. "/" .. total)
    local fraction = total > 0 and (done / total) or 0
    text = text .. " " .. M.bar(fraction) .. " " .. count
    if detail.label and detail.label ~= "" then text = text .. " " .. detail.label end
    return text
  end
  if detail.text and detail.text ~= "" then return text .. " \u{00B7} " .. detail.text end
  return text
end

-- ---- the call in flight -------------------------------------------------------------
-- One tool call at a time in a CLI: the agent's loop is sequential here, and the row is one line.
local current = nil

function M.reset() current = nil end

-- A call started: `tool` is the name the reader knows (`bash`), `now` the clock.
function M.begin(tool, now)
  current = { tool = tostring(tool or "tool"), started = tonumber(now) or 0, last_output = tonumber(now) or 0,
    lines = {} }
  return current
end

-- A chunk of the call's own output, when the caller has it (`operation`'s streaming reads, a test).
-- `\r` is a line break too: a bar that rewrites itself in place is exactly what this row is for.
function M.observe(chunk, now)
  if not current then return false end
  local added = false
  for piece in (tostring(chunk or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local line = M.printable(piece):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      current.lines[#current.lines + 1] = line:sub(1, MAX_LINE)
      if #current.lines > KEEP_LINES then table.remove(current.lines, 1) end
      added = true
    end
  end
  if added then current.last_output = tonumber(now) or current.last_output end
  return added
end

-- The call ended (or its result arrived): the row goes away now rather than on a timer.
function M.finish() current = nil end

function M.active() return current end

-- The live file's facts, re-read at most once a quarter second - the host publishes at most four
-- times a second, so a faster read cannot be fresher. `options.path` / `options.refresh` for tests.
local memo = { at = nil, path = nil, facts = nil }
function M.live(options)
  local o = options or {}
  local path = o.path or M.path(o)
  local now = tonumber(o.now) or (host and host.now and host.now() or os.time())
  local ms = math.floor(now * 1000)
  if not o.refresh and memo.path == path and memo.at and (ms - memo.at) < 250 then return memo.facts end
  local facts = nil
  local ok, text = pcall(host.read_file, path)
  if ok and type(text) == 'string' and text ~= "" then
    local decoded, value = pcall(json.decode, text)
    if decoded and type(value) == 'table' then facts = value end
  end
  memo.path, memo.at, memo.facts = path, ms, facts
  return facts
end

function M.reset_live() memo.at, memo.path, memo.facts = nil, nil, nil end

-- The row for the call in flight, from the live file when it has something fresher than this
-- process's own tail, else from that tail. `nil` while the call is too young, and `nil` when nothing
-- is running.
-- `options`: `now`, `limit` (columns; the caller clips, this only guards), `path`, `refresh`.
function M.status(options)
  local o = options or {}
  local now = tonumber(o.now) or (host and host.now and host.now() or os.time())
  local facts = M.live({ path = o.path, refresh = o.refresh, now = now })
  local detail, tool, started, last_output = nil, nil, nil, nil
  if type(facts) == 'table' and facts.state == "running" then
    local at = tonumber(facts.at)
    if at and (now - at) <= M.FRESH then
      tool = type(facts.tool) == 'string' and facts.tool or nil
      started = tonumber(facts.started_at)
      last_output = tonumber(facts.last_output_at)
      detail = M.detail_from_facts(facts.detail)
    end
  end
  -- The file is the authority while it is fresh: it is fed by the host's wait loop, which is awake
  -- while this interpreter is not. Without it, this process's own tail answers.
  if not tool and current then
    tool, started, last_output, detail = current.tool, current.started, current.last_output, M.detail(current.lines)
  end
  if not tool or not started then return nil end
  local seconds = now - started
  if seconds < M.MIN_SECONDS then return nil end
  local silent = math.max(0, now - (last_output or started))
  local text = scrub(M.row_text(tool, seconds, detail, silent), o.secrets)
  return { text = text, kind = silent >= M.STALL_SECONDS and "stall" or "tool" }
end

-- A detail table from the live file's JSON (`{kind:bar|text,...}`), in this module's shape.
function M.detail_from_facts(value)
  if type(value) ~= 'table' then return nil end
  if value.kind == "bar" then
    return { kind = "bar", label = tostring(value.label or ""), done = tonumber(value.done) or 0,
      total = tonumber(value.total) or 0, percent = value.percent == true }
  end
  if value.kind == "text" then return { kind = "text", text = tostring(value.text or "") } end
  return nil
end

return M
