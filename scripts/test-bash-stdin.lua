-- bash {stdin}: the text a caller gives is the command's standard input, then it is closed
-- (mission tool-args-honest-and-same-on-peers, item 4).
--
-- The finding: `tools.remote({capability:"bash", stdin:"hello"})` wrote an empty file and answered code 0
-- with empty stdout. The field did not exist, nothing refused it, and the call ran as a different call.
-- Now it exists on every route - the direct call here, a script's `tools.bash`, and a peer's capability -
-- because it is one declared field fed by ONE spawn path (rust/wa-operation: Spec.stdin -> process.rs), and
-- the peer path is the same dispatch.
--
-- What this row pins: the bytes arrive; the command sees EOF afterwards instead of waiting forever; a
-- caller without the field gets the null device it always got; a value that is not a string and a text above
-- the bound are refused BY NAME with effect none, so a command is never run with half its input.
--
-- Run it with the tree's own binary: this is a host capability, so the Lua root alone cannot prove it.
--   WASM_AGENT_HOME=<scratch> WA_SCRIPT=scripts/test-bash-stdin.lua wa --db <scratch>/t.db
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
dofile('lua/core/server.lua')   -- defines wa_peer_dispatch, the seam a verified peer reaches
local home = host.paths().home
local ctx = { user_id = 'master' }
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local function bash(args) return tools.dispatch(memory, 'bash', args, 'master', ctx) end

-- 1. Victor's own test: hello through cat.
local hello = bash({ command = 'cat', stdin = 'hello' })
check(type(hello) == 'table' and hello.code == 0, 'cat with stdin exits 0: ' .. json.encode(hello):sub(1, 200))
check(hello.stdout == 'hello', 'the command reads exactly the text it was given: ' .. json.encode(hello.stdout):sub(1, 120))

-- 2. Multi-line, and the bytes are the caller's own (a trailing newline is part of the text).
local multi = bash({ command = 'cat', stdin = 'one\ntwo\n' })
check(multi.stdout == 'one\ntwo\n', 'a multi-line text arrives unchanged: ' .. json.encode(multi.stdout):sub(1, 120))

-- 3. EOF, not a hang: a command that reads one line finishes at once instead of waiting for a terminal.
local line = bash({ command = 'read line; printf "%s" "$line"', stdin = 'only\n' })
check(line.code == 0 and line.stdout == 'only', 'a single read gets the line and then end-of-input: ' .. json.encode(line):sub(1, 200))

-- 4. No stdin is the null device it always was: `read` returns at once with nothing.
local nothing = bash({ command = 'read nothing; printf done' })
check(nothing.code == 0 and nothing.stdout == 'done', 'without stdin the command sees the null device: ' .. json.encode(nothing):sub(1, 200))

-- 5. A text above the declared bound is REFUSED by name, and the command does not run.
local marker = home .. '/stdin-too-large-ran'
local big = bash({ command = 'printf x > ' .. marker, stdin = string.rep('x', tools.STDIN_MAX_BYTES + 1) })
check(big.error == 'stdin_too_large', 'a text above the bound is refused by name: ' .. json.encode(big):sub(1, 200))
check(big.effect == 'none' and big.max_bytes == tools.STDIN_MAX_BYTES, 'and nothing ran: ' .. json.encode(big):sub(1, 200))
check(host.read_file(marker) == nil, 'the refused command never ran')

-- 6. A value that is not text is refused by name too, rather than coerced.
local wrong = bash({ command = 'cat', stdin = 5 })
check(wrong.error == 'invalid_stdin' and wrong.effect == 'none', 'a non-text stdin is refused: ' .. json.encode(wrong):sub(1, 200))

-- 7. The ADOPTED path a peer reaches (budget_ms) carries it: same field, same executor, one hop away.
local caller = { node_id = 'peer-stdin-probe', role = 'master' }
local adopted = wa_peer_dispatch('bash', { command = 'cat', stdin = 'hello', budget_ms = 8000 }, caller, 'master')
check(type(adopted) == 'table' and tonumber(adopted.code) == 0,
  'adopted bash runs the command: ' .. json.encode(adopted):sub(1, 240))
check(tostring(adopted.stdout or '') == 'hello',
  'and the adopted command reads the same text: ' .. json.encode(adopted.stdout):sub(1, 120))

print(('bash stdin: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
