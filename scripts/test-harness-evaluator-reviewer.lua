-- harness-evaluator landing reviewer: the fixed text, the fresh session, the numbers, the one switch.
--
-- Why this row exists. "A fresh reviewer reviews the branch before it lands, and its numbers are
-- evidence - not a gate" is a claim about a process this row does not run itself. So each part is proved
-- where it can be observed:
--
--   * the instruction text is byte for byte the text the operator approved (this file holds its own
--     copy, so a drift in either place fails);
--   * a review runs a session that shares nothing with the caller: its own home and its own ledger, in a
--     `mktemp -d` scratch root outside the node home, with the model pinned and the effects refused by
--     the replay's own sink and PATH guards;
--   * the prompt the child is given starts with that text and then names the branch, its sha, the base
--     and the brief - and the child's checkout is the branch tip, so the diff it reads is the branch;
--   * the findings and the final `REVIEW <branch> <sha> findings=<n>` line come back, the run is
--     recorded with tokens and time, and the door exits 0 even when there are findings (it never blocks
--     a landing - scripts/landing-queue.mjs does not read the store);
--   * marks and misses land in the store and `wa eval report` shows the totals;
--   * one switch turns it off - `reviewer = off` in the node's config file, or `WA_REVIEWER=off` in the
--     environment - and then the door says it is off and exits 0.
--
-- What it does NOT prove, and says so: no model is called here (a fast-path row has no vault), so the
-- real-binary run records `no_review` with zero model calls. That is measured, not papered over: the
-- review's answer path is proved with a candidate binary that answers on stdout, and the fresh-session
-- path with the real binary and its own ledger.
local json = dofile('lua/vendor/json.lua')
local core = dofile('lua/core/harness_evaluator.lua')
local replay = dofile('lua/core/harness_evaluator_replay.lua')
local reviewer = dofile('lua/core/harness_evaluator_reviewer.lua')
local cli = dofile('lua/core/harness_evaluator_cli.lua')

local checks = 0
local function check(value, label)
  checks = checks + 1
  if not value then error('HARNESS EVALUATOR REVIEWER CHECK FAILED: ' .. label) end
end
local function read(path) return host.read_file(path) end
local exec = core.exec
local shquote = core.shquote

local home = host.getenv('WASM_AGENT_HOME') or ''
check(home ~= '', 'the row runs with a scratch home')
local bin = host.getenv('FAST_BIN') or ''
check(bin ~= '' and bin:sub(1, 1) == '/', 'the row has the binary under test (' .. bin .. ')')
local root = host.getenv('WASM_AGENT_LUA_ROOT') or ''

-- ---------------------------------------------------------------- 1. the text, byte for byte
-- This copy is the operator's text (13/11, approved as written). It is duplicated on purpose: a test that
-- reads the constant it checks cannot catch a change to it.
local EXPECTED = 'You review one branch before it lands on main. You did not write it and you have no notes from the session that did. Read the brief, the diff against main, and every file the diff touches in full. Look for: wrong behavior, a test that passes without proving its claim, a guard or refusal that can be bypassed, a change the brief did not ask for, and user- or model-visible text that changed without being listed. For each finding give file:line, what goes wrong, and the smallest input that shows it. Do not fix anything and do not comment on style. If nothing changes behavior, say so in one line. End with: REVIEW <branch> <sha> findings=<n>'
check(reviewer.INSTRUCTION == EXPECTED, 'the instruction text is the approved text, byte for byte ('
  .. #reviewer.INSTRUCTION .. ' bytes vs ' .. #EXPECTED .. ')')

-- ---------------------------------------------------------------- 2. the switch
-- The node's one config file is `<config>/env`; the row's config is its own scratch home's.
local config_file = host.getenv('WASM_AGENT_HOME') .. '/.wasm-agent/env'
check(reviewer.switch().on == true, 'with no switch set the reviewer is on by default')
check(host.write_file(config_file, 'WASM_AGENT_SOMETHING=1\nreviewer = off\n'), 'the config file is writable')
local off = reviewer.switch()
check(off.on == false, '`reviewer = off` in the config file turns it off')
check(tostring(off.source):find('config', 1, true) ~= nil, 'and the switch names the file it read')
check(host.write_file(config_file, 'reviewer = on\n'), 'the config file can be rewritten')
check(reviewer.switch().on == true, '`reviewer = on` leaves it on')
host.write_file(config_file, '')

-- ---------------------------------------------------------------- 3. a fixture branch to review
dofile('lua/core/memory.lua').setup()
local function exec_git(repo, args)
  local ran = exec('git -C ' .. shquote(repo) .. ' ' .. args, '', 120)
  return ran
end
local repo = home .. '/review-repo'
local made = exec('mkdir -p ' .. shquote(repo), '', 60)
check(made.status == 0, 'the fixture repository directory exists')
local function commit(repo_dir, message)
  local ran = exec_git(repo_dir, '-c user.name=fixture -c user.email=fixture@example.invalid commit -q -m '
    .. shquote(message))
  check(ran.status == 0, 'a fixture commit lands: ' .. tostring(ran.stderr))
  return (exec_git(repo_dir, 'rev-parse HEAD').stdout or ''):gsub('%s+$', '')
end
check(exec_git(repo, 'init -q -b main .').status == 0, 'the fixture repository is a git repository')
check(host.write_file(repo .. '/README.md', '# fixture\n'), 'the fixture has a base file')
exec_git(repo, 'add -A')
local base_sha = commit(repo, 'base')
check(exec_git(repo, 'checkout -q -b change/fixture').status == 0, 'the fixture branch exists')
check(host.write_file(repo .. '/feature.txt', 'the branch adds a file\n'), 'the branch changes a file')
exec_git(repo, 'add -A')
local sha = commit(repo, 'the change under review')
check(#sha >= 7 and sha ~= base_sha, 'the branch tip is its own commit')
-- main moves on AFTER the branch is cut, so the base is no longer the branching point: the diff a review
-- reads must be against the MERGE BASE, not the base ref, or it shows main's new work as the branch's
-- reversions (both of this branch's first reviews were handed exactly that).
exec_git(repo, 'checkout -q main')
check(host.write_file(repo .. '/main-only.txt', 'landed after the branch was cut\n'), 'main moves on')
exec_git(repo, 'add -A')
local main_sha = commit(repo, 'main moves on')
local brief_path = home .. '/brief.md'
local BRIEF = 'BRIEF-MARKER: add feature.txt; nothing else should change.'
check(host.write_file(brief_path, BRIEF .. '\n'), 'the brief exists')

-- ---------------------------------------------------------------- 4. a review, answered by a stub
-- A candidate binary that answers on stdout is what proves the prompt, the parse, the record and the
-- numbers without reaching a model. It keeps no ledger, so the tokens stay nil with the reason named.
local stub = home .. '/stub-wa.sh'
local STUB_ANSWER = table.concat({
  'FINDING 1 - feature.txt:1 - BYPASS-MARKER: the guard can be bypassed by an empty path.',
  'FINDING 2 - tests/test-feature.lua:12 - the test asserts nothing about the branch.',
  '',
  'REVIEW change/fixture ' .. sha .. ' findings=2',
}, '\n')
check(host.write_file(stub, '#!/bin/sh\ncat <<\'EOF\'\n' .. STUB_ANSWER .. '\nEOF\nexit 0\n'), 'the stub exists')
check(exec('chmod 755 ' .. shquote(stub), '', 60).status == 0, 'the stub is executable')

local record, why = reviewer.run({
  branch = 'change/fixture', repo = repo, brief = brief_path, bin = stub,
  timeout = 60, keep_scratch = true,
})
check(record ~= nil, 'the review runs: ' .. tostring(why))
check(record.state == 'reviewed', 'the review is recorded as reviewed (' .. tostring(record.state) .. ')')
check(record.findings == 2, 'the findings count comes from the REVIEW line, not a guess')
check(record.review_line == 'REVIEW change/fixture ' .. sha .. ' findings=2', 'the final line is kept verbatim')
check(record.sha == sha and record.branch == 'change/fixture', 'the record names the branch and its sha')
check(record.base_ref == 'main' and record.base_sha == main_sha, 'the base that resolved is the base recorded')
check(record.diff_base == base_sha, 'and the diff base is the merge base, where the branch was cut')
check(record.diff_bytes ~= nil and record.diff_bytes > 0, 'the diff was written and measured')
check((read(record.diff_path) or ''):find('main%-only', 1) == nil,
  'the diff does NOT carry work that landed on main after the branch was cut')
check(record.model == 'deepseek-v4.1-flash', 'the model is pinned to the one model in the brief')

-- The prompt: the approved text first, byte for byte, then the input the operator named.
local prompt = read(record.isolation.scratch .. '/prompt.txt') or ''
check(prompt:sub(1, #EXPECTED) == EXPECTED, 'the child is given the instruction text, byte for byte, first')
check(prompt:find('Branch: change/fixture', 1, true) ~= nil, 'the prompt names the branch')
check(prompt:find('Sha: ' .. sha, 1, true) ~= nil, 'the prompt names the sha')
check(prompt:find('Base: main (' .. main_sha .. ')', 1, true) ~= nil, 'the prompt names the base')
check(prompt:find('Merge base: ' .. base_sha, 1, true) ~= nil,
  'and names the merge base as what the diff is against, so main\'s later commits are not read as the branch\'s')
check(prompt:find(BRIEF, 1, true) ~= nil, 'the prompt carries the brief')
check(prompt:find('REVIEW change/fixture ' .. sha .. ' findings=<n>', 1, true) ~= nil,
  'the prompt says which line ends the review')

-- The session: its own home, its own ledger, in a scratch root outside this node's.
check(record.isolation.scratch ~= home and not replay.inside(record.isolation.scratch, home),
  "the review runs outside this node's home")
check(read(record.isolation.scratch .. '/.wasm-agent-eval-scratch') ~= nil, 'the scratch carries the marker')
check(record.command:find('env %-i') ~= nil, 'the child is started with env -i and an allowlist')
check(record.command:find('WASM_AGENT_HOME=.', 1) ~= nil, 'and its own home travels in that allowlist')
-- Code mode is ON, as in a replay: since the nested-dispatch fix every call inside a script crosses the
-- same sink, so it cannot perform an effect this run would not see (825ce08f, docs/HOOKS.md).
check(record.command:find('WASM_AGENT_CODEMODE=.native.', 1) ~= nil,
  'code mode is on as in a replay, and the command says so')
check(record.command:find('WASM_AGENT_LLM_MODEL=.deepseek%-v4%.1%-flash.', 1) ~= nil, 'the model is the pinned one')
check(record.command:find('timeout 60', 1, true) ~= nil, 'the review is bounded')
-- ONE argument, `--once`, and stdin closed: a prompt on a valve is read line by line, one turn per line
-- (measured 13/11 - a dozen lines became a dozen model calls), so the prompt travels as one message.
check(record.command:find('chat --once ' .. shquote(prompt), 1, true) ~= nil,
  'the whole prompt travels as ONE argument, so the session runs one turn')
check(record.command:find('< /dev/null', 1, true) ~= nil, 'and stdin is closed, so nothing else is read')
check(record.session_id == nil or record.session_id ~= '', 'a session id is never an empty string')

-- The checkout the child reads: an EXPORT of the branch tip - no git directory, no alternates, no remote,
-- so nothing in it points at the operator's tree (a `--shared` clone does; second real review, finding 4).
local target = read(record.isolation.scratch .. '/TARGET') or ''
check(target:find('sha ' .. sha, 1, true) ~= nil, 'the scratch names the branch tip it exported')
check(select(2, pcall(host.path_kind, record.checkout .. '/.git')) == 'missing',
  'the checkout has no git directory for a bash call to walk back through')
check(read(record.checkout .. '/feature.txt') ~= nil, 'the branch file is in the export')
check(read(record.checkout .. '/README.md') ~= nil, 'and the base file it did not change is too')
local diff_text = read(record.diff_path or '') or ''
check(record.diff_path ~= nil and diff_text:find('feature.txt', 1, true) ~= nil,
  'the diff the child reads is the branch' .. "'" .. 's own change, written by the engine')
-- The diff is against the MERGE BASE: a branch cut before today's main must not read other people's
-- landed work as its own reversions (both first reviews of this branch spent their opening on that).
local merge_base = (exec_git(repo, 'merge-base ' .. shquote(base_sha) .. ' ' .. shquote(sha)).stdout or ''):gsub('%s+$', '')
check(record.diff_base == merge_base, 'the diff base is the merge base of the base and the tip')
local touched = table.concat(record.files_touched or {}, ',')
check(touched:find('feature.txt', 1, true) ~= nil, 'the record names the file the diff touches')

-- Effects are refused by the same machinery a replay uses, with the review's own words.
local hooks = json.decode(read(record.isolation.scratch .. '/home/.wasm-agent/hooks.json') or '')
check(hooks ~= nil and type(hooks.hooks.PreToolUse) == 'table', 'the review installs its own PreToolUse hook')
local patterns = {}
for _, entry in ipairs(hooks.hooks.PreToolUse or {}) do patterns[#patterns + 1] = entry.matcher end
local pattern_text = table.concat(patterns, ' ')
check(pattern_text:find('^tool_call$', 1, true) ~= nil, 'the one-tool dispatch is hooked (nested effects)')
check(pattern_text:find('^whatsapp_', 1, true) ~= nil and pattern_text:find('^email_', 1, true) ~= nil,
  'connectors and mail are hooked')
local sink = read(record.isolation.scratch .. '/sink.sh') or ''
check(sink:find('review: a review reads and changes nothing', 1, true) ~= nil,
  "the sink refuses in the review's words, and nothing of the replay's")
local function guarded(command, cwd)
  return exec('env -i PATH=' .. shquote(record.isolation.scratch .. '/bin:/usr/local/bin:/usr/bin:/bin')
    .. ' WA_EVAL_SINK_DIR=' .. shquote(record.isolation.scratch .. '/sink')
    .. ' sh -c ' .. shquote(command), cwd or record.checkout, 60)
end
local pushed = guarded('git push origin main')
check(tonumber(pushed.code) == 97, 'a remote git verb is refused (exit ' .. tostring(pushed.code) .. ')')
-- `git -C <dir> push` put the directory where the subcommand should be, and the guard let it through to
-- the real git (third real review, finding 1: it executed a push with the guard first on PATH).
local by_dir = guarded('git -C /tmp push origin main')
check(tonumber(by_dir.code) == 97, 'and `git -C <dir> push` is refused too (exit ' .. tostring(by_dir.code) .. ')')
local by_config = guarded('git -c user.name=x push origin main')
check(tonumber(by_config.code) == 97, 'and `git -c <k=v> push` (exit ' .. tostring(by_config.code) .. ')')
-- `|| true` used to make this check unfailable, and the export has no `.git` to log in: the assert now
-- names the real git's own answer (fourth real review, finding 3).
local local_read = guarded('git --version')
check(tonumber(local_read.code) == 0, 'local git still works through the guard (' .. tostring(local_read.code) .. ')')
check(tostring(local_read.stdout):find('git version', 1, true) ~= nil, 'and it is the real git answering')
-- An alias reaches the remote verb inside the REAL git, after the guard's scan: refused by name
-- (fourth real review, finding 1 - it executed a push this way).
local by_alias = guarded('git -c alias.p=push p origin main')
check(tonumber(by_alias.code) == 97, 'a git alias is refused (exit ' .. tostring(by_alias.code) .. ')')
-- A local verb the guard has no business knowing still runs: an allowlist of "known" verbs refused
-- `git revert`/`git symbolic-ref` and moved a replay's counts (fifth real review, finding 1).
local local_verb = guarded('git symbolic-ref --short HEAD', repo)
check(tonumber(local_verb.code) == 0, 'a local verb runs through the guard (' .. tostring(local_verb.code) .. ')')
-- A READ is not an effect: `git remote -v` runs, and nothing is recorded as would-have-done.
-- In a real repository (the fixture), because `git remote -v` in an export with no `.git` is git's own
-- "not a repository", not this guard's answer.
local remote_read = guarded('git remote -v', repo)
check(tonumber(remote_read.code) == 0, '`git remote -v` is a read and runs (exit ' .. tostring(remote_read.code) .. ')')
check(#core.entries(record.isolation.scratch .. '/sink') > 0, 'the sink is there, so a refusal would have been recorded')
local remote_update = guarded('git remote update')
check(tonumber(remote_update.code) == 97, 'while `git remote update` is refused (' .. tostring(remote_update.code) .. ')')
check(tostring(pushed.stderr):find('review:', 1, true) ~= nil, 'and the refusal says review, not replay')

-- A stub keeps no ledger: the tokens stay nil and the record names the rule, never a zero.
check(record.metrics.tokens_in == nil, 'with no ledger read back, the tokens stay nil, not zero')
check(tostring(record.dump_error):find('ledger could not be read back', 1, true) ~= nil,
  'and the record says why the ledger could not be read')
check(type(record.wall_ms) == 'number' and record.wall_ms >= 0, 'the run records how long it took')

-- Two runs of one branch sit side by side and are numbered.
local second = reviewer.run({ branch = 'change/fixture', repo = repo, bin = stub, timeout = 60 })
check(second ~= nil and second.id == record.id:gsub('%-001$', '-002'),
  'a second review of the same branch is numbered, not overwritten')
check(second.brief.path == nil and second.brief.bytes == 0, 'a review with no brief says so instead of inheriting one')
-- `read_file` answers nil for a directory whether or not it is there, so the scratch's absence is asked
-- of the path (the first real review of this branch found this check passing with cleanup deleted).
local gone = select(2, pcall(host.path_kind, second.isolation.scratch))
check(gone == 'missing', 'a scratch root is removed when the review is done (' .. tostring(gone) .. ')')

-- A review that writes into its own export is recorded as having done so: the manifest is a digest of the
-- whole export (one line - a 3,000-line manifest came back clipped and compared equal; fifth review).
local writer_stub = home .. '/writer-wa.sh'
check(host.write_file(writer_stub, table.concat({
  '#!/bin/sh',
  'echo "edited" >> "$PWD/feature.txt"',
  'echo "REVIEW change/fixture ' .. sha .. ' findings=0"',
  'exit 0',
  '', }, '\n')), 'a stub that edits its own export exists')
exec('chmod 755 ' .. shquote(writer_stub), '', 60)
local wrote = reviewer.run({ branch = 'change/fixture', repo = repo, bin = writer_stub, timeout = 60 })
check(wrote ~= nil, 'the writing review runs')
check(wrote.checkout_changed == true, 'and the record says its export changed')
check(wrote.effects ~= nil, 'and the effects the sink refused are stored, not only claimed')
local clean = reviewer.run({ branch = 'change/fixture', repo = repo, bin = stub, timeout = 60 })
check(clean.checkout_changed == nil, 'while a review that writes nothing records no change')

-- An abbreviated sha of THIS commit is this commit, not "another commit" (fifth review, finding 5).
local short_stub = home .. '/short-wa.sh'
check(host.write_file(short_stub, table.concat({
  '#!/bin/sh',
  'echo "REVIEW change/fixture ' .. sha:sub(1, 9) .. ' findings=0"',
  'exit 0',
  '', }, '\n')), 'a stub that echoes an abbreviated sha exists')
exec('chmod 755 ' .. shquote(short_stub), '', 60)
local short = reviewer.run({ branch = 'change/fixture', repo = repo, bin = short_stub, timeout = 60 })
check(short ~= nil and short.state == 'reviewed',
  'an abbreviated sha of this tip is accepted (' .. tostring(short and short.state) .. ')')

-- ---------------------------------------------------------------- 5. marks, misses and the totals
local marked, mark_why = reviewer.mark(record.id, 'accepted', 1)
check(marked ~= nil, 'a finding can be marked: ' .. tostring(mark_why))
check(marked.marks['1'].state == 'accepted', 'the accepted mark is stored on the finding it names')
local inline = reviewer.mark(record.id .. '#2', 'rejected')
check(inline ~= nil and inline.marks['2'].state == 'rejected', '`<id>#2` marks the second finding alone')
check(inline.marks['1'].state == 'accepted', 'and leaves the first one as it was')
local refused_mark, refused_why = reviewer.mark(record.id, 'accepted', 9)
check(refused_mark == nil and tostring(refused_why):find('is not one', 1, true) ~= nil,
  'a finding number the review does not have is refused by name')
local refused_word = reviewer.mark(record.id, 'maybe')
check(refused_word == nil, 'a mark that is not accepted/rejected is refused')
-- A review that found nothing is a real outcome ("If nothing changes behavior, say so in one line"), and
-- marking a finding that does not exist must be refused rather than invented.
check(core.write_json(reviewer.review_path('nothing-001'), {
  schema = reviewer.SCHEMA, id = 'nothing-001', branch = 'change/nothing', sha = sha,
  base_ref = 'main', base_sha = base_sha, findings = 0, state = 'reviewed', marks = {},
}), 'a review with no findings can be stored')
local no_findings, no_findings_why = reviewer.mark('nothing-001', 'accepted')
check(no_findings == nil and tostring(no_findings_why):find('no findings', 1, true) ~= nil,
  'a review with no findings has nothing to mark, and says so')

-- A LONE mark, on a review whose marks are empty, re-read from disk: `marks[2]` on its own is a sparse
-- array and `lua/vendor/json.lua` refuses one, which crashed the door and dropped the mark (finding 1).
local lone, lone_why = reviewer.mark(second.id, 'rejected', 2)
check(lone ~= nil, 'a lone mark on the second finding is accepted: ' .. tostring(lone_why))
local reread = reviewer.record(second.id)
check(reread ~= nil and type(reread.marks) == 'table', 'the review is readable back from disk after a lone mark')
check(type(reread.marks['2']) == 'table' and reread.marks['2'].state == 'rejected',
  'and the mark is on the finding it names, in the stored record')
local lone_counts = { reviewer.counts(reread) }
check(lone_counts[2] == 1 and lone_counts[3] == 1, 'the counts read a lone mark as one rejected, one unmarked')

local miss, miss_why = reviewer.miss('change/fixture', 'the reviewer missed the bypass', repo)
check(miss ~= nil, 'a miss is recorded: ' .. tostring(miss_why))
check(miss.sha == sha, 'the miss names the commit it was found on')
local empty_miss, empty_miss_why = reviewer.miss('change/fixture', '', repo)
check(empty_miss == nil and tostring(empty_miss_why):find('note', 1, true) ~= nil,
  'a miss with no note is refused (a miss nobody can read is not evidence)')

local totals = reviewer.totals()
check(totals.reviews >= 3, 'the totals count every review in the store (' .. tostring(totals.reviews) .. ')')
check(totals.findings >= 4 and totals.accepted == 1 and totals.rejected == 2
  and totals.unmarked == totals.findings - 3,
  string.format('the totals count every finding and every mark (%d findings, 1 accepted, 2 rejected, %d unmarked)',
    totals.findings, totals.unmarked))
check(totals.accepted_rate ~= nil and math.abs(totals.accepted_rate - 1 / 3) < 0.001,
  'the accepted rate is over the findings that were marked')
check(totals.misses == 1, 'the totals count the misses')

local report_text = table.concat(core.report({ all = true, reviews = reviewer }), '\n')
check(report_text:find('reviews (data only - a review never blocks a landing)', 1, true) ~= nil,
  'the report names the review store as data only')
check(report_text:find('accepted rate 33%', 1, true) ~= nil, 'the report shows the accepted rate')
check(report_text:find('misses 1', 1, true) ~= nil, 'the report shows the misses')
check(report_text:find('change/fixture', 1, true) ~= nil, 'the report names the branch, not its text')
check(report_text:find('BYPASS-MARKER', 1, true) == nil, "the report never prints the review's text")
local without = table.concat(core.report({ all = true }), '\n')
check(without:find('reviews (data only', 1, true) == nil, 'a caller that passes no store gets the old report')

-- ---------------------------------------------------------------- 6. the door
local function door(args)
  local code
  local printed = {}
  local real_print = print
  print = function(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
  end
  code = cli.run(args)
  print = real_print
  return code, table.concat(printed, '\n')
end
local door_code, door_text = door({ 'eval', 'reviewer', 'change/fixture', '--repo', repo, '--bin', stub,
  '--brief', brief_path, '--timeout', '60' })
check(door_code == 0, 'the door exits 0 with findings, so it cannot block a landing (' .. tostring(door_code) .. ')')
check(door_text:find('REVIEW change/fixture ' .. sha .. ' findings=2', 1, true) ~= nil,
  'the door prints the final REVIEW line')
check(door_text:find('BYPASS-MARKER', 1, true) ~= nil, 'the door prints the findings themselves')
-- The model is one model: an option that would change it is refused rather than silently dropped.
local model_code, model_text = door({ 'eval', 'reviewer', 'change/fixture', '--repo', repo, '--bin', stub,
  '--model', 'gpt-6.1-sol' })
check(model_code == 2 and model_text:find('unknown option --model', 1, true) ~= nil,
  'the door refuses `--model`: the reviewer is one model')
-- Main's storage form for a replay run is still reachable, and still storage only.
core.record_run({ schema = core.SCHEMA, id = 'fixture-run-001', task_id = 'fixture-run',
  category = 'code-fix', check = { kind = 'human' }, metrics = { rounds = 1 } })
local storage_code, storage_text = door({ 'eval', 'reviewer', 'run', 'fixture-run-001', '--findings', '3',
  '--accepted', '2', '--misses', '1', '--cost', '0.04' })
check(storage_code == 0, 'the storage form on a replay run still works (' .. tostring(storage_code) .. ')')
check(storage_text:find('"findings":3', 1, true) ~= nil, 'and it stores the reviewer shape it always did')
-- A stub that answers about another sha: the door must say so and exit non-zero, and the last line must
-- not be presented as this branch's (third real review, finding 3).
local wrong_stub = home .. '/wrong-wa.sh'
check(host.write_file(wrong_stub, table.concat({
  '#!/bin/sh',
  'echo "looked at the wrong commit"',
  'echo "REVIEW change/fixture ' .. string.rep('ab', 20) .. ' findings=1"',
  'exit 0',
  '',
}, '\n')), 'a stub that answers about another commit exists')
exec('chmod 755 ' .. shquote(wrong_stub), '', 60)
local wrong_code, wrong_text = door({ 'eval', 'reviewer', 'change/fixture', '--repo', repo, '--bin', wrong_stub })
check(wrong_code == 1, 'a review about another commit exits non-zero (' .. tostring(wrong_code) .. ')')
check(wrong_text:find('not change/fixture', 1, true) ~= nil,
  'and says which commit it answered about')
check(wrong_text:find("the session's own final line:", 1, true) ~= nil,
  'and quotes its line as the session\'s, not as this branch\'s')

-- A branch whose name is a subcommand word is reachable with `--branch` (third real review, finding 6).
check(exec_git(repo, 'branch list ' .. sha).status == 0, 'a branch named `list` exists')
local list_stub = home .. '/list-wa.sh'
check(host.write_file(list_stub, table.concat({
  '#!/bin/sh',
  'echo "REVIEW list ' .. sha .. ' findings=1"',
  'exit 0',
  '',
}, '\n')), 'a stub that answers for the branch named `list` exists')
exec('chmod 755 ' .. shquote(list_stub), '', 60)
local named_code, named_text = door({ 'eval', 'reviewer', '--branch', 'list', '--repo', repo, '--bin', list_stub })
check(named_code == 0, '`--branch list` reviews the branch named `list` (' .. tostring(named_code) .. ')')
check(named_text:find('review list', 1, true) ~= nil, 'and the review is of that branch')

local usage_code, usage_text = door({ 'eval', 'help' })
check(usage_code == 0 and usage_text:find('wa eval reviewer <branch>', 1, true) ~= nil,
  'the help text shows the branch door (not the old run-id recorder)')
check(usage_text:find('--brief', 1, true) ~= nil and usage_text:find('reviewer mark', 1, true) ~= nil,
  'and the brief option and the marks are in it')
-- (`wa eval run` still takes `--model`; it is the REVIEW line that must not, because a reviewer spread
-- over several models is not one reviewer.)
check(usage_text:find('reviewer <branch> [--brief <file>] [--base <ref>] [--repo <dir>] [--bin <wa>]',
  1, true) ~= nil, 'the usage shows the branch door without a model option')
check(usage_text:find('[--branch <name>]', 1, true) ~= nil,
  'and the `--branch` escape hatch the docs list is in the text that ships')

-- Not a gate: the landing queue does not read the reviewer's store.
local queue = root ~= '' and read(root .. '/scripts/landing-queue.mjs') or nil
if queue then
  check(queue:find('harness_evaluator_reviewer', 1, true) == nil, 'the landing queue does not read the reviewer')
  check(queue:find('eval reviewer', 1, true) == nil, 'and does not call it')
else
  print('SKIP the landing queue is not readable from this row, so "it does not read the reviewer" is unchecked')
end

-- A note that begins with a dash is a note, not an unknown option (finding 5).
local dash_code, dash_text = door({ 'eval', 'reviewer', 'miss', 'change/fixture', '--note',
  '--missed the bypass on line 12' })
check(dash_code == 0, 'a note that starts with `--` is accepted (' .. tostring(dash_code) .. ')')
check(dash_text:find('--missed the bypass on line 12', 1, true) ~= nil, 'and stored as written')

-- A switch VALUE nobody recognises leaves the reviewer on and is said out loud (third review, finding 5).
check(host.write_file(config_file, 'reviewer = disabled\n'), 'the config carries a value nobody knows')
local typo_code, typo_text = door({ 'eval', 'reviewer', 'change/fixture', '--repo', repo, '--bin', stub,
  '--timeout', '60' })
check(typo_code == 0 and typo_text:find('is not one of off/0/false/no', 1, true) ~= nil,
  'a typo in the switch is printed, not obeyed silently')
host.write_file(config_file, '')

-- The switch, through the door an operator uses: the env spelling, in a child process.
local child_home = home .. '/door-home'
exec('mkdir -p ' .. shquote(child_home), '', 60)
local function door_child(env_prefix)
  local command = 'env -u WA_SCRIPT -u WASM_AGENT_LUA_ROOT HOME=' .. shquote(child_home)
    .. ' WASM_AGENT_HOME=' .. shquote(child_home) .. ' WASM_AGENT_DB=' .. shquote(child_home .. '/door.db')
    .. ' WASM_AGENT_MANAGED=0 ' .. env_prefix .. ' ' .. shquote(bin)
    .. ' eval reviewer change/fixture --repo ' .. shquote(repo) .. ' --bin ' .. shquote(stub)
  return exec(command, '', 120)
end
-- One spawn proves two things: the env switch turns it off, and it does so with NO branch named (the door
-- reads the switch before demanding a positional - third real review, finding 7 of the first round).
local bare_off = exec('env -u WA_SCRIPT -u WASM_AGENT_LUA_ROOT HOME=' .. shquote(child_home)
  .. ' WASM_AGENT_HOME=' .. shquote(child_home) .. ' WASM_AGENT_DB=' .. shquote(child_home .. '/door.db')
  .. ' WASM_AGENT_MANAGED=0 WA_REVIEWER=off ' .. shquote(bin) .. ' eval reviewer', '', 120)
check(tonumber(bare_off.code) == 0, 'WA_REVIEWER=off with no branch exits 0 (' .. tostring(bare_off.code) .. ')')
check(tostring(bare_off.stdout):find('the reviewer is off', 1, true) ~= nil,
  'and says the reviewer is off, with or without a branch named')
check(tostring(bare_off.stdout):find('REVIEW ', 1, true) == nil, 'and runs no review')
check(host.write_file(child_home .. '/.wasm-agent/env', 'reviewer = off\n'), 'the child config file is writable')
local config_off = door_child('')
check(tonumber(config_off.code) == 0, '`reviewer = off` in the config file exits 0 (' .. tostring(config_off.code) .. ')')
check(tostring(config_off.stdout):find('the reviewer is off', 1, true) ~= nil,
  'and the config-file spelling of the one switch turns it off too')
-- The word can arrive two ways the host itself makes equivalent: this engine reads `<config>/env`, and the
-- host's own loader puts the same line in the environment at startup. Either way the door names where the
-- switch came from instead of saying nothing.
check(tostring(config_off.stdout):find('config ', 1, true) ~= nil
  or tostring(config_off.stdout):find('environment reviewer', 1, true) ~= nil,
  'and names the source of the switch it obeyed')

-- ---------------------------------------------------------------- 7. the fresh session, with the real binary
-- No vault in a fast-path row, so this review cannot answer. What it proves is the part that matters
-- here: the child runs a session of its own, in its own ledger, given this prompt - and this row's own
-- ledger does not see it.
local function own_sessions()
  return tonumber((json.decode(host.sql_query('SELECT COUNT(*) AS n FROM sessions', '[]')) or {})[1].n) or -1
end
local before = own_sessions()
local real, real_why = reviewer.run({
  branch = 'change/fixture', repo = repo, brief = brief_path, bin = bin, timeout = 90, keep_scratch = true,
})
check(real ~= nil, 'the real binary runs the review: ' .. tostring(real_why))
check(real.state == 'no_review', 'with no model reachable the review records no_review, not a finding')
check(real.metrics.model_calls == 0, 'and zero model calls - the honest shape of a model-less row')
check(real.ledger_sessions == 1, 'the child kept exactly one session: its own, in its own ledger')
check(real.session_id ~= nil and real.session_id ~= '', "the record names the child's session")
check(own_sessions() == before, "the review added no session to this row's ledger")
check(tonumber((json.decode(host.sql_query('SELECT COUNT(*) AS n FROM sessions WHERE id=?',
  json.encode({ real.session_id }))) or {})[1].n) == 0, "the child's session is not in this row's ledger")
-- `read_file` refuses a binary file, so the ledger's existence is asked of the path, not of its bytes.
local ledger_kind = select(2, pcall(host.path_kind, real.isolation.scratch .. '/home/.wasm-agent/memory.db'))
check(ledger_kind == 'file', "the child's own ledger exists (" .. tostring(ledger_kind) .. ")")
local real_prompt = read(real.isolation.scratch .. '/prompt.txt') or ''
check(real_prompt:sub(1, #EXPECTED) == EXPECTED, 'the real child was given the same instruction text')
local dump = replay.dump_ledger(real.isolation.scratch, bin, real.isolation.scratch .. '/bin')
local child_user = nil
for _, row in ipairs(dump.messages or {}) do
  if row.role == 'user' and tostring(row.content):find('Branch: change/fixture', 1, true) ~= nil then
    child_user = row
  end
end
check(child_user ~= nil, "the child's ledger holds the prompt it was given")
check(tostring(child_user.content):sub(1, #EXPECTED) == EXPECTED, 'and that prompt begins with the text')
check(tostring(child_user.session_id) == tostring(real.session_id), 'in the session the record names')

print(string.format('harness evaluator reviewer ok (%d checks)', checks))
