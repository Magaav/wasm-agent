-- A tool's wait is ONE number, and no capability may keep a private one below it.
--
-- The rule (Victor 27/11, whatsapp-read-slow-is-not-an-error): a slow answer is not a failure. The wait a
-- call obeys is the shared one - `lua/core/codemode_pending.lua`, `DEFAULT_WAIT_S = 60` with a 300 s ceiling
-- and `effective_ms(wait_s, remaining)` - and a crate that answers a tool call may not bound that answer
-- with a constant of its own.
--
-- WHY THIS ROW EXISTS AND WHY IT IS WRITTEN FIRST. The defect it guards was not a missing column: two
-- crates kept `WAIT_MS = 2_000` and the read's answer was decided by 2 s against a rule that says 60, so a
-- slow read crossed the seam as a THROW and a Promise.all lost its sibling too. A rule nothing checks comes
-- back, so this row is the check: it must FAIL on the code before the fix, and the fix must make it pass
-- without editing it.
--
-- SCOPE, stated so a reviewer can disagree with it precisely. It judges the crates that bound a tool
-- call's own answer and the names inside them that mark such a wait:
--
--   rust/wa-whatsapp-index   the index behind whatsapp_search/read/media/download
--   rust/wa-email-index      the index behind the mail tools
--   rust/wa-capabilities     the host side that calls them (its DOWNLOAD_WAIT_MS)
--
-- It does NOT judge a driver's own budget (`wa-window`'s LAUNCH_WAIT_MS bounds a browser launch, not a
-- tool answer), nor an environment knob (`wa-sentinel`'s WA_WATCHDOG_WAIT_MS), nor the completion wait
-- (`serve.rs` reads WASM_AGENT_COMPLETION_WAIT_SECONDS, which is already an env value and not a constant).
-- Those are reviewed where they live; this row is about the answer to a call.
local failed, checks = 0, 0

local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end

local function read(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("a")
  file:close()
  return text
end

-- The one shared default, read from the file that owns it. Copied numbers are how the two 2 s constants
-- happened in the first place.
local pending = read("lua/core/codemode_pending.lua")
assert(pending, "lua/core/codemode_pending.lua is not readable; this row judges the tree it runs in")
local default_s = tonumber(pending:match("M%.DEFAULT_WAIT_S%s*=%s*(%d+)"))
assert(default_s and default_s > 0, "M.DEFAULT_WAIT_S not found in codemode_pending.lua")
local shared_ms = default_s * 1000

ok(shared_ms == 60000, "the shared default is read from its owner and is 60 s (it is " .. shared_ms .. " ms)")

local judged = {
  "rust/wa-whatsapp-index/src/lib.rs",
  "rust/wa-email-index/src/lib.rs",
  "rust/wa-capabilities/src/whatsapp_query.rs",
}

-- Every `const NAME: u64 = N;` whose name ends in WAIT_MS, with its number.
local function private_waits(text)
  local found = {}
  -- The name is captured whole and then tested for the suffix: `[A-Z][A-Z0-9_]*WAIT_MS` cannot match a
  -- bare `WAIT_MS` (the first class eats the W and the literal can never find a second one), which is a
  -- way for a scan like this to see only the prefixed constants and call the tree clean.
  for name, number in text:gmatch("const%s+([A-Z][A-Z0-9_]*)%s*:%s*u64%s*=%s*([%d_]+)") do
    if name:sub(-7) == "WAIT_MS" then
      local value = tonumber((number:gsub("_", "")))
      if value then found[#found + 1] = { name = name, ms = value } end
    end
  end
  return found
end

-- The scan must SEE the code it judges: a row that finds nothing passes for the wrong reason.
local seen = 0
local offenders = 0
for _, path in ipairs(judged) do
  local text = read(path)
  ok(text ~= nil, path .. " is readable")
  if text then
    for _, wait in ipairs(private_waits(text)) do
      seen = seen + 1
      if wait.ms < shared_ms then
        offenders = offenders + 1
        ok(false, path .. ": " .. wait.name .. " = " .. wait.ms .. " ms is a private wait below the shared "
          .. shared_ms .. " ms; the call must obey effective_ms(wait_s, remaining), not a constant")
      end
    end
  end
end

-- The scan must WORK on a fix that leaves nothing to complain about: a row that only fails while offenders
-- exist would report "clean" for a broken pattern the moment the tree was fixed. So the pattern is
-- exercised on a sample of its own, and the real scan is allowed to find zero.
local sample = 'pub const WAIT_MS: u64 = 2_000;' .. "\n" .. 'pub const DOWNLOAD_WAIT_MS: u64 = 10_000;'
ok(#private_waits(sample) == 2, "the scan reads a bare WAIT_MS and a prefixed one out of a sample")
ok(#private_waits("// nothing here") == 0, "and finds nothing in a sample that holds no wait")
ok(true, offenders .. " private wait(s) below the shared default, of " .. seen .. " judged (0 is the fixed tree)")

if failed > 0 then
  print("waits-follow-the-shared-rule: " .. failed .. " failed of " .. checks .. " checks")
  os.exit(1)
end
print("waits-follow-the-shared-rule ok (" .. checks .. " checks)")
