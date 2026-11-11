-- The done gate: a turn ends when the request is done or measurably impossible, and the harness
-- decides that from checks the run itself recorded - never from a nudge in the prompt.
--
-- Measured, 10/11 and 11/11 (the operator's "fix 1"): sessions ended turns at natural break points
-- with work remaining and needed a human "go/continue". session b5a92f25 spent 18 operator messages
-- and about five hours on one request; session 0ed9a783 stopped after phase 1 with "phases 2-4 not
-- started"; session 08c59fbc said "I stopped exploring" with its bootstrap unfinished; session
-- 31792e47 said "done to the limit" with its landing pending. One session even wrote its own
-- acceptance check and then dropped it. None of those answers was a lie about the machine - each was
-- a true account of a turn that stopped because the model had run out of things it wanted to say.
--
-- The operator's rule is that models are free: no turn cap, no round cap, no nudge text. So the fix
-- cannot be "ask it to keep going" - it has to be a fact the harness can test. The facts are:
--
--   capture   a "do X" request gets its acceptance checks written down next to the operator's
--             verbatim words, in this session's own store, before the work starts. A check is a
--             command the harness can run and read, or a written criterion a fresh verifier judges.
--   gate      when the model ends a turn, the harness runs the recorded command checks. A failing
--             check whose output is not a named, measured impossibility re-enters the run with the
--             operator's words and the failing output - it does not end the turn.
--   no budget nothing here counts rounds. The loop ends on pass, on a measured impossibility, on
--             operator input, or on a stall: the same failing output N times with no state change.
--             A stall is one named record plus one wake, because a loop that will not move is a fact
--             the operator needs, not a turn to spend.
--   questions an explanation request makes no state change and is never gated: with no gate there is
--             nothing to test, and the gate is only ever created by a recorded capture.
--
-- What the checks may change: a command check runs through `host.exec` in the session's workdir, as
-- the node's own user. It is a probe, not a sandbox - a check that writes is the model's own doing,
-- and `docs/DONE-GATE.md` says so. The harness runs it; it does not launder it.
--
-- Durability: an open gate survives a restart, a compaction and a wake, because it is a row in the
-- memory database (`done_gates`, `done_checks`), beside the transcript, not a field of the object
-- that happens to be running. A later turn in the same session reads the same checks - which is the
-- whole point: the acceptance checks outlive the run that wrote them.
--
-- Nothing in this module calls a model except through the `verify` function the caller injects, and
-- nothing in it writes a token to the transcript except the sentence the caller sends. That keeps
-- the judgement testable without a provider: `scripts/test-done-gate.lua` drives it with a fake
-- verifier, a real shell and a scratch database.

local json = dofile("lua/vendor/json.lua")

local M = {}

-- Modules are cached per interpreter: the gate is consulted at every turn end, and re-loading
-- memory.lua to read one row would re-register the whole tool catalogue on the way.
local deps = {}
local function dep(name)
  if not deps[name] then deps[name] = dofile("lua/core/" .. name .. ".lua") end
  return deps[name]
end

local function sql(method, statement, params)
  local raw = host[method](statement, json.encode(params or {}))
  local value = raw
  if type(raw) == "string" then
    local ok, decoded = pcall(json.decode, raw)
    if not ok then error("done_gate_store: unreadable answer") end
    value = decoded
  end
  if type(value) ~= "table" then error("done_gate_store: no answer from " .. method) end
  if value.error then error(tostring(value.error)) end
  return value
end
local function exec(statement, params) return sql("sql_exec", statement, params) end
local function query(statement, params) return sql("sql_query", statement, params) end

local ready = false
local SCHEMA = {
  [[CREATE TABLE IF NOT EXISTS done_gates (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    owner TEXT NOT NULL DEFAULT '',
    request TEXT NOT NULL DEFAULT '',
    request_seq INTEGER,
    status TEXT NOT NULL DEFAULT 'open',
    close_code TEXT NOT NULL DEFAULT '',
    close_detail TEXT NOT NULL DEFAULT '',
    wake_id TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    closed_at REAL
  )]],
  [[CREATE INDEX IF NOT EXISTS done_gates_session_idx ON done_gates(session_id, status, created_at)]],
  [[CREATE TABLE IF NOT EXISTS done_checks (
    id TEXT PRIMARY KEY,
    gate_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    kind TEXT NOT NULL,
    command TEXT NOT NULL DEFAULT '',
    expect TEXT NOT NULL DEFAULT '',
    expect_exit INTEGER,
    timeout_seconds REAL,
    text TEXT NOT NULL DEFAULT '',
    why TEXT NOT NULL DEFAULT '',
    added_by TEXT NOT NULL DEFAULT 'model',
    added_at REAL NOT NULL,
    removed_at REAL,
    removed_by TEXT NOT NULL DEFAULT '',
    operator_quote TEXT NOT NULL DEFAULT '',
    weakened_from TEXT NOT NULL DEFAULT ''
  )]],
  [[CREATE INDEX IF NOT EXISTS done_checks_gate_idx ON done_checks(gate_id, ordinal)]],
}

-- Create the tables once per interpreter. `IF NOT EXISTS` keeps a second interpreter safe; the flag
-- keeps the (write-locking) DDL off every turn end.
function M.setup()
  if ready then return true end
  dep("memory").setup()
  for _, statement in ipairs(SCHEMA) do exec(statement, {}) end
  ready = true
  return true
end

-- ---- shapes -----------------------------------------------------------------------------------

M.CHECK_LIMIT = 24
M.OUTPUT_LIMIT = 4000
M.STALL_LIMIT_DEFAULT = 3
M.COMMAND_TIMEOUT = 120

local function now_seconds()
  return host.now and host.now() or os.time()
end

-- Where a command check runs: the session's own worktree when it has one, else the node's cwd. The
-- same rule the agent uses for its workdir (`lua/core/agent.lua`, `M.workdir`), because a check that
-- runs somewhere else than the work is a check of the wrong tree.
function M.session_cwd(session_id)
  local ok, worktree = pcall(function() return dep("memory").session_worktree(session_id) end)
  if ok and type(worktree) == "string" and worktree ~= "" then return worktree end
  local platform_ok, cwd = pcall(function() return dep("platform").cwd() end)
  if platform_ok and type(cwd) == "string" then return cwd end
  return ""
end

-- A JSON/SQL NULL for a positional parameter list: an absent value in the middle of an array would
-- make it sparse, and the encoder refuses a sparse array rather than guessing which hole it was.
local function null() return setmetatable({}, { __json_empty = "null" }) end

-- Whitespace-collapsed, for comparing an operator's words with the transcript. Case is kept: an
-- operator quote is a quote, and a near-match is not consent.
function M.normalize(text)
  return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- One imported fact per check, from the tool arguments or a test. `command` makes it a command
-- check; `text` alone makes it a written criterion. An unknown shape is refused rather than
-- guessed: a check nobody can run or judge is worse than no check.
function M.check_spec(raw)
  if type(raw) ~= "table" then return nil, "done_gate_check_must_be_an_object" end
  local command = type(raw.command) == "string" and M.normalize(raw.command) or ""
  local text = type(raw.text) == "string" and M.normalize(raw.text) or ""
  if command == "" and text == "" then
    return nil, "done_gate_check_needs_command_or_text"
  end
  if command ~= "" then text = "" end
  local expect_exit = raw.expect_exit
  if expect_exit ~= nil then
    expect_exit = tonumber(expect_exit)
    if expect_exit == nil or expect_exit % 1 ~= 0 then return nil, "done_gate_expect_exit_must_be_a_whole_number" end
  end
  local timeout = tonumber(raw.timeout_seconds)
  if timeout ~= nil and (timeout <= 0 or timeout > 3600) then return nil, "done_gate_timeout_out_of_range" end
  return {
    kind = command ~= "" and "command" or "criterion",
    command = command,
    text = text,
    expect = type(raw.expect) == "string" and raw.expect or "",
    expect_exit = expect_exit,     -- nil means "0 for a command check, 0 for a probe"
    timeout_seconds = timeout,
    why = type(raw.why) == "string" and raw.why:sub(1, 400) or "",
  }
end

-- ---- is this request work? --------------------------------------------------------------------

-- The verbs a "do X" request starts with. This list only decides whether the harness ASKS for a
-- capture at a turn end; it never decides whether a check passes. A wrong answer therefore costs one
-- extra round (the run is told to write its acceptance checks), never a false verdict on the work.
local WORK_VERBS = {
  ["do"] = true, ["fix"] = true, ["build"] = true, ["implement"] = true, ["add"] = true,
  ["make"] = true, ["write"] = true, ["run"] = true, ["deploy"] = true, ["update"] = true,
  ["land"] = true, ["send"] = true, ["create"] = true, ["install"] = true, ["migrate"] = true,
  ["test"] = true, ["check"] = true, ["verify"] = true, ["prove"] = true, ["clean"] = true,
  ["remove"] = true, ["delete"] = true, ["refactor"] = true, ["wire"] = true, ["commit"] = true,
  ["push"] = true, ["continue"] = true, ["finish"] = true, ["resume"] = true, ["start"] = true,
  ["stop"] = true, ["restart"] = true, ["upgrade"] = true, ["rename"] = true, ["move"] = true,
  ["review"] = true, ["audit"] = true, ["investigate"] = true, ["bootstrap"] = true,
  ["generate"] = true, ["configure"] = true, ["enable"] = true, ["merge"] = true, ["rebase"] = true,
  ["revert"] = true, ["patch"] = true, ["ship"] = true, ["publish"] = true, ["reproduce"] = true,
  ["measure"] = true, ["benchmark"] = true, ["profile"] = true, ["debug"] = true, ["sync"] = true,
  ["port"] = true, ["extract"] = true, ["convert"] = true, ["split"] = true, ["replace"] = true,
  ["record"] = true, ["schedule"] = true, ["tighten"] = true, ["reduce"] = true, ["find"] = true,
}

-- The openers that make a question about work rather than a request to do it: "explain why the build
-- fails" is not "fix the build", and gating it would be exactly the over-reach the operator forbade.
local ASKING = {
  ["explain"] = true, ["describe"] = true, ["summarize"] = true, ["summarise"] = true,
  ["what"] = true, ["why"] = true, ["how"] = true, ["who"] = true, ["where"] = true,
  ["when"] = true, ["which"] = true, ["tell"] = true, ["show"] = true, ["compare"] = true,
  ["read"] = true, ["list"] = true, ["is"] = true, ["are"] = true, ["was"] = true,
  ["were"] = true, ["does"] = true, ["did"] = true, ["can"] = true, ["could"] = true,
  ["would"] = true, ["should"] = true,
}

-- Does this message ask for a change in the world?
--
-- The rule is deliberately dumb and deterministic, because it is a policy switch a reader has to be
-- able to predict: an asking word first (`what`, `why`, `how`, `explain`, ...) or a trailing `?` with
-- no imperative verb is a question; an imperative verb first, "can you <verb>", "please <verb>",
-- "I need ...", "let's ...", a numbered list or a phased plan is work.
function M.work_shaped(text)
  local t = M.normalize(text):lower()
  if t == "" then return false end
  local first = t:match("^([%a']+)") or ""
  -- The polite form is checked before the asking words, because "can" is both: "can you deploy it" is a
  -- request, "can the deploy fail" is a question, and the verb after it is what tells them apart.
  local polite = t:match("^can you (%a+)") or t:match("^could you (%a+)")
    or t:match("^would you (%a+)") or t:match("^please (%a+)")
  if polite then return WORK_VERBS[polite] == true end
  if ASKING[first] then return false end
  if WORK_VERBS[first] then return true end
  if t:sub(-1) == "?" then return false end
  if t:match("^i need ") or t:match("^i want ") or t:match("^let's ") or t:match("^let us ") then
    return true
  end
  if t:match("%d+[%.%)]%s") or t:find(" phase", 1, true) or t:find("phase ", 1, true)
      or t:find(" then ", 1, true) or t:find(" until ", 1, true) then
    return true
  end
  return false
end

-- ---- the store --------------------------------------------------------------------------------

local function gate_row(id)
  M.setup()
  return query("SELECT * FROM done_gates WHERE id=?", { id })[1]
end

-- The newest open gate for a session, whatever request it belongs to. Used where a call is about the
-- mission in front of the run (add a check, declare it impossible) and for a harness turn that has no
-- operator words of its own.
function M.open_gate(session_id)
  M.setup()
  local row = query("SELECT * FROM done_gates WHERE session_id=? AND status='open' ORDER BY created_at DESC LIMIT 1",
    { tostring(session_id or "") })[1]
  return row or nil
end

-- The gate recorded for ONE request, in any status. This is the pair that matters: the same operator
-- words are judged against the same checks for as long as the session lives, and a request that was
-- already answered cannot be gated twice. Two different requests in one session are two gates - a
-- session is a conversation, a mission is a request.
function M.gate_for(session_id, request)
  M.setup()
  local wanted = M.normalize(request)
  if wanted == "" then return nil end
  local rows = query("SELECT * FROM done_gates WHERE session_id=? ORDER BY created_at DESC LIMIT 40",
    { tostring(session_id or "") })
  for _, row in ipairs(rows) do
    if M.normalize(row.request) == wanted then return row end
  end
  return nil
end

function M.gate(id)
  local row = gate_row(tostring(id or ""))
  return row or nil
end

-- Live checks, in the order they were recorded. A removed check keeps its row (the history is the
-- audit trail) and is not part of the gate any more.
function M.checks(gate_id)
  M.setup()
  local rows = query("SELECT * FROM done_checks WHERE gate_id=? AND removed_at IS NULL ORDER BY ordinal, added_at",
    { tostring(gate_id or "") })
  for _, row in ipairs(rows) do
    row.ordinal = tonumber(row.ordinal) or 0
    row.expect_exit = row.expect_exit ~= nil and tonumber(row.expect_exit) or nil
    row.added_at = tonumber(row.added_at) or 0
  end
  return rows
end

function M.removed_checks(gate_id)
  M.setup()
  return query("SELECT * FROM done_checks WHERE gate_id=? AND removed_at IS NOT NULL ORDER BY removed_at",
    { tostring(gate_id or "") })
end

local function next_ordinal(gate_id)
  local row = query("SELECT COALESCE(MAX(ordinal),0) AS ordinal FROM done_checks WHERE gate_id=?", { gate_id })[1]
  return (tonumber(row and row.ordinal) or 0) + 1
end

-- Add one check. `who` is `model` unless a caller says otherwise; the operator's own words are the
-- only thing that may remove one (see M.remove).
function M.add(gate_id, session_id, spec, who)
  M.setup()
  local id = host.uuid()
  exec([[INSERT INTO done_checks(id,gate_id,session_id,ordinal,kind,command,expect,expect_exit,timeout_seconds,
      text,why,added_by,added_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)]],
    { id, gate_id, session_id, next_ordinal(gate_id), spec.kind, spec.command or "",
      spec.expect or "", spec.expect_exit or null(), spec.timeout_seconds or null(), spec.text or "", spec.why or "",
      who or "model", now_seconds() })
  return id
end

-- Close the gate with a named status. Only `open` gates do work at a turn end, so this is the one
-- effect that stops the harness from re-entering.
function M.close(gate_id, status, code, detail)
  M.setup()
  local now = now_seconds()
  exec("UPDATE done_gates SET status=?,close_code=?,close_detail=?,closed_at=?,updated_at=? WHERE id=?",
    { tostring(status or "passed"), tostring(code or ""), tostring(detail or ""):sub(1, 4000), now, now,
      tostring(gate_id) })
  return gate_row(gate_id)
end

function M.set_wake(gate_id, wake_id)
  M.setup()
  exec("UPDATE done_gates SET wake_id=?,updated_at=? WHERE id=?", { tostring(wake_id or ""), now_seconds(), tostring(gate_id) })
end

-- The newest operator turn in this session, verbatim. The request a gate is judged against is always
-- one of these rows, never a string the model typed: a paraphrase of the request cannot weaken it.
function M.latest_user_text(session_id)
  local ok, rows = pcall(function()
    return dep("memory").session_messages(session_id, { all = true, limit = 400 })
  end)
  if not ok or type(rows) ~= "table" then return nil end
  for index = #rows, 1, -1 do
    local row = rows[index]
    if row.role == "user" and type(row.content) == "string" and M.normalize(row.content) ~= "" then
      return row.content, tonumber(row.seq)
    end
  end
  return nil
end

-- Is `quote` something the operator actually said in this session? Whitespace is collapsed on both
-- sides; nothing else is forgiven. This is what makes "remove a check" an operator decision instead
-- of a model one: consent has to already exist in the transcript.
function M.operator_said(session_id, quote)
  local wanted = M.normalize(quote)
  if wanted == "" then return nil end
  local ok, rows = pcall(function()
    return dep("memory").session_messages(session_id, { all = true, limit = 400 })
  end)
  if not ok or type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do
    if row.role == "user" and type(row.content) == "string" then
      if M.normalize(row.content):find(wanted, 1, true) then return row end
    end
  end
  return nil
end

-- ---- running a check --------------------------------------------------------------------------

-- One command check through the host: `{ passed, code, output, ms }`. `expect_exit` defaults to 0 for
-- a check; `expect` is a literal substring of stdout+stderr and is only required when it was given.
-- A check that could not run at all (no shell, no exec capability) is a failure with the reason, not
-- a pass and not an exception: a gate that crashes the run would be worse than the stop it fixes.
function M.run_command(check, cwd, default_timeout)
  local timeout = tonumber(check.timeout_seconds) or tonumber(default_timeout) or M.COMMAND_TIMEOUT
  local started = now_seconds()
  if type(host.exec) ~= "function" then
    return { passed = false, code = nil, output = "the node has no host.exec; a command check cannot run here" }
  end
  local ok, raw = pcall(host.exec, check.command, cwd or "", timeout)
  if not ok then
    return { passed = false, code = nil, output = "the shell refused the check: " .. tostring(raw) }
  end
  local result = raw
  if type(raw) == "string" then
    local decoded_ok, decoded = pcall(json.decode, raw)
    result = decoded_ok and decoded or { stdout = raw, code = 0 }
  end
  if type(result) ~= "table" then
    return { passed = false, code = nil, output = "the shell returned no readable result" }
  end
  local output = tostring(result.stdout or "")
  if result.stderr and result.stderr ~= "" then
    output = output .. (output ~= "" and "\n" or "") .. tostring(result.stderr)
  end
  if #output > M.OUTPUT_LIMIT then output = output:sub(1, M.OUTPUT_LIMIT) .. "\n(output truncated)" end
  local code = tonumber(result.code)
  local expected = check.expect_exit
  if expected == nil then expected = 0 end
  local passed = (code == expected)
  if passed and check.expect and check.expect ~= "" then
    passed = output:find(check.expect, 1, true) ~= nil
  end
  return { passed = passed, code = code, expected_exit = expected, output = output,
    ms = math.floor((now_seconds() - started) * 1000),
    timed_out = result.timed_out == true or nil }
end

-- ---- evaluation ------------------------------------------------------------------------------

local function clip(text, limit)
  local value = tostring(text or "")
  if #value <= limit then return value end
  return value:sub(1, limit) .. "\n(truncated, " .. #value .. " bytes)"
end

-- The fresh verifier's prompt. It sees the request, the criteria and the evidence - never the working
-- agent's reasoning, never its transcript, never a claim about what it intended to do. It has no
-- stake: it did not do the work and its answer cannot finish the task, only hold or release it.
M.VERIFIER_SYSTEM = table.concat({
  "You are a verifier. You did not do this work and you have no stake in its outcome.",
  "You are given: the operator's request, verbatim; the acceptance criteria someone wrote for it;",
  "and the evidence the working agent produced.",
  "",
  "Judge each criterion literally against the evidence. A criterion is satisfied only when the",
  "evidence shows it: a plan, a promise, a summary of what was intended, or work that is 'mostly'",
  "done does not satisfy it. A criterion that the evidence does not mention is NOT satisfied.",
  "Do not reward effort, do not infer files you cannot see, and do not accept the agent's own",
  "verdict as evidence. If the evidence is ambiguous, the criterion fails.",
  "",
  "Answer with JSON only, no prose before or after:",
  '{"verdicts":[{"id":"c1","pass":true,"reason":"one sentence citing the evidence"}]}',
  "One entry per criterion, in the order given, ids exactly as given.",
}, "\n")

-- Build the verifier's user message. Bounded: a gate must not spend the whole window on evidence.
function M.verifier_message(request, criteria, evidence)
  local lines = { "Request (verbatim, the operator's own words):", "", tostring(request or ""), "",
    "Acceptance criteria to judge:", "" }
  for index, criterion in ipairs(criteria) do
    lines[#lines + 1] = string.format("c%d. %s%s", index, tostring(criterion.text or ""),
      criterion.why and criterion.why ~= "" and (" (" .. criterion.why .. ")") or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Evidence (everything the working agent chose to show):"
  lines[#lines + 1] = ""
  lines[#lines + 1] = clip(evidence, 12000)
  return table.concat(lines, "\n")
end

-- Parse the verifier's answer into `{ pass = bool, reason = string }` per criterion id. A reply that
-- is not the JSON asked for is `unjudged`, never a pass: an unreadable verdict must not release work.
function M.parse_verdicts(text, count)
  local raw = tostring(text or "")
  local start = raw:find("{", 1, true)
  local finish = raw:match(".*()}")
  local verdicts = {}
  if start and finish and finish > start then
    local ok, decoded = pcall(json.decode, raw:sub(start, finish))
    if ok and type(decoded) == "table" and type(decoded.verdicts) == "table" then
      for index, item in ipairs(decoded.verdicts) do
        if type(item) == "table" then
          local pass = item.pass == true or item.verdict == true or item.verdict == "pass"
          verdicts[index] = { pass = pass, reason = tostring(item.reason or "") }
        end
      end
    end
  end
  for index = 1, count do
    if not verdicts[index] then
      verdicts[index] = { pass = false, unjudged = true,
        reason = "the verifier's answer could not be read: " .. clip(raw, 400) }
    end
  end
  return verdicts
end

-- Evaluate every live check. Command checks run here, in the session's workdir; written criteria go to
-- the injected `verify` function (one call for all of them). Returns
--   { ok, total, judged, results = { {id,label,kind,passed,output,reason} }, failing = {...},
--     fingerprint = <digest of the failing output>, unjudged = <count> }
-- `fingerprint` is what the stall detector compares: the same failing bytes twice in a row with no
-- state change is a loop, and the digest is taken over the failing checks only, so a fix that leaves
-- one check failing in the same way is still visible as the same loop.
function M.evaluate(gate, opts)
  opts = opts or {}
  local rows = M.checks(gate.id)
  local results, failing, criteria = {}, {}, {}
  for _, row in ipairs(rows) do
    if row.kind == "command" then
      local outcome = M.run_command(row, opts.cwd, opts.timeout_seconds)
      results[#results + 1] = { id = row.id, kind = "command", label = row.command,
        passed = outcome.passed == true, output = outcome.output, code = outcome.code,
        expected_exit = outcome.expected_exit, why = row.why }
      if not outcome.passed then failing[#failing + 1] = results[#results] end
    else
      criteria[#criteria + 1] = { row = row, text = row.text, why = row.why, index = #results + 1 }
      results[#results + 1] = { id = row.id, kind = "criterion", label = row.text, passed = false,
        unjudged = true, why = row.why }
    end
  end
  local unjudged = 0
  if #criteria > 0 then
    if type(opts.verify) ~= "function" then
      -- No verifier: the criteria cannot be judged here. Say so instead of failing or passing them;
      -- the caller decides (agent.lua ends the turn and reports it, which is visible).
      for _, item in ipairs(criteria) do
        local result = results[item.index]
        result.reason = "no verifier is available in this run"
        unjudged = unjudged + 1
        failing[#failing + 1] = result
      end
    else
      local verdicts
      local ok, answer = pcall(opts.verify, M.verifier_message(gate.request, criteria, opts.evidence or ""))
      if ok and type(answer) == "string" then
        verdicts = M.parse_verdicts(answer, #criteria)
      else
        verdicts = M.parse_verdicts("", #criteria)
        for index = 1, #criteria do
          verdicts[index].reason = "the verifier call failed: " .. clip(tostring(answer), 300)
        end
      end
      for index, item in ipairs(criteria) do
        local verdict = verdicts[index]
        local result = results[item.index]
        result.passed = verdict.pass == true
        result.unjudged = verdict.unjudged or nil
        result.reason = verdict.reason or ""
        if result.passed then result.output = result.reason else
          unjudged = unjudged + (result.unjudged and 1 or 0)
          failing[#failing + 1] = result
        end
      end
    end
  end
  local parts = {}
  for _, result in ipairs(failing) do
    parts[#parts + 1] = tostring(result.id) .. "|" .. tostring(result.code) .. "|" .. tostring(result.output or result.reason or "")
  end
  table.sort(parts)
  local fingerprint = host.sha256(table.concat(parts, "\n"))
  return { ok = #failing == 0, total = #rows, failing = failing, results = results,
    unjudged = unjudged, fingerprint = fingerprint }
end

-- ---- the turn-end decision ---------------------------------------------------------------------

function M.stall_limit()
  local raw = tonumber(host.getenv("WASM_AGENT_DONE_GATE_STALL") or "")
  if raw == nil or raw < 2 then return M.STALL_LIMIT_DEFAULT end
  return math.floor(raw)
end

-- The state a run carries between turn ends: only what the stall detector needs.
function M.new(opts)
  opts = opts or {}
  local request = tostring(opts.request or "")
  return {
    session_id = tostring(opts.session_id or ""),
    owner = tostring(opts.owner or ""),
    request = request,
    work_shaped = opts.work_shaped ~= nil and opts.work_shaped or M.work_shaped(request),
    -- A harness turn (`[self-wake]`, `[run failure]`, `[done gate ...]`) has no operator words of its
    -- own: it continues the mission already recorded, so it inherits the newest open gate and never
    -- asks for a capture.
    harness_turn = M.normalize(request):sub(1, 1) == "[",
    stall_limit = tonumber(opts.stall_limit) or M.stall_limit(),
    disabled = opts.disabled == true,
    called_tools = false,
    fingerprint = nil,
    state_digest = nil,
    repeats = 0,
    reentries = 0,
    outcomes = {},
  }
end

local function quote_for_message(text, limit)
  local value = tostring(text or "")
  if #value > limit then value = value:sub(1, limit) .. " (truncated)" end
  return value
end

-- The message that re-enters a run. It is the operator's own words plus what the machine just saw -
-- not an instruction to try harder, and not a new request. `[done gate]` marks it as a harness turn so
-- a later reader (and the model) can tell it apart from a human message.
function M.reentry_message(gate, evaluation)
  local lines = {
    "[done gate · harness] The operator's request is not finished. This is not a new request: the",
    "turn ended while an acceptance check recorded for it still fails.",
    "",
    "The operator's words, verbatim:",
    "",
    quote_for_message(gate.request, 4000),
    "",
    "Failing checks, run by the harness just now:",
  }
  for _, result in ipairs(evaluation.failing) do
    if result.kind == "command" then
      lines[#lines + 1] = string.format("- `%s` exited %s (expected %s)", result.label,
        tostring(result.code), tostring(result.expected_exit))
    else
      lines[#lines + 1] = string.format("- criterion: %s", result.label)
      lines[#lines + 1] = "  verifier: " .. tostring(result.reason or "")
    end
    local output = tostring(result.output or "")
    if output ~= "" then
      for line in (output .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = "  | " .. line end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Finish the work, then end the turn; the same checks run again. To add a check, call"
  lines[#lines + 1] = "done_criteria {action=\"add\"}. To end on evidence instead, call done_criteria"
  lines[#lines + 1] = "{action=\"impossible\", reason=..., probes=[{command=..., expect_exit=..., expect=...}]}"
  lines[#lines + 1] = "with a probe the harness can rerun. A recorded check can only be removed with the"
  lines[#lines + 1] = "operator's own words, quoted in the call."
  return table.concat(lines, "\n")
end

-- A work-shaped request with no gate: the run changed the world and recorded nothing to test it
-- against. This is NOT re-entered - the harness cannot invent the criterion, and an extra round of
-- "record your checks" is a turn spent on paperwork nobody asked for. It is recorded instead: a gate
-- row whose status says `uncaptured`, a status line the reader sees, and a telemetry event, so a run
-- that skipped the capture is a visible fact rather than a silent one. `docs/DONE-GATE.md` says so.
function M.record_uncaptured(state, ctx)
  M.setup()
  local detail = "the run changed state and recorded no acceptance checks for this request"
  local id, seq = M.latest_user_text(state.session_id)
  local request = id or state.request
  local now = now_seconds()
  local gate_id = host.uuid()
  exec([[INSERT INTO done_gates(id,session_id,owner,request,request_seq,status,close_code,close_detail,created_at,updated_at,closed_at)
    VALUES(?,?,?,?,?,'uncaptured','no_checks_recorded',?,?,?,?)]],
    { gate_id, state.session_id, state.owner, tostring(request):sub(1, 20000), seq or null(), detail:sub(1, 4000),
      now, now, now })
  if type(ctx.emit) == "function" then
    pcall(ctx.emit, { type = "status", text = "done gate: this request changed state but recorded no "
      .. "acceptance checks; recorded (done_criteria {action=\"status\"})" })
  end
  return gate_id
end

-- One named, durable record of a loop that will not move, plus one wake. The record goes through
-- lua/core/run_failure.lua when that module is present (the same row shape and the same bus/event
-- channels every other non-answer ending uses); until it lands, the same fact is written here, so
-- this branch does not depend on another branch's uncommitted file.
--
-- `mission` is anything with `session_id` and `owner` - a gate row, or the run's own state when the
-- stall is the capture demand repeating (there is no gate to name there).
function M.stall_record(mission, evaluation, ctx)
  local failing = {}
  for _, result in ipairs(evaluation.failing) do
    failing[#failing + 1] = result.kind == "command"
      and (result.label .. " -> exit " .. tostring(result.code))
      or ("criterion: " .. tostring(result.label))
  end
  table.sort(failing)
  local detail = string.format("the same %d acceptance check(s) failed with the same output %d turn(s) in a row "
    .. "and nothing changed: %s", #evaluation.failing, ctx.repeats, table.concat(failing, "; "))
  local info = {
    code = "done_gate_stalled",
    why = "the recorded acceptance checks did not move",
    detail = detail:sub(1, 2000),
    retryable = false,
    text = "run_failed: done_gate_stalled - the recorded acceptance checks did not move: " .. detail:sub(1, 1200),
  }
  local opts = { session_id = mission.session_id, user_id = mission.owner, message_id = ctx.message_id,
    at = math.floor(now_seconds() * 1000) }
  local recorded, announced
  local ok, run_failure = pcall(dofile, "lua/core/run_failure.lua")
  if ok and type(run_failure) == "table" and type(run_failure.record) == "function" then
    local wrote, answer = pcall(run_failure.record, info, opts)
    if wrote then recorded = answer end
    local announced_ok, channels = pcall(run_failure.announce, info, opts)
    if announced_ok then announced = channels end
  end
  if not recorded then
    -- Same row shape as run_failure.record: one assistant row, ok=false, content = the named fact.
    local memory = dep("memory")
    local id = host.uuid()
    memory.append_turn(mission.session_id, { id = id, role = "assistant", content = info.text, ok = false,
      trace = { { kind = "run", ok = false, code = info.code, error = info.detail } } })
    recorded = { id = id }
  end
  if not announced and type(ctx.emit) == "function" then
    pcall(ctx.emit, { type = "failure", code = info.code, retryable = false, error = info.detail,
      session_id = mission.session_id, text = info.text })
  end
  return info, recorded
end

-- One wake for the operator: a notice that this gate stopped moving, with the checks that did it.
-- `done_gates.wake_id` makes it once per gate, not once per refusal - a stalled loop that wakes on
-- every turn would be the loop it was meant to name.
function M.wake_operator(mission, info, ctx)
  if mission.wake_id and mission.wake_id ~= "" then return mission.wake_id, "already_woken" end
  local seconds = 60
  local raw = tonumber(host.getenv("WASM_AGENT_DONE_GATE_WAKE_SECONDS") or "")
  if raw ~= nil then
    if raw <= 0 then return nil, "wake_disabled" end
    seconds = raw
  end
  local ok, answer = pcall(function()
    return dep("selfloop").schedule({
      session_id = mission.session_id,
      owner = mission.owner,
      reason = "done gate stalled",
      prompt = "[done gate stalled] " .. tostring(info.text) .. "\n\nThis is an automated notice, not a new "
        .. "request. The recorded acceptance checks for the operator's request stopped moving: the same "
        .. "check output repeated with no change in the world. Read the gate (done_criteria "
        .. "{action=\"status\"}) and the session, then either finish it, change the approach, or tell the "
        .. "operator plainly what is blocking it and what you need from them.",
      in_seconds = seconds,
    }, { session_id = mission.session_id, user_id = mission.owner })
  end)
  if not ok or type(answer) ~= "table" or not answer.ok then return nil, "wake_failed: " .. tostring(answer) end
  local id = answer.wake and answer.wake.id or "scheduled"
  if mission.id and mission.id ~= "" then M.set_wake(mission.id, id) end
  return id, nil
end

-- The turn-end gate. Returns the message to re-enter the run with, or nil to let the turn end, plus an
-- outcome table the caller records in telemetry.
--
-- ctx:  called_tools  did this run call any tool at all (a pure answer to a question stays pure)
--       cwd           where a command check runs (the session's workdir)
--       changes       a digest of the run's changed files, for the stall detector
--       evidence      the text a fresh verifier judges written criteria against
--       verify        the one-shot model call (prompt) -> answer text
--       emit          the run's event stream
--       message_id    the candidate answer's id
function M.turn_end(state, ctx)
  ctx = ctx or {}
  if state.disabled then return nil, { action = "disabled" } end
  local outcome = { action = "none" }
  if not state.called_tools then
    -- A turn that called no tool cannot have changed anything; there is nothing to test and nothing to
    -- demand. This is also what keeps a plain question from ever meeting the gate.
    outcome.action = "no_tools"
    return nil, outcome
  end
  local gate = M.gate_for(state.session_id, state.request)
  if gate and gate.status ~= "open" then
    -- This request already has a verdict (passed, impossible, exempt, stalled). Re-entering on a closed
    -- gate would turn a settled mission into an endless one, so it is answered and left alone.
    outcome.action = "closed"
    outcome.gate_id = gate.id
    outcome.status = gate.status
    outcome.close_code = gate.close_code
    return nil, outcome
  end
  if not gate and state.harness_turn then gate = M.open_gate(state.session_id) end
  if not gate then
    -- A request that changed state with nothing recorded to test it against: recorded, not re-entered.
    -- An explanation that only read (a read-only tool, `git status`, `rg`) changed nothing, and
    -- requirement 4 says it is never gated at all.
    if state.work_shaped and not state.harness_turn and state.effected then
      local gate_id = M.record_uncaptured(state, ctx)
      outcome.action = "uncaptured"
      outcome.gate_id = gate_id
    end
    return nil, outcome
  end
  local evaluation = M.evaluate(gate, { cwd = ctx.cwd or M.session_cwd(state.session_id),
    verify = ctx.verify, evidence = ctx.evidence })
  outcome.gate_id = gate.id
  outcome.total = evaluation.total
  outcome.failing = #evaluation.failing
  outcome.unjudged = evaluation.unjudged
  if evaluation.ok then
    M.close(gate.id, "passed", "checks_passed", string.format("%d check(s) passed", evaluation.total))
    outcome.action = "passed"
    if type(ctx.emit) == "function" then
      pcall(ctx.emit, { type = "status", text = string.format("done gate: %d acceptance check(s) passed", evaluation.total) })
    end
    return nil, outcome
  end
  -- A criterion nobody could judge is not a failure to re-enter on: the harness says so and lets the
  -- turn end, because looping on "the verifier is unavailable" would be a budget in disguise.
  if #evaluation.failing == evaluation.unjudged and evaluation.unjudged > 0 then
    outcome.action = "unjudged"
    if type(ctx.emit) == "function" then
      local reason = evaluation.failing[1] and tostring(evaluation.failing[1].reason or "") or ""
      pcall(ctx.emit, { type = "status", text = "done gate: written criteria could not be judged ("
        .. reason:sub(1, 240) .. "); the gate stays open" })
    end
    return nil, outcome
  end
  -- Stall: the same failing bytes, and the same state, `stall_limit` turn ends in a row. A fix that
  -- changes the output resets it; a retry that changes nothing does not.
  if state.fingerprint == evaluation.fingerprint and state.state_digest == tostring(ctx.changes or "") then
    state.repeats = state.repeats + 1
  else
    state.repeats = 1
  end
  state.fingerprint = evaluation.fingerprint
  state.state_digest = tostring(ctx.changes or "")
  if state.repeats >= state.stall_limit then
    local info = M.stall_record(gate, evaluation, { repeats = state.repeats, emit = ctx.emit,
      message_id = ctx.message_id })
    local wake_id, wake_error = M.wake_operator(gate, info, ctx)
    M.close(gate.id, "stalled", "no_progress", info.detail)
    outcome.action = "stalled"
    outcome.repeats = state.repeats
    outcome.wake_id = wake_id
    outcome.wake_error = wake_error
    outcome.record_id = info and info.code
    if type(ctx.emit) == "function" then
      pcall(ctx.emit, { type = "status", text = string.format(
        "done gate: stalled - the same check output %d times with no change; recorded and the operator notified",
        state.repeats) })
    end
    return nil, outcome
  end
  state.reentries = state.reentries + 1
  outcome.action = "reenter"
  outcome.repeats = state.repeats
  outcome.failing_ids = {}
  for _, result in ipairs(evaluation.failing) do outcome.failing_ids[#outcome.failing_ids + 1] = result.id end
  return M.reentry_message(gate, evaluation), outcome
end

-- ---- the tool ----------------------------------------------------------------------------------

local function require_gate(session_id)
  local gate = M.open_gate(session_id)
  if not gate then return nil, { error = "done_gate_missing", effect = "none",
    detail = "capture the operator's request and its acceptance checks first: done_criteria {action=\"capture\", checks=[...]}" } end
  return gate
end

-- `done_criteria`: capture the operator's request and its acceptance checks, add a check, close the
-- gate on a measured impossibility, or read it. Removal and weakening require the operator's words,
-- quoted, and the quote is checked against the transcript - not against what the model says they said.
function M.tool(args, ctx)
  M.setup()
  args = args or {}
  ctx = ctx or {}
  local session_id = tostring(ctx.session_id or args.session_id or "")
  if session_id == "" then return { error = "session_required", effect = "none" } end
  local action = tostring(args.action or "status")
  if action == "status" then
    local gate = M.open_gate(session_id)
    local latest = query("SELECT * FROM done_gates WHERE session_id=? ORDER BY created_at DESC LIMIT 5", { session_id })
    if not gate then
      return { ok = true, open = false, recent = latest, effect = "none",
        note = "no open gate in this session; a 'do X' request gets one with action=capture" }
    end
    local checks = M.checks(gate.id)
    return { ok = true, open = true, gate = gate, checks = checks,
      removed = M.removed_checks(gate.id), recent = latest }
  end
  if action == "capture" then
    local request, seq
    if type(args.request) == "string" and M.normalize(args.request) ~= "" then
      local said = M.operator_said(session_id, args.request)
      if not said then
        return { error = "done_gate_request_not_in_transcript", effect = "none",
          detail = "`request` must be the operator's words, verbatim; it does not appear in a user turn of this session" }
      end
      request, seq = said.content, tonumber(said.seq)
    else
      request, seq = M.latest_user_text(session_id)
      if not request then return { error = "done_gate_request_missing", effect = "none" } end
    end
    local existing = M.gate_for(session_id, request)
    if existing then
      return { ok = true, gate_id = existing.id, existing = true, status = existing.status,
        checks = M.checks(existing.id),
        note = "this request already has a gate; add checks with action=add" }
    end
    local specs = {}
    for _, raw in ipairs(type(args.checks) == "table" and args.checks or {}) do
      local spec, refusal = M.check_spec(raw)
      if not spec then return { error = refusal, effect = "none" } end
      specs[#specs + 1] = spec
    end
    if #specs == 0 then
      return { error = "done_gate_checks_required", effect = "none",
        detail = "capture needs at least one check: a command the harness can run, or a criterion a verifier can judge" }
    end
    if #specs > M.CHECK_LIMIT then return { error = "done_gate_too_many_checks", limit = M.CHECK_LIMIT, effect = "none" } end
    local id = host.uuid()
    local now = now_seconds()
    exec([[INSERT INTO done_gates(id,session_id,owner,request,request_seq,status,created_at,updated_at)
      VALUES(?,?,?,?,?,'open',?,?)]],
      { id, session_id, tostring(ctx.user_id or ""), request:sub(1, 20000), seq or null(), now, now })
    local added = {}
    for _, spec in ipairs(specs) do
      added[#added + 1] = { id = M.add(id, session_id, spec, "model"), kind = spec.kind,
        label = spec.kind == "command" and spec.command or spec.text }
    end
    return { ok = true, gate_id = id, checks = added, request = request:sub(1, 500) }
  end
  if action == "add" then
    local gate, refusal = require_gate(session_id)
    if not gate then return refusal end
    local specs = {}
    for _, raw in ipairs(type(args.checks) == "table" and args.checks or {}) do
      local spec, why = M.check_spec(raw)
      if not spec then return { error = why, effect = "none" } end
      specs[#specs + 1] = spec
    end
    if #specs == 0 then return { error = "done_gate_checks_required", effect = "none" } end
    if #M.checks(gate.id) + #specs > M.CHECK_LIMIT then
      return { error = "done_gate_too_many_checks", limit = M.CHECK_LIMIT, effect = "none" }
    end
    local added = {}
    for _, spec in ipairs(specs) do
      added[#added + 1] = { id = M.add(gate.id, session_id, spec, "model"), kind = spec.kind,
        label = spec.kind == "command" and spec.command or spec.text }
    end
    return { ok = true, gate_id = gate.id, checks = added }
  end
  if action == "remove" or action == "weaken" then
    local gate, refusal = require_gate(session_id)
    if not gate then return refusal end
    local quote = type(args.operator_quote) == "string" and args.operator_quote or ""
    local said = M.operator_said(session_id, quote)
    if not said then
      return { error = "done_check_removal_requires_operator_words", effect = "none",
        detail = "removing or weakening a recorded check needs the operator's own instruction, quoted verbatim in operator_quote; "
          .. "the quote was not found in a user turn of this session. Add a check instead, or report the check as failing." }
    end
    local targets = {}
    if type(args.id) == "string" and args.id ~= "" then targets[1] = args.id
    elseif type(args.id) == "string" and args.id == "" then return { error = "done_check_id_required", effect = "none" } end
    if #targets == 0 then
      for _, row in ipairs(M.checks(gate.id)) do targets[#targets + 1] = row.id end
    end
    local done = {}
    for _, id in ipairs(targets) do
      local rows = query("SELECT * FROM done_checks WHERE id=? AND gate_id=? AND removed_at IS NULL", { id, gate.id })
      local row = rows[1]
      if not row then
        return { error = "done_check_not_found", id = id, effect = "none" }
      end
      if action == "weaken" then
        local spec, why = M.check_spec({ command = args.command, text = args.text, expect = args.expect,
          expect_exit = args.expect_exit, why = args.why })
        if not spec then return { error = why, effect = "none" } end
        exec([[UPDATE done_checks SET kind=?,command=?,text=?,expect=?,expect_exit=?,timeout_seconds=?,why=?,
          operator_quote=?,weakened_from=? WHERE id=?]],
          { spec.kind, spec.command, spec.text, spec.expect, spec.expect_exit or null(), spec.timeout_seconds or null(),
            spec.why ~= "" and spec.why or row.why, quote, json.encode({ command = row.command, text = row.text,
              expect = row.expect, expect_exit = row.expect_exit }), id })
        done[#done + 1] = { id = id, weakened = true }
      else
        exec("UPDATE done_checks SET removed_at=?,removed_by='operator',operator_quote=? WHERE id=?",
          { now_seconds(), quote, id })
        done[#done + 1] = { id = id, removed = true }
      end
    end
    exec("UPDATE done_gates SET updated_at=? WHERE id=?", { now_seconds(), gate.id })
    return { ok = true, gate_id = gate.id, operator_seq = tonumber(said.seq), done = done }
  end
  if action == "exempt" then
    local why = type(args.why) == "string" and M.normalize(args.why) or ""
    if why == "" then return { error = "done_gate_exempt_why_required", effect = "none" } end
    local gate = M.open_gate(session_id)
    if not gate then
      -- No gate yet: the exemption still has to be a record, or the capture demand would ask again on
      -- the next turn end and the honest answer "this needs no change in the world" could never be given.
      local request = M.latest_user_text(session_id)
      if not request then return { error = "done_gate_request_missing", effect = "none" } end
      local id = host.uuid()
      local now = now_seconds()
      exec([[INSERT INTO done_gates(id,session_id,owner,request,status,close_code,close_detail,created_at,updated_at,closed_at)
        VALUES(?,?,?,?,'exempt','model_exemption',?,?,?,?)]],
        { id, session_id, tostring(ctx.user_id or ""), request:sub(1, 20000), why:sub(1, 4000), now, now, now })
      return { ok = true, gate_id = id, exempt = true, why = why, status = "exempt" }
    end
    if #M.checks(gate.id) > 0 then
      return { error = "done_gate_checks_exist", effect = "none",
        detail = "this gate has live checks; a recorded check can only be removed with the operator's words" }
    end
    M.close(gate.id, "exempt", "model_exemption", why)
    return { ok = true, gate_id = gate.id, exempt = true, why = why }
  end
  if action == "impossible" then
    local gate, refusal = require_gate(session_id)
    if not gate then return refusal end
    local reason = type(args.reason) == "string" and M.normalize(args.reason) or ""
    if reason == "" then return { error = "done_gate_impossibility_reason_required", effect = "none" } end
    local probes = {}
    local raw = args.probes or args.probe
    if type(raw) == "table" and raw.command == nil and raw.text == nil then
      for _, item in ipairs(raw) do probes[#probes + 1] = item end
    elseif type(raw) == "table" then
      probes[1] = raw
    end
    -- Two ways to be measured: a probe the harness reruns and sees meet its own expectation, or an
    -- operator instruction quoted from the transcript ("stop, that is enough").
    local quote = type(args.operator_quote) == "string" and args.operator_quote or ""
    local said = quote ~= "" and M.operator_said(session_id, quote) or nil
    if #probes == 0 and not said then
      return { error = "done_gate_impossibility_not_measured", effect = "none",
        detail = "name the blocker with probes the harness can rerun (probe={command=..., expect_exit=..., expect=...}), "
          .. "or quote the operator's instruction to stop from this session's transcript" }
    end
    local evidence, failed = {}, {}
    for _, item in ipairs(probes) do
      local spec, why = M.check_spec(item)
      if not spec or spec.kind ~= "command" then
        return { error = why or "done_gate_probe_must_be_a_command", effect = "none" }
      end
      local outcome = M.run_command(spec, ctx.cwd or M.session_cwd(session_id), args.timeout_seconds)
      local line = string.format("`%s` -> exit %s (expected %s)", spec.command, tostring(outcome.code),
        tostring(outcome.expected_exit))
      evidence[#evidence + 1] = line .. (outcome.output ~= "" and ("\n  " .. outcome.output:gsub("\n", "\n  ")) or "")
      if not outcome.passed then failed[#failed + 1] = line end
    end
    if #failed > 0 then
      return { error = "impossibility_not_measured", effect = "none",
        detail = "a probe did not show what was claimed: " .. table.concat(failed, "; ") }
    end
    local detail = reason
    if #evidence > 0 then detail = detail .. " | probes: " .. table.concat(evidence, " | ") end
    if said then detail = detail .. " | operator: " .. quote end
    M.close(gate.id, "impossible", said and "operator_stopped" or "probe_measured", detail)
    return { ok = true, gate_id = gate.id, status = "impossible", reason = reason,
      measured = #evidence, operator_seq = said and tonumber(said.seq) or nil }
  end
  return { error = "done_gate_unknown_action", action = action, effect = "none" }
end

return M
