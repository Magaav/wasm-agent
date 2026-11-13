-- Harness evaluator, the landing reviewer: one FRESH session reviews one branch before it lands.
--
-- Why a fresh session. A session that wrote a branch cannot review it: it remembers what it meant, it
-- has its own notes, and it reads its own diff the way it wrote it. So this engine starts a session
-- that shares nothing with the caller - its own home, its own ledger, no memory, no notes, no history -
-- and gives it the branch, the base and the brief. The child is the same `wa chat` an operator runs; the
-- isolation is the replay's (`harness_evaluator_replay.lua`: a `mktemp -d` scratch root with a marker,
-- `env -i` with an allowlist, the `PreToolUse` sink that refuses every effect and connector tool, the
-- PATH guards that refuse a remote git command), reused rather than copied.
--
-- What it is NOT: a gate. It prints findings and it never blocks a landing; nothing in the landing queue
-- reads it. The operator marks each finding accepted or rejected afterwards and records the misses found
-- after landing, and `wa eval report` shows the totals - evidence about the reviewer, not a verdict
-- about the branch.
--
-- The instruction text is fixed, byte for byte (M.INSTRUCTION), because it is the thing being measured:
-- changing it changes every number in the store. `scripts/test-harness-evaluator-reviewer.lua` holds its
-- own copy of the text and refuses if the two ever differ.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local core = dofile("lua/core/harness_evaluator.lua")
local replay = dofile("lua/core/harness_evaluator_replay.lua")

local M = {}
local exec = core.exec
local shquote = core.shquote

M.SCHEMA = "harness-evaluator/review/1"
M.MARKER = ".wasm-agent-eval-scratch"

-- The reviewer's instruction. Exactly this text, one line, no bytes added: a test asserts it.
M.INSTRUCTION = [==[You review one branch before it lands on main. You did not write it and you have no notes from the session that did. Read the brief, the diff against main, and every file the diff touches in full. Look for: wrong behavior, a test that passes without proving its claim, a guard or refusal that can be bypassed, a change the brief did not ask for, and user- or model-visible text that changed without being listed. For each finding give file:line, what goes wrong, and the smallest input that shows it. Do not fix anything and do not comment on style. If nothing changes behavior, say so in one line. End with: REVIEW <branch> <sha> findings=<n>]==]

-- The model is pinned: the benchmark of a reviewer is only comparable if every review is one model, and
-- the operator's brief for this reviewer says deepseek-v4.1-flash only. There is no `--model`/`--provider`
-- on the door for that reason (found as a gap by the first real review of this branch, 13/11).
M.DEFAULT_PROVIDER = "opencode-go"
M.DEFAULT_MODEL = "deepseek-v4.1-flash"
-- The model route is the one thing a review cannot invent, and it is all that travels: the vault's URL
-- (the route `lua/core/vault.lua` brokers) and its directory. Deliberately NOT
-- `WASM_AGENT_VAULT_KEYSTORE`/`WASM_AGENT_VAULT_PASSPHRASE`: those are what `rust/wa-keystore` unseals the
-- operator's sealed store with, the route does not need them, and the review child's `bash` is not one of
-- the hooked tools - so passing them would put the unseal credentials in a session that can print them
-- (found by the first real review of this branch, 13/11).
M.MODEL_ROUTE_ENV = { "WASM_AGENT_VAULT_URL", "WASM_AGENT_VAULT_DIR" }

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ---------------------------------------------------------------- the one switch
-- `reviewer = off` in the node's config file (`<config>/env`, the one file the host reads) or the same
-- word in the environment (`WA_REVIEWER=off`, or `reviewer=off` for a host whose loader put the config
-- line there). Any spelling that says off turns it off; a value nobody recognises leaves it ON and says
-- which value it saw, because a typo must not quietly disable a review the operator asked for.
local OFF_WORDS = { off = true, ["0"] = true, ["false"] = true, no = true }

local function config_switch(config_text)
  for line in tostring(config_text or ""):gmatch("[^\n]+") do
    local key, value = line:match("^%s*([%w_.-]+)%s*=%s*(.-)%s*$")
    if key and key:lower() == "reviewer" then return trim(value) end
  end
  return nil
end

function M.switch()
  local seen = {}
  local from_env = trim(host.getenv("WA_REVIEWER"))
  if from_env ~= "" then seen[#seen + 1] = { source = "environment WA_REVIEWER", value = from_env } end
  local from_loader = trim(host.getenv("reviewer"))
  if from_loader ~= "" then seen[#seen + 1] = { source = "environment reviewer", value = from_loader } end
  local from_config = config_switch(host.read_file(paths.config_file()))
  if from_config and from_config ~= "" then
    seen[#seen + 1] = { source = "config " .. paths.config_file(), value = from_config }
  end
  for _, entry in ipairs(seen) do
    if OFF_WORDS[entry.value:lower()] then
      return { on = false, source = entry.source, value = entry.value }
    end
  end
  return { on = true, source = seen[1] and seen[1].source or "default (no switch set)", value = seen[1] and seen[1].value }
end

-- ---------------------------------------------------------------- the store
function M.reviews_dir() return core.state_dir() .. "/reviews" end
function M.misses_path() return M.reviews_dir() .. "/misses.json" end
function M.review_dir(id) return M.reviews_dir() .. "/" .. core.safe_id(id) end
function M.review_path(id) return M.review_dir(id) .. "/review.json" end

function M.ids()
  local ids = {}
  for _, entry in ipairs(core.entries(M.reviews_dir())) do
    if entry.kind == "dir" and host.read_file(M.reviews_dir() .. "/" .. entry.name .. "/review.json") then
      ids[#ids + 1] = entry.name
    end
  end
  table.sort(ids)
  return ids
end

function M.record(id)
  if not id or id == "" then return nil end
  return core.read_json(M.review_path(id))
end

function M.records()
  local out = {}
  for _, id in ipairs(M.ids()) do
    local record = M.record(id)
    if record then out[#out + 1] = record end
  end
  return out
end

local function save(record)
  host.write_file(M.reviews_dir() .. "/.keep", "")
  return core.write_json(M.review_path(record.id), record)
end

function M.misses()
  local stored = core.read_json(M.misses_path())
  if type(stored) ~= "table" or type(stored.misses) ~= "table" then return {} end
  return stored.misses
end

local function save_misses(list)
  host.write_file(M.reviews_dir() .. "/.keep", "")
  return core.write_json(M.misses_path(), { version = 1, misses = list })
end

-- ---------------------------------------------------------------- git facts
local function git(repo, args)
  local ran = exec("git " .. args, repo or "", 120)
  return ran.status == 0, trim(ran.stdout), trim(ran.stderr)
end

local function commit_of(repo, ref)
  if not ref or ref == "" then return nil end
  local ok, out = git(repo, "rev-parse --verify " .. shquote(ref .. "^{commit}"))
  if not ok then return nil end
  local sha = out:gsub("%s+", "")
  if #sha < 7 then return nil end
  return sha
end
M.commit_of = commit_of

local function repo_root(cwd)
  local ran = exec("git rev-parse --show-toplevel", cwd or "", 60)
  if ran.status ~= 0 then return nil end
  local path = trim(ran.stdout)
  if path == "" then return nil end
  return path:gsub("\\", "/")
end

-- `main` as the reviewer's text says, and what this checkout actually has: a clone of this repository
-- has `origin/main`; a branch checked out without a remote has a local `main`. The base the diff is taken
-- against is the one that resolved, and the record names it, so no review is read as "against main" when
-- it was against something else.
local function resolve_base(repo, wanted)
  local candidates = wanted and { wanted } or { "origin/main", "main", "oc/main" }
  for _, ref in ipairs(candidates) do
    local sha = commit_of(repo, ref)
    if sha then return ref, sha end
  end
  return nil
end

local function binary_path(opts)
  if opts.bin and opts.bin ~= "" then return opts.bin end
  local ok, raw = pcall(host.runtime_info)
  local info = type(raw) == "string" and json.decode(raw) or raw
  local path = type(info) == "table" and info.binary_path or nil
  if type(path) == "string" and path ~= "" then return path end
  return nil
end

-- ---------------------------------------------------------------- what the child is given
-- The instruction first, byte for byte, then the input the operator named: the branch and its sha, the
-- base, the brief, and where the checkout is. Nothing else - a reviewer that is told what to expect is
-- not reviewing the branch.
--
-- The diff is against the MERGE BASE of the base and the tip, which is what "the diff against main" means
-- for a branch cut before today's main: both of this branch's first reviews spent their opening on a
-- `git diff <base>..HEAD` that showed other people's landed work as reversions, because the branch did not
-- contain the base. The prompt names both commits so nothing is read as one when it is the other.
function M.prompt(record, brief_text)
  local lines = {
    M.INSTRUCTION,
    "",
    "---",
    "Branch: " .. tostring(record.branch),
    "Sha: " .. tostring(record.sha),
    "Base: " .. tostring(record.base_ref) .. " (" .. tostring(record.base_sha) .. ")",
    "Merge base: " .. tostring(record.diff_base) .. " - the diff against it is the branch's own change",
  }
  if record.diff_path and record.diff_path ~= "" then
    lines[#lines + 1] = "Diff: " .. tostring(record.diff_path) .. " (git diff " .. tostring(record.diff_base)
      .. ".." .. tostring(record.sha) .. ", " .. tostring(record.diff_bytes or 0) .. " bytes)"
  end
  lines[#lines + 1] = "Checkout: " .. tostring(record.checkout)
    .. " - an export of the branch tip (files only; there is no git history in it)"
  if brief_text and brief_text ~= "" then
    lines[#lines + 1] = "Brief (" .. tostring(record.brief.path) .. "):"
    lines[#lines + 1] = "--- begin brief ---"
    lines[#lines + 1] = brief_text:gsub("%s+$", "")
    lines[#lines + 1] = "--- end brief ---"
  else
    lines[#lines + 1] = "Brief: none was given for this branch. Review the diff and the files it touches " ..
      "against what the change says it does."
  end
  lines[#lines + 1] = "---"
  lines[#lines + 1] = "End your review with exactly one line: REVIEW " .. tostring(record.branch) .. " "
    .. tostring(record.sha) .. " findings=<n>"
  return table.concat(lines, "\n") .. "\n"
end

local function child_env(scratch, opts, bindir)
  local home = scratch .. "/home"
  local pairs_ = {
    { "PATH", bindir .. ":/usr/local/bin:/usr/bin:/bin" },
    { "HOME", home },
    { "TMPDIR", scratch .. "/tmp" },
    { "WASM_AGENT_HOME", home },
    { "WASM_AGENT_DB", home .. "/.wasm-agent/memory.db" },
    { "WASM_AGENT_MANAGED", "0" },
    { "WASM_AGENT_RENDEZVOUS", "" },
    { "WASM_AGENT_RELAY", "" },
    { "WA_GRAPH_WATCH", "0" },
    -- Code mode is ON, as in a replay: since the nested-dispatch fix (825ce08f, docs/HOOKS.md "nested
    -- dispatch is a hook boundary") a tool call inside a script crosses the same sink this run installs,
    -- so leaving code mode on cannot perform an effect the record would not see. Forcing it off measured
    -- the direct tool loop only, which is not how the node is worked.
    { "WASM_AGENT_CODEMODE", "native" },
    { "WA_EVAL_SINK_DIR", scratch .. "/sink" },
    { "WA_EVAL_DECISIONS", scratch .. "/decisions" },
    { "WASM_AGENT_PROVIDER", M.DEFAULT_PROVIDER },
    { "WASM_AGENT_LLM_MODEL", M.DEFAULT_MODEL },
  }
  for _, name in ipairs(M.MODEL_ROUTE_ENV) do
    local value = host.getenv(name)
    if value and value ~= "" then pairs_[#pairs_ + 1] = { name, value } end
  end
  local parts = {}
  for _, pair in ipairs(pairs_) do parts[#parts + 1] = pair[1] .. "=" .. shquote(pair[2]) end
  return table.concat(parts, " ")
end

-- The last `REVIEW <branch> <sha> findings=<n>` line in a text: the instruction says to END with it, and
-- a reviewer that says it twice is read by the last word, not the first.
function M.review_line(text)
  local found
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local branch, sha, count = line:match("^REVIEW%s+(%S+)%s+(%S+)%s+findings=(%d+)%s*$")
    if branch then
      found = { line = trim(line), branch = branch, sha = sha, findings = tonumber(count) }
    end
  end
  return found
end

-- The child's answer: its last assistant row when its ledger could be read, the captured stdout when it
-- could not (a candidate binary that keeps no ledger still answers on stdout). Never a guess from a
-- summary line.
local function answer_of(dump, stdout)
  local text
  for _, row in ipairs((dump or {}).messages or {}) do
    if row.role == "assistant" then
      local content = tostring(row.content or "")
      if trim(content) ~= "" then text = content end
    end
  end
  if text then return text end
  local out = tostring(stdout or "")
  if trim(out) ~= "" then return out end
  return nil
end

local function review_id_for(branch, existing)
  local base = core.safe_id(branch)
  if base == "" then base = "branch" end
  for index = 1, 999 do
    local candidate = string.format("%s-%03d", base, index)
    if not existing[candidate] then return candidate end
  end
  return base .. "-" .. tostring(math.floor(host.now()))
end

-- ---------------------------------------------------------------- the run
-- `wa eval reviewer <branch> [--brief <file>] [--base <ref>] [--bin <wa>] [--model <name>] ...`
-- Returns the stored review record, or nil and the reason it could not review.
function M.run(opts)
  opts = opts or {}
  local branch = opts.branch and tostring(opts.branch) or ""
  if branch == "" then return nil, "a review needs a branch" end

  local repo = opts.repo and opts.repo ~= "" and opts.repo or repo_root(opts.cwd)
  if not repo then return nil, "not inside a git repository, so there is no branch to review" end
  local sha = commit_of(repo, branch)
  if not sha then return nil, "no such branch or commit in " .. repo .. ": " .. branch end
  local base_ref, base_sha = resolve_base(repo, opts.base)
  if not base_ref then
    return nil, "no base to diff against (tried " .. tostring(opts.base or "origin/main, main, oc/main") .. ")"
  end

  local bin = binary_path(opts)
  if not bin then return nil, "no binary to run the review with (pass --bin <path>)" end
  if not bin:match("^[/\\]") and not bin:match("^%a:[/\\]") then
    return nil, "--bin must be an absolute path (a bare name would resolve against the review's own PATH)"
  end

  local brief_text, brief_path
  if opts.brief and opts.brief ~= "" then
    brief_path = tostring(opts.brief)
    brief_text = host.read_file(brief_path)
    if brief_text == nil then return nil, "the brief cannot be read: " .. brief_path end
  end

  local home = paths.home()
  local scratch, scratch_error = replay.make_scratch("review-" .. core.safe_id(branch):sub(1, 20))
  if not scratch then return nil, scratch_error end
  if replay.inside(scratch, home) then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, "refusing a scratch directory inside this node's home: " .. scratch
  end
  replay.write_text(scratch .. "/" .. M.MARKER, "harness-evaluator review\n")

  local existing = {}
  for _, id in ipairs(M.ids()) do existing[id] = true end
  local record = {
    schema = M.SCHEMA,
    id = review_id_for(branch, existing),
    branch = branch,
    sha = sha,
    base_ref = base_ref,
    base_sha = base_sha,
    diff_base = base_sha,
    repo = repo,
    bin = bin,
    provider = M.DEFAULT_PROVIDER,
    model = M.DEFAULT_MODEL,
    checkout = scratch .. "/ws",
    brief = { path = brief_path, bytes = brief_text and #brief_text or 0 },
    started_at = host.now(),
    isolation = {
      scratch = scratch,
      marker = M.MARKER,
      operator_home = home,
      scratch_inside_operator_home = false,
      session = "fresh: its own home and its own ledger - no memory, no notes, no history of the session that wrote the branch",
      environment = "env -i with an allowlist (HOME, ledger, PATH, sink, the model route); no node env, no rendezvous, no relay",
      effects = "blocked by the review sink and the PATH guards; a review records what it would have done and does nothing. `bash` is not hooked (a review needs it to run `git diff`), so only its remote verbs are shimmed",
      code_mode = "on, as in a replay: every nested dispatch crosses the same sink, so a script cannot perform an unrecorded effect",
      checkout = "an export of the branch tip (git archive): no git directory, no alternates, no remote - nothing in it points at the operator's tree",
    },
    files_touched = {},
    marks = {},
  }

  -- The checkout is an EXPORT of the branch tip, not a clone: a `--shared` clone carries
  -- `.git/objects/info/alternates` and `remote.origin.url` pointing at the operator's tree, and `bash` is
  -- not a hooked tool, so one bash call could edit the operator's checkout with nothing in the record
  -- saying so (the second real review of this branch, 13/11, finding 4). An export has no git directory at
  -- all, and the diff is written here, by the parent, from the repository it already has.
  local ws = record.checkout
  exec("mkdir -p " .. shquote(ws), "", 120)
  local merge_base = trim(git(repo, "merge-base " .. shquote(base_sha) .. " " .. shquote(sha)) or "")
  if merge_base ~= "" and #merge_base >= 7 then
    record.diff_base = merge_base
  end
  local exported = exec("git -C " .. shquote(repo) .. " archive --format=tar " .. shquote(sha)
    .. " | tar -x -C " .. shquote(ws), "", 600)
  if exported.status ~= 0 then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, "the branch tip " .. sha .. " could not be exported for the review: " .. trim(exported.stderr)
  end
  replay.write_text(scratch .. "/TARGET",
    "branch " .. branch .. "\nsha " .. sha .. "\nbase " .. base_ref .. " " .. base_sha .. "\nmerge_base "
      .. tostring(record.diff_base) .. "\n")
  local diff_path = scratch .. "/diff.patch"
  local diff = exec("git -C " .. shquote(repo) .. " diff " .. shquote(tostring(record.diff_base))
    .. " " .. shquote(sha), "", 600)
  if diff.status ~= 0 then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, "the branch's diff could not be read: " .. trim(diff.stderr)
  end
  local diff_text = tostring(diff.stdout or "")
  replay.write_text(diff_path, diff_text)
  record.diff_path = diff_path
  record.diff_bytes = #diff_text
  local ok_diff, names = git(repo, "diff --name-only " .. shquote(tostring(record.diff_base)) .. " " .. shquote(sha))
  if ok_diff then
    for name in names:gmatch("[^\n]+") do record.files_touched[#record.files_touched + 1] = name end
  end
  -- A manifest of the export, so "the review changed nothing in it" is a comparison of content rather
  -- than `git status` in a directory that (rightly) has no git.
  local manifest = exec("cd " .. shquote(ws) .. " && find . -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum", "", 300)
  record.checkout_manifest = tostring(manifest.stdout or "")

  exec("mkdir -p " .. shquote(scratch .. "/sink") .. " " .. shquote(scratch .. "/decisions")
    .. " " .. shquote(scratch .. "/home") .. " " .. shquote(scratch .. "/tmp"), "", 120)
  local sink_path, sink_error = replay.install_sink(scratch, {
    label = "review",
    reason = "review: a review reads and changes nothing; this call was refused and nothing was executed",
  })
  if not sink_path then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, sink_error or "the review sink could not be written"
  end
  local hooks_path, hooks_error = replay.install_hooks(scratch, sink_path)
  if not hooks_path then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, hooks_error or "the review hook file could not be written"
  end
  record.hooks = hooks_path
  local bindir, guard_error = replay.install_guards(scratch, record, "review")
  if not bindir then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, guard_error or "the review guards could not be written"
  end

  local prompt = M.prompt(record, brief_text)
  replay.write_text(scratch .. "/prompt.txt", prompt)
  record.prompt_bytes = #prompt

  -- The prompt travels as ONE argument with `--once`, not on stdin. Measured here (13/11): a scripted
  -- `wa chat < prompt.txt` takes stdin LINE BY LINE and runs a turn per line, so a review prompt of a
  -- dozen lines became a dozen model calls, each seeing one line - and the answer was a dozen "no
  -- provider" notes. One argument is one message, and `--once` says the process exits after it.
  if #prompt > 100000 then
    exec("rm -rf " .. shquote(scratch), "", 60)
    return nil, "the instruction, the brief and the input come to " .. #prompt
      .. " bytes; one prompt argument holds about 100000, so give a shorter brief"
  end
  local seconds = tonumber(opts.timeout) or 1800
  local command = "cd " .. shquote(ws) .. " && env -i " .. child_env(scratch, opts, bindir)
    .. " timeout " .. math.floor(seconds) .. " " .. shquote(bin) .. " chat --once " .. shquote(prompt)
    .. " < /dev/null"
  record.command = command
  local began = host.monotonic_ms()
  local ran = exec(command, ws, math.floor(seconds) + 180)
  record.wall_ms = host.monotonic_ms() - began
  record.exit_code = ran.status
  record.timed_out = ran.status == 124
  record.stdout_bytes = #tostring(ran.stdout or "")
  record.stdout_tail = tostring(ran.stdout or ""):sub(-4000)
  record.stderr_tail = tostring(ran.stderr or ""):sub(-2000)

  local dump, dump_error = replay.dump_ledger(scratch, bin, bindir)
  record.metrics = core.metrics({ messages = dump.messages, events = dump.events })
  if dump_error then record.dump_error = dump_error end
  record.ledger_sessions = #(dump.sessions or {})
  for _, row in ipairs(dump.sessions or {}) do
    if row.id then record.session_id = tostring(row.id) end
  end

  local answer = answer_of(dump, ran.stdout)
  record.answer = answer and answer:sub(1, 200000) or nil
  local line = M.review_line(answer)
  record.reviewed = line ~= nil
  if line then
    record.review_line = line.line
    record.findings = line.findings
    record.reported_branch, record.reported_sha = line.branch, line.sha
    if line.sha ~= sha or line.branch ~= branch then
      record.state = "answered_about_another_commit"
    else
      record.state = "reviewed"
    end
  else
    record.findings = nil
    record.state = "no_review"
  end
  -- What the review session itself changed, if anything: it is its own discarded export, so this is
  -- evidence that the reviewer fixed nothing, not a warning about the operator's tree.
  local after_manifest = exec("cd " .. shquote(ws) .. " && find . -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum", "", 300)
  if tostring(after_manifest.stdout or "") ~= tostring(record.checkout_manifest or "") then
    record.checkout_changed = true
    record.checkout_changed_note = "the export differs from what it was before the review"
  end
  record.checkout_manifest = nil

  -- Evidence stays in the review's own directory under the state dir; the scratch tree goes away.
  local kept = scratch
  record.kept_scratch = opts.keep_scratch and true or false
  if opts.keep_scratch then
    -- A kept scratch cannot be removed before the record is read, and its ledger is what a reader wants.
    record.acknowledged_scratch = kept
  end
  save(record)
  if not opts.keep_scratch then
    if host.read_file(scratch .. "/" .. M.MARKER) then exec("rm -rf " .. shquote(scratch), "", 120) end
  end
  if not line then
    return record, "the review session gave no REVIEW line (state " .. tostring(record.state) .. ")"
  end
  return record
end

-- ---------------------------------------------------------------- the operator's marks
-- `<id>` or `<id>#<n>`: a review's findings are numbered in the order the reviewer wrote them, 1..n.
function M.mark(id, word, finding)
  if word ~= "accepted" and word ~= "rejected" then return nil, "a finding is marked `accepted` or `rejected`" end
  local review_id, inline = tostring(id or ""):match("^(.+)#(%d+)$")
  if review_id then id, finding = review_id, finding or inline end
  local record = M.record(id)
  if not record then return nil, "no such review: " .. tostring(id) end
  local count = tonumber(record.findings) or 0
  if count == 0 then return nil, "review " .. tostring(id) .. " recorded no findings to mark" end
  record.marks = type(record.marks) == "table" and record.marks or {}
  local wanted = {}
  if finding ~= nil and tostring(finding) ~= "" then
    local index = tonumber(finding)
    if not index or index < 1 or index > count or index % 1 ~= 0 then
      return nil, "review " .. tostring(id) .. " has findings 1-" .. count .. "; " .. tostring(finding) .. " is not one"
    end
    wanted[1] = index
  else
    for index = 1, count do wanted[#wanted + 1] = index end
  end
  -- Keyed by STRING index: `marks[2]` alone is a sparse array, and `lua/vendor/json.lua` refuses one
  -- ("mixed or invalid key types"), which made marking any single finding but the first crash the door and
  -- lose the mark (the second real review of this branch, 13/11, finding 1).
  record.marks = type(record.marks) == "table" and record.marks or {}
  for _, index in ipairs(wanted) do record.marks[tostring(index)] = { state = word, at = host.now() } end
  if not save(record) then return nil, "the mark could not be written" end
  return record
end

function M.miss(branch, note, cwd)
  branch, note = trim(branch), trim(note)
  if branch == "" then return nil, "a miss needs the branch it was found on" end
  if note == "" then return nil, "a miss needs a note saying what the reviewer did not find" end
  local misses = M.misses()
  local sha
  local ok, found = pcall(commit_of, cwd or "", branch)
  if ok and found then sha = found end
  misses[#misses + 1] = { branch = branch, sha = sha, note = note, at = host.now() }
  if not save_misses(misses) then return nil, "the miss could not be written" end
  return misses[#misses]
end

-- ---------------------------------------------------------------- the totals
local function fmt_count(value)
  if type(value) ~= "number" then return "-" end
  if value >= 1000000 then return string.format("%.1fM", value / 1000000) end
  if value >= 1000 then return string.format("%.1fk", value / 1000) end
  return tostring(math.floor(value + 0.5))
end

local function fmt_ms(ms)
  if type(ms) ~= "number" then return "-" end
  if ms >= 1000 then return string.format("%.1fs", ms / 1000) end
  return string.format("%dms", math.floor(ms))
end

local function sum(records, get)
  local total, seen = nil, false
  for _, record in ipairs(records) do
    local value = get(record)
    if type(value) == "number" then total, seen = (total or 0) + value, true end
  end
  return seen and total or nil
end

-- accepted, rejected, unmarked for one review. A mark is read by its string key (`"2"`), and a record
-- written by the first version of this store (numeric keys) is read the same way, by its tostring.
function M.counts(record)
  local accepted, rejected = 0, 0
  local findings = tonumber(record.findings) or 0
  local marks = type(record.marks) == "table" and record.marks or {}
  for index = 1, findings do
    local mark = marks[tostring(index)]
    if type(mark) ~= "table" then mark = marks[index] end
    if type(mark) == "table" and mark.state == "accepted" then accepted = accepted + 1 end
    if type(mark) == "table" and mark.state == "rejected" then rejected = rejected + 1 end
  end
  return accepted, rejected, findings - accepted - rejected
end
local counts_of = M.counts

function M.totals()
  local records = M.records()
  local accepted, rejected, unmarked, findings = 0, 0, 0, 0
  for _, record in ipairs(records) do
    local a, r, u = counts_of(record)
    accepted, rejected, unmarked = accepted + a, rejected + r, unmarked + u
    findings = findings + (tonumber(record.findings) or 0)
  end
  local marked = accepted + rejected
  return {
    reviews = #records,
    findings = findings,
    accepted = accepted,
    rejected = rejected,
    unmarked = unmarked,
    accepted_rate = marked > 0 and (accepted / marked) or nil,
    misses = #M.misses(),
    reviews_without_line = (function()
      local n = 0
      for _, record in ipairs(records) do if record.state ~= "reviewed" then n = n + 1 end end
      return n
    end)(),
    tokens_in = sum(records, function(r) return (r.metrics or {}).tokens_in end),
    tokens_out = sum(records, function(r) return (r.metrics or {}).tokens_out end),
    model_calls = sum(records, function(r) return (r.metrics or {}).model_calls end),
    wall_ms = sum(records, function(r) return r.wall_ms end),
  }
end

local function pad(text, width)
  text = tostring(text or "")
  if #text >= width then return text end
  return text .. string.rep(" ", width - #text)
end

-- What `wa eval report` adds: per review a row (branch, sha, findings, marked, tokens, time) and then the
-- totals. Counts and ids only - the review's own text stays in the store, the same rule a task follows.
function M.report_lines()
  local records = M.records()
  local lines = {}
  if #records == 0 and #M.misses() == 0 then return lines end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "reviews (data only - a review never blocks a landing):"
  lines[#lines + 1] = pad("BRANCH", 28) .. pad("SHA", 10) .. pad("FINDINGS", 10) .. pad("ACCEPT", 8)
    .. pad("REJECT", 8) .. pad("IN", 8) .. pad("OUT", 8) .. pad("WALL", 8) .. "STATE"
  for _, record in ipairs(records) do
    local accepted, rejected = counts_of(record)
    local metrics = record.metrics or {}
    lines[#lines + 1] = pad(tostring(record.branch), 28) .. pad(tostring(record.sha):sub(1, 8), 10)
      .. pad(tostring(record.findings or "-"), 10) .. pad(tostring(accepted), 8) .. pad(tostring(rejected), 8)
      .. pad(fmt_count(metrics.tokens_in), 8) .. pad(fmt_count(metrics.tokens_out), 8)
      .. pad(fmt_ms(record.wall_ms), 8) .. tostring(record.state or "-")
  end
  local tm = M.totals()
  local rate = tm.accepted_rate and string.format("%.0f%%", tm.accepted_rate * 100) or "-"
  lines[#lines + 1] = string.format(
    "totals: %d review(s), findings %d, accepted %d, rejected %d, unmarked %d, accepted rate %s, misses %d",
    tm.reviews, tm.findings, tm.accepted, tm.rejected, tm.unmarked, rate, tm.misses)
  lines[#lines + 1] = string.format("cost: %s in / %s out, %s model call(s), %s wall",
    fmt_count(tm.tokens_in), fmt_count(tm.tokens_out), fmt_count(tm.model_calls), fmt_ms(tm.wall_ms))
  return lines
end

return M
