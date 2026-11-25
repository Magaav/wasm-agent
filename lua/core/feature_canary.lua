-- The canary of a feature: a synthetic end-to-end exercise that touches nothing of the user's, and
-- answers pass or fail WITH THE STAGE THAT FAILED.
--
-- Between the release gate and a node's real life there was a hole (Victor, 23/11): the gate tests the
-- tree in a scratch home, and the fleet read-back answers 'which commit are you running' - so a feature
-- that installs correctly and then cannot do its work answered PASS on both. The copilot reply was off
-- for two days that way. A canary is the missing question: on THIS node, after THIS install, does the
-- feature still do the thing a user does with it?
--
-- THREE RULES, and they are the whole design:
--   * it touches nothing of the user's. A canary that must write (a turn, a wake, an undo) runs in a
--     CHILD node - this binary, its own scratch home, its own scratch ledger (M.child) - so the
--     operator's ledger, config and files cannot be the thing that passed. A canary that only reads
--     (the index, a component's own config) runs in this process and says mode = 'read'.
--   * it says WHICH STAGE failed. Every exercise prints 'stage: <name>' as it goes; the verdict names
--     the last stage reached, the child's own words, and its exit. 'the canary failed' is the kind of
--     answer that made the original silence possible.
--   * a canary that cannot run is not a pass. A missing exercise, a node with no `wa` binary to spawn, a
--     child that hangs: each is a named failure (canary_missing, binary_unknown, spawn_failed), because
--     'unknown' rendered as 'fine' is exactly the bug.
--
-- WHAT A CANARY IS ON THE DISK: a module at <canary dir>/<row.canary>.lua returning
--   { mode = 'child-node'|'read', run = function(ctx) -> ok, stage, detail }
--
-- `child-node` means what it says: the exercise runs in a PROCESS THIS NODE SPAWNS, with its own home and
-- ledger (feature_canary.child), so it can only prove that the CODE works - never that the LIVE node's own
-- loop is alive. It was called `loopback` until 24/11, and that word read as "this node": on 24/11 the
-- node delivered zero self-wakes for 2.5 hours while `self-wake PASS` kept printing, because the canary's
-- child had a fresh ledger and a counted dispatcher. The live node's own state is /health.wakes.
-- The registry row names it (canary), and scripts/check-features-registry.mjs refuses a row whose module
-- is not there - a feature that ships without an exercise fails a check.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local feature_health = dofile('lua/core/feature_health.lua')

local M = {}

M.DIR = 'lua/core/canaries'
M.TASK_DEADLINE_S = 180

local function getenv(name)
  if type(host.getenv) ~= 'function' then return nil end
  local ok, value = pcall(host.getenv, name)
  if not ok or value == nil or value == '' then return nil end
  return tostring(value)
end

-- host.exec answers JSON TEXT (rust/wa-capabilities/src/host.rs: exec -> push_json), not a table: the exit
-- code is process_exit_code, and a command that could not start answers an error instead. One decoder, so
-- a canary's verdict and the scratch-directory check cannot disagree about what a command did.
local function exec_result(ok, raw)
  if not ok then return nil, tostring(raw) end
  local document = raw
  if type(raw) == 'string' then
    local parsed, decoded = pcall(json.decode, raw)
    if not parsed or type(decoded) ~= 'table' then return nil, 'the command answered something that is not JSON: ' .. tostring(raw):sub(1, 200) end
    document = decoded
  end
  if type(document) ~= 'table' then return nil, 'the command answered nothing' end
  if document.error ~= nil then return nil, tostring(document.error) end
  return {
    code = tonumber(document.process_exit_code or document.code),
    out = tostring(document.stdout or ''),
    err = tostring(document.stderr or ''),
  }
end

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- Where the canary modules are. A caller may name the directory (opts.dir): that is how this module's own
-- test drives fixture canaries, and how a release step can read the canaries it is about to ship rather
-- than the ones a node runs. WA_CANARY_DIR does the same from the outside.
function M.dir(named) return named or getenv('WA_CANARY_DIR') or M.DIR end

function M.path(canary, dir) return M.dir(dir) .. '/' .. tostring(canary) .. '.lua' end

-- The binary a child-node canary spawns: the node's own. WA_BIN is how the suite hands a row the binary of
-- the tree under test; a node answers from its PATH. With neither, the canary is refused by name - a
-- canary that cannot spawn the node must not report that the feature works.
function M.binary()
  local named = getenv('WA_BIN')
  if named then return named, 'WA_BIN' end
  local ok, found = pcall(host.executable_on_path, 'wa')
  if ok and type(found) == 'string' and found ~= '' then return found, 'path' end
  return nil, 'binary_unknown'
end

-- A scratch home for one canary, under the node's own cache directory so nothing lands in a user's files,
-- and removed when the canary is done whatever its verdict.
local function make_scratch(label)
  local base = paths.cache() .. '/canary'
  local directory = string.format('%s/%s-%d', base, tostring(label):gsub('[^%w%-_]', '_'), math.floor(tonumber(host.now()) or 0))
  local made, why = exec_result(pcall(host.exec, 'mkdir -p ' .. quote(directory), '', 30))
  if not made then return nil, 'the canary scratch directory could not be made: ' .. directory .. ' (' .. tostring(why) .. ')' end
  if made.code ~= nil and made.code ~= 0 then return nil, 'the canary scratch directory could not be made: ' .. directory end
  return directory
end

local function remove_scratch(directory)
  if type(directory) ~= 'string' or directory == '' then return end
  pcall(host.exec, 'rm -rf ' .. quote(directory), '', 60)
end

-- One supervised child node with a scratch home and ledger. `args` are extra node arguments; `opts.env`
-- are extra KEY=value entries (WA_SCRIPT is how a canary task names the file the child runs). Answers
-- {code, out, err, stage, fail}, where stage is the last stage the task printed and fail the line it
-- failed on.
function M.child(ctx, args, opts)
  opts = opts or {}
  local binary, why = M.binary()
  if not binary then return { code = nil, stage = why, fail = 'this node has no wa binary to spawn' } end
  local scratch = opts.scratch or ctx.scratch
  if type(scratch) ~= 'string' then return { code = nil, stage = 'no_scratch', fail = 'the canary has no scratch directory' } end
  local home = opts.home or (scratch .. '/home')
  local db = opts.db or (scratch .. '/memory.db')
  local parts = {
    'WASM_AGENT_HOME=' .. quote(home),
    -- A child that inherited the operator's vault or provider could answer on credentials the canary
    -- never configured, and would pass for that reason alone (scripts/lib/test-provider.lua, 11/11).
    'WASM_AGENT_VAULT_URL=', 'WASM_AGENT_VAULT_DIR=', 'WASM_AGENT_VAULT_KEYSTORE=', 'WASM_AGENT_VAULT_PASSPHRASE=',
  }
  for _, entry in ipairs(opts.env or {}) do parts[#parts + 1] = entry end
  local lua_root = getenv('WASM_AGENT_LUA_ROOT')
  if lua_root then parts[#parts + 1] = 'WASM_AGENT_LUA_ROOT=' .. quote(lua_root) end
  local command = 'env ' .. table.concat(parts, ' ') .. ' ' .. quote(binary) .. ' --db ' .. quote(db)
  for _, arg in ipairs(args or {}) do command = command .. ' ' .. quote(arg) end
  local ran, ran_why = exec_result(pcall(host.exec, command, '', opts.deadline or M.TASK_DEADLINE_S))
  if not ran then return { code = nil, stage = 'spawn_failed', fail = tostring(ran_why) } end
  local out, err, code = ran.out, ran.err, ran.code
  local stage, fail
  for line in (out .. '\n' .. err):gmatch('[^\n]+') do
    local named = line:match('^stage:%s*(.+)$')
    if named then stage = named:gsub('%s+$', '') end
    if line:match('^FAIL%s+') then fail = line end
  end
  return { code = tonumber(code), out = out, err = err, stage = stage, fail = fail }
end

-- Load one canary module, and name the fault if it cannot be loaded. One order, so each fault has exactly
-- one name: dofile first (the node's own loader, which resolves a pinned tree copy on an installed node),
-- then the file itself - which is both how a fixture canary outside the tree is reached and how the
-- REASON a module would not load is kept instead of being guessed at.
local function load_canary(path)
  local built, module = pcall(dofile, path)
  if built and type(module) == 'table' and type(module.run) == 'function' then return module end
  local read_ok, text = pcall(host.read_file, path)
  if not (read_ok and type(text) == 'string') then
    return nil, 'canary_missing', 'there is no canary module at ' .. path .. ' (' .. tostring(module) .. ')'
  end
  local chunk, load_error = (loadstring or load)(text, '@' .. path)
  if not chunk then return nil, 'canary_unloadable', path .. ': ' .. tostring(load_error) end
  local ran, value = pcall(chunk)
  if not ran then return nil, 'canary_unloadable', path .. ': ' .. tostring(value) end
  if type(value) ~= 'table' or type(value.run) ~= 'function' then
    return nil, 'canary_malformed', 'a canary module must return { mode = ..., run = function(ctx) }, and this one returned ' .. type(value)
  end
  return value
end

-- Run one feature's canary. Never raises: a canary that raises is a NAMED failure (canary_raised), because
-- a canary is the thing that must still answer when the feature is broken.
function M.run(feature, opts)
  opts = opts or {}
  local row, why = feature_health.row(feature)
  if not row then return { feature = tostring(feature), ok = false, stage = 'unknown_feature', detail = tostring(why) } end
  local path = M.path(row.canary, opts.dir)
  local module, stage, detail = load_canary(path)
  if not module then
    return { feature = row.name, canary = row.canary, ok = false, stage = stage, detail = detail }
  end
  local scratch, scratch_why = make_scratch(row.canary)
  local ctx = {
    feature = row.name, canary = row.canary, row = row, mode = module.mode or 'child-node',
    scratch = scratch, home = paths.config(), now = tonumber(host.now()) or 0,
  }
  local called, ok, ran_stage, ran_detail = pcall(module.run, ctx)
  remove_scratch(scratch)
  if not called then
    return { feature = row.name, canary = row.canary, mode = ctx.mode, ok = false, stage = 'canary_raised', detail = tostring(ok) }
  end
  -- THE THIRD OUTCOME: 'off'. A canary that cannot be exercised because the feature is switched off by its
  -- own configuration (the WhatsApp copilot with posting disabled, the defect this mission starts from)
  -- answers `return 'off', 'off (posting disabled)', why` - it is NOT a pass (nothing was proven) and NOT a
  -- failure (nothing is broken: the operator turned it off). It is printed, counted and named, and it is
  -- never recorded as a success, so a feature that was switched off does not read as "last worked".
  if ok == 'off' then
    return {
      feature = row.name, canary = row.canary, mode = ctx.mode, ok = false, off = true,
      stage = tostring(ran_stage or 'off'), detail = ran_detail and tostring(ran_detail) or nil,
    }
  end
  -- THE FOURTH OUTCOME: 'not_proven'. A canary asked a question this node cannot answer - the mailbox and the
  -- linked device live elsewhere (lua/core/canaries/account.lua) - answers `return 'not_proven', stage, why`.
  -- It is NOT a pass (nothing was proven) and NOT a failure (nothing here is broken), and it records nothing:
  -- the row's last real success keeps its own time, exactly as 'off' does. The release step refuses a release
  -- whose canary is not_proven on EVERY node asked (feature_canary.aggregate).
  if ok == 'not_proven' then
    return {
      feature = row.name, canary = row.canary, mode = ctx.mode, ok = false, not_proven = true,
      stage = tostring(ran_stage or 'not_proven'), detail = ran_detail and tostring(ran_detail) or nil,
    }
  end
  if scratch_why and (ok == false or ok == nil) then ran_detail = tostring(ran_detail or '') .. ' (' .. scratch_why .. ')' end
  return {
    feature = row.name, canary = row.canary, mode = ctx.mode,
    ok = (ok == true), stage = tostring(ran_stage or (ok == true and 'done' or 'failed')),
    detail = ran_detail and tostring(ran_detail) or nil,
  }
end

-- Run every canary this node can run, record each verdict, and answer the rows. A feature whose component
-- this node does not have is SKIPPED with the reason the registry's role gives - a laptop without the
-- WhatsApp component cannot exercise WhatsApp, and saying so is the honest answer; refusing the whole run
-- would teach an operator to ignore it.
function M.run_all(opts)
  opts = opts or {}
  local rows, why = feature_health.rows()
  if not rows then return nil, why end
  local results = {}
  for _, row in ipairs(rows) do
    if not opts.only or row.name == opts.only then
      local applies, not_applicable = feature_health.applies(row)
      if not applies then
        results[#results + 1] = { feature = row.name, canary = row.canary, ok = false, skipped = true,
          stage = 'off-node', detail = not_applicable }
      else
        local result = M.run(row.name, opts)
        -- An 'off' canary records NOTHING: neither a success (nothing was proven) nor a failure (nothing is
        -- broken), so the row's last real success keeps its own time and the reason is the operator's switch.
        if not result.off and not result.not_proven then
          result.recorded = feature_health.record(row.name, result.ok, {
            stage = result.stage, detail = result.detail, source = 'canary' }) and true or false
        end
        results[#results + 1] = result
      end
    end
  end
  return results
end

-- One line per result: what an operator and the release report read.
function M.lines(results)
  local out = {}
  local passed, failed, off, skipped, notproven = 0, 0, 0, 0, 0
  for _, result in ipairs(results or {}) do
    if result.skipped then
      skipped = skipped + 1
      out[#out + 1] = string.format('  %-22s SKIP  %s (%s)', result.feature, tostring(result.stage), tostring(result.detail))
    elseif result.off then
      off = off + 1
      out[#out + 1] = string.format('  %-22s OFF   %s: %s', result.feature, tostring(result.stage), tostring(result.detail))
    elseif result.not_proven then
      notproven = notproven + 1
      out[#out + 1] = string.format('  %-22s NOT PROVEN  %s: %s', result.feature, tostring(result.stage), tostring(result.detail))
    elseif result.ok then
      passed = passed + 1
      -- THE MODE IS PART OF THE VERDICT (r8c item G). "self-wake PASS delivered" read as "this node's own
      -- loop works" while the node delivered nothing for 2.5 hours on 24/11; the line now says WHOSE code was
      -- exercised: a child-node the canary spawned, or a read this process made - never the live node's loop,
      -- which is /health.wakes.
      out[#out + 1] = string.format('  %-22s PASS  %s: %s', result.feature, tostring(result.mode or 'child-node'), tostring(result.stage))
    else
      failed = failed + 1
      out[#out + 1] = string.format('  %-22s FAIL  %s: %s: %s', result.feature, tostring(result.mode or 'child-node'), tostring(result.stage), tostring(result.detail))
    end
  end
  table.insert(out, 1, string.format('canaries: %d passed, %d failed, %d off, %d not proven, %d off-node', passed, failed, off, notproven, skipped))
  return out
end

-- <answers> -> { failed = {...}, off = {...}, proven_nowhere = {...} }
-- answers: a list of { node = <name>, results = { <run_all/run result tables> } } - this node first.
--
-- PROVEN NOWHERE IS A RED (25/11). A canary that answered `not_proven` on EVERY node asked was answered
-- nowhere: the account lives on some other node, so the release has proven nothing about that feature. It is
-- not a fail (no node said it was broken) and it is certainly not a pass - so it is named and it is red.
function M.aggregate(answers)
  local proven, asked, failed, off, nowhere = {}, {}, {}, {}, {}
  for _, answer in ipairs(answers or {}) do
    local node = tostring((type(answer) == "table" and answer.node) or "?")
    for _, result in ipairs((type(answer) == "table" and answer.results) or {}) do
      local feature = tostring(result.feature)
      if result.ok and not result.skipped then proven[feature] = true end
      if result.off then
        off[#off + 1] = node .. "/" .. feature .. " (" .. tostring(result.stage) .. ")"
      elseif result.skipped then
        -- off-node is not an answer about this feature's health
      elseif result.not_proven then
        asked[feature] = (asked[feature] or 0) + 1
      elseif result.ok then
        -- a pass on this node: already recorded above, and it is not a failure of anything
      else
        failed[#failed + 1] = string.format("%s %s (%s)", node, feature, tostring(result.stage))
      end
    end
  end
  for feature, count in pairs(asked) do
    if not proven[feature] then
      nowhere[#nowhere + 1] = string.format("%s (not proven on %d node(s) asked)", feature, count)
    end
  end
  table.sort(failed); table.sort(nowhere)
  return { failed = failed, off = off, proven_nowhere = nowhere }
end

return M
