-- THE CLI IS NOT THE NODE (26/11, Fable item 2a).
--
-- `wa services status` asks this process kernel registry, and a name this process was never told about answers
-- not_running - measured 26/11, the CLI said not_running while the node said running. When another process serves
-- this node, the CLI must say "served by pid N; ask it" and never print its own empty registry as the node state.
-- A pid file that outlives its process is not evidence: liveness decides.
local cli = dofile('lua/core/services_cli.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if value then print('  ok   ' .. label) else failed = failed + 1; print('  FAIL ' .. label) end end
local function has(text, needle, label) ok(tostring(text):find(needle, 1, true) ~= nil, label .. ' (in ' .. tostring(text):sub(1, 100) .. ')') end

ok(type(cli.supervisor) == 'function', 'services_cli.supervisor is a named function')
ok(type(cli.served) == 'function', 'services_cli.served is the gate the CLI uses')

local PID_PATH = '/fixture/serve.pid'
local function fixture(files, options)
  options = options or {}
  return {
    paths = { PID_PATH },
    pid = options.pid or 100,
    read_file = function(path)
      local value = files[path]
      if value == nil then error('no such file: ' .. tostring(path)) end
      return value
    end,
  }
end

-- 1. a live supervisor other than this process
local live = fixture({ [PID_PATH] = '4242\n', ['/proc/4242/cmdline'] = 'wa\0serve\0' })
local sup = cli.supervisor(live)
ok(sup ~= nil, 'a serve.pid naming a live pid is found')
ok(sup.pid == 4242, 'with the pid it names')
ok(sup.path == PID_PATH, 'and the file it came from')
local served = cli.served('status', live)
ok(served ~= nil, 'status is gated when another process serves the node')
ok(served.mutating == false, 'status is not a mutation')
has(served.line, 'served by pid 4242', 'and the line says who serves it')
has(served.line, 'ask it', 'with the way out: ask it')
ok(served.line:find('not_running', 1, true) == nil, 'and never says not_running')

-- 2. a verb that changes the node is refused, not run beside the supervisor
local start = cli.served('start', live)
ok(start ~= nil and start.mutating == true, 'start is refused while another process serves the node')
ok(cli.served('stop', live).mutating == true, 'and so is stop')
ok(cli.served('enable', live).mutating == true, 'and enable')

-- 3. list is not gated: its rows are the stored definitions
ok(cli.served('list', live) == nil, 'list still runs (stored definitions, not live state)')

-- 4. a pid file that outlives its process is not evidence
local stale = fixture({ [PID_PATH] = '4242\n' })
ok(cli.supervisor(stale) == nil, 'a stale serve.pid (no live pid) is not a supervisor')
ok(cli.served('status', stale) == nil, 'so status is not gated by it')

-- 5. this process is the node: its own pid is not another supervisor
local mine = fixture({ [PID_PATH] = '100\n', ['/proc/100/cmdline'] = 'wa\0serve\0' })
ok(cli.supervisor(mine) == nil, 'the CLI own pid in the file is not another supervisor')

-- 6. no pid file at all is the ordinary CLI case
local none = fixture({})
ok(cli.supervisor(none) == nil, 'no serve.pid means no supervisor claimed here')
ok(cli.served('status', none) == nil, 'and nothing is gated')

-- 7. the gate is wired into M.run, and its JSON names the refusal
local src = host.read_file('lua/core/services_cli.lua') or ''
has(src, 'local served = M.served(verb, options)', 'M.run asks the gate')
has(src, 'cli_is_not_the_node', 'and the machine answer carries its own error name')
has(src, 'served_by', 'with the pid that serves the node')

-- 8. the paths it looks at
local paths = cli.serve_pid_paths({})
ok(type(paths) == 'table', 'serve_pid_paths answers a list')

if failed > 0 then print(string.format('services cli served FAILED (%d checks, %d failed)', checks, failed)) return 1 end
print(string.format('services cli served ok (%d checks)', checks))
return 0
