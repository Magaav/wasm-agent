-- The one rule a test that WRITES a ledger must pass before it runs (item 3, review 19/11).
--
-- A test here starts sessions, journals notes and opens the memory store, so it must never do that
-- against a real node home. The guard that used to stand at the top of these scripts compared
-- `WASM_AGENT_HOME` with `os.getenv("HOME") .. "/.wasm-agent"`, and that comparison can never fire:
-- the host resolves HOME from WASM_AGENT_HOME (rust/wa-host-support/src/paths.rs, `resolve_home`
-- reads WASM_AGENT_HOME first), so the process sees HOME == WASM_AGENT_HOME and the right-hand side
-- is always `<home>/.wasm-agent`, never `<home>`. Measured on this node: with
-- WASM_AGENT_HOME=/tmp/x, HOME is /tmp/x. It also missed the dangerous case outright - a home that
-- IS the user's home, so `<home>/.wasm-agent` is the live state root with the node key and the
-- ledger in it - because that path does not END in `/.wasm-agent`.
--
-- So the rule is an ALLOW-LIST plus an independent refusal, and both name their reason:
--   1. the home must sit under a scratch root the run owns: the one the caller names (GATE_ROOT, else
--      TMPDIR) OR the orchestrator's row contract root, WA_ROW_SCRATCH_ROOT (25/11, measured in row
--      20261125T223107Z-6213: the row runner gives a row HOME=<root>/home with TMPDIR=<root>/tmp, so a
--      guard that knew only TMPDIR refused every Lua row there - "this test writes a ledger: it refuses
--      to run (the test home <root>/home is not under the scratch root <root>/tmp)"). Anything else - a
--      real home, a sibling worktree, a path someone typed - refuses without further inspection;
--   2. it must not carry the live node's own markers, `<home>/.wasm-agent/node.key` (a private key)
--      or `<home>/.wasm-agent/memory.db` (the ledger and the MCP registry). This is what catches the
--      case the allow-list alone would wave through on a node whose scratch root is inside its state
--      root (measured here: TMPDIR is `<state>/tmp`).
-- Existence is asked with `host.canonical_path`, which answers a path when it exists and nil when it
-- does not, WITHOUT reading it - and both probes are injectable, so a test drives the rule with no
-- node, no filesystem and no secret in reach.
local M = {}

-- The files that mean "this is a live node home, not a scratch one".
M.MARKERS = { "node.key", "memory.db" }

local function normalize(path)
  local text = tostring(path or ""):gsub("\\", "/")
  text = text:gsub("/+", "/")
  return text
end

-- Is `child` the same as `root`, or a path under it? On a separator boundary only, so /tmp/wa-1
-- is not "under" /tmp/wa.
local function under(child, root)
  local c, r = normalize(child), normalize(root)
  if r:sub(-1) ~= "/" then r = r .. "/" end
  return c == r:sub(1, -2) or c:sub(1, #r) == r
end

local function host_exists(path)
  local ok, value = pcall(function() return host.canonical_path(path) end)
  if not ok then return false end
  return type(value) == "string" and value ~= ""
end

--- The scratch roots THIS RUN may name, in the order a row tries them: the suite's (GATE_ROOT, else TMPDIR) and the
--- row contract's own (WA_ROW_SCRATCH_ROOT), which the orchestrator's runner exports and the fast path does not.
--- Exported so a row that asks "is this path inside my scratch space?" asks the SAME question the home guard asks,
--- instead of spelling a second rule (measured 25/11: nine Lua rows kept their own and refused a correct runner home).
function M.roots(opts)
  opts = opts or {}
  local roots = {}
  if type(opts.scratch) == "string" and opts.scratch ~= "" then roots[#roots + 1] = opts.scratch end
  local contract_root = opts.root
  if contract_root == nil and type(host) == "table" and type(host.getenv) == "function" then
    local ok, value = pcall(host.getenv, "WA_ROW_SCRATCH_ROOT")
    if ok and type(value) == "string" and value ~= "" then contract_root = value end
  end
  if type(contract_root) == "string" and contract_root ~= "" then roots[#roots + 1] = contract_root end
  return roots
end

--- Is `child` `root` or a path under it (a separator boundary: /tmp/wa-1 is not under /tmp/wa)?
function M.under(child, root) return under(child, root) end

-- nil when the home is safe, else one named reason. `opts`:
--   home     the WASM_AGENT_HOME the test will write (required)
--   scratch  the root the suite owns: GATE_ROOT, else TMPDIR (required)
--   root     the row contract's root (WA_ROW_SCRATCH_ROOT); read from the environment when not given
--   exists   optional `function(path) -> boolean`, for a test with no filesystem
--   resolve  optional `function(path) -> path`, to compare real paths (symlinked /tmp)
function M.reason(opts)
  opts = opts or {}
  local home = opts.home
  local scratch = opts.scratch
  if type(home) ~= "string" or home == "" then
    return "no test home (WASM_AGENT_HOME is unset)"
  end
  -- THE ROOTS THIS RUN MAY NAME: the caller's (GATE_ROOT, else TMPDIR) and the row contract's own, which the
  -- orchestrator's runner exports and the fast path does not (25/11). One allow-list, two spellings, and the home
  -- still has to be UNDER one of them - this widens nothing about a real home.
  local roots = M.roots({ scratch = scratch, root = opts.root })
  if #roots == 0 then
    return "no scratch root (GATE_ROOT, TMPDIR and WA_ROW_SCRATCH_ROOT are all unset), so a home cannot be told from a real one"
  end
  local exists = opts.exists or host_exists
  local resolve = opts.resolve
  local resolved_home = normalize(home)
  if resolve then resolved_home = normalize(resolve(home)) end
  local allowed, named = false, {}
  for _, root in ipairs(roots) do
    local resolved_root = normalize(root)
    if resolve then resolved_root = normalize(resolve(root)) end
    named[#named + 1] = resolved_root
    if under(resolved_home, resolved_root) then allowed = true end
  end
  if not allowed then
    return "the test home " .. resolved_home .. " is not under the scratch root " .. table.concat(named, " or ")
  end
  for _, marker in ipairs(M.MARKERS) do
    local path = resolved_home .. "/.wasm-agent/" .. marker
    if exists(path) then
      return "the test home " .. resolved_home .. " carries a live node's own " .. marker
        .. " (" .. path .. "), so it is (or sits inside) a real node home"
    end
  end
  return nil
end

return M
