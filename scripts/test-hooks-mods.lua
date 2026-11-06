-- The mods surface (docs/MODS.md): the operator's own footer segment, slash commands and key
-- declarations, all from the same config files as hooks. Model-free and hermetic: every command is
-- this test's own script in its own scratch home.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end

local config, home = paths.config(), paths.home()
local function sh(command)
  local result = json.decode(host.exec(command, '', 30))
  assert(result and result.code == 0, command .. ' -> ' .. json.encode(result))
end
local function write(path, text) assert(host.write_file(path, text), 'write ' .. path) end
local function script(name, body)
  local path = config .. '/' .. name .. '.sh'
  write(path, '#!/usr/bin/env bash\n' .. body .. '\n')
  sh("chmod +x '" .. path .. "'")
  return "bash '" .. path .. "'"
end
local function answer(name, text)
  return script(name, "printf '%s' " .. string.format('%q', text))
end
sh("mkdir -p '" .. config .. "'")

local hooks = dofile('lua/core/hooks.lua')
local counter = home .. '/statusline-calls.txt'
os.remove(counter)

-- A footer segment that counts how often it ran, and echoes the model it was told about. Builtins
-- only: this environment spawns a process in about a second, and a test must measure the hook layer,
-- not Git Bash's startup.
write(config .. '/hooks.json', json.encode({ mods = {
  statusline = {
    { name = 'branch', command = script('status',
      "payload=$(cat)\nprintf 'x' >> '" .. counter .. "'\nmodel=${payload#*\\\"model\\\":\\\"}\nmodel=${model%%\\\"*}\nprintf 'main - %s' \"$model\"") },
  },
  commands = {
    { name = '/hello', description = 'say hello to a name', command = answer('hello',
      json.encode({})) , timeout_ms = 5000 },
  },
  keybindings = { { key = 'ctrl+g', command = 'git status', description = 'show the working tree' } },
} }))

-- The command answers only when the argument reached it as JSON on stdin - which is what a mod is.
write(config .. '/hello.sh',
  '#!/usr/bin/env bash\npayload=$(cat)\n'
  .. 'case "$payload" in *\'"args":"world"\'*) printf "hello world" ;; *) printf "missing args" ;; esac\n')
sh("chmod +x '" .. config .. "/hello.sh'")

hooks.reset()
local segment = hooks.statusline({ session_id = 's1', model = 'gpt-test', runs = 3 })
ok(segment:find('main', 1, true) ~= nil, 'the footer segment is the command\'s stdout: ' .. segment)
ok(segment:find('gpt-test', 1, true) ~= nil, 'the status-line payload carries the model, so a mod can use it')
ok(not segment:find('\n', 1, true), 'a segment is one line, even when the command prints more')
local first = #(host.read_file(counter) or '')
local again = hooks.statusline({ session_id = 's1', model = 'gpt-test', runs = 3 })
local second = #(host.read_file(counter) or '')
ok(again == segment and first == second, 'a redraw inside the TTL reuses the segment instead of running the command again')

-- A different session is a different key: the cache is not a lie about which thread it describes.
hooks.statusline({ session_id = 's2', model = 'gpt-test' })
ok(#(host.read_file(counter) or '') > second, 'another session reads its own segment')

-- The footer segment is capped, so one mod cannot take the whole row.
write(config .. '/hooks.json', json.encode({ mods = { statusline = {
  { name = 'long', command = answer('long', string.rep('x', 400)) } } } }))
hooks.reset()
local long = hooks.statusline({ session_id = 's3' })
ok(#long <= hooks.STATUSLINE_MAX + 4, 'a segment is clipped to the documented bound plus a three-byte ellipsis (' .. #long .. ')')

-- A failing status line is marked, never raised: the footer is not a failure surface.
write(config .. '/hooks.json', json.encode({ mods = { statusline = {
  { name = 'broken', timeout_ms = 500, command = script('broken', 'exit 3') } } } }))
hooks.reset()
local broken = hooks.statusline({ session_id = 's4' })
ok(broken == '!broken', 'a broken segment is named in the row instead of breaking it: ' .. broken)

-- ---- slash commands ------------------------------------------------------------------------------
write(config .. '/hooks.json', json.encode({ mods = { commands = {
  { name = '/hello', description = 'say hello to a name', command = "bash '" .. config .. "/hello.sh'" },
} } }))
hooks.reset()
local listed = hooks.commands({})
ok(#listed == 1 and listed[1].name == '/hello', 'the configured command is listed')
ok(listed[1].description == 'say hello to a name', 'with its description')
local ran = hooks.run_command('/hello', 'world', { session_id = 's' })
ok(ran.ok == true and ran.output == 'hello world', 'the command runs with its arguments: ' .. tostring(ran.output))
local missing = hooks.run_command('/nope', '', {})
ok(missing.ok == false and missing.error == 'unknown_hook_command', 'an unknown command is refused by name')
local no_args = hooks.run_command('/hello', '', { session_id = 's' })
ok(no_args.ok == true and no_args.output == 'missing args',
  'the same command without the argument says so rather than guessing: ' .. tostring(no_args.output))

-- A plugin command is a Lua function; it is listed with the configured ones and runs the same way.
local handle, why = hooks.register_command('/plugin', function(args) return 'plugin saw ' .. tostring(args.args) end,
  { description = 'a Lua command' })
ok(handle ~= nil, 'a Lua command registers: ' .. tostring(why))
local plugin_list = hooks.commands({})
ok(#plugin_list == 2 and plugin_list[2].name == '/plugin', 'both kinds are listed, config first')
local plugin_ran = hooks.run_command('/plugin', 'this', {})
ok(plugin_ran.ok == true and plugin_ran.output == 'plugin saw this', 'a Lua command runs')
local bad_handle, bad_why = hooks.register_command('noslash', function() end)
ok(bad_handle == nil and bad_why == 'command_name_must_start_with_slash', 'a command name must start with /')

-- ---- the `/hooks` report -------------------------------------------------------------------------
write(config .. '/hooks.json', json.encode({
  hooks = { PreToolUse = { { name = 'policy', matcher = 'bash', command = 'true' } } },
  mods = { statusline = { { name = 'branch', command = 'echo main' } },
    commands = { { name = '/hello', description = 'say hello', command = 'true' } },
    keybindings = { { key = 'ctrl+g', command = 'git status', description = 'show the working tree' } } } }))
hooks.reset()
local report = hooks.report({ session_id = 's' })
ok(report:find('PreToolUse', 1, true) ~= nil and report:find('policy', 1, true) ~= nil,
  '/hooks names the event and the hook')
ok(report:find('footer segments: 1', 1, true) ~= nil, '/hooks counts the footer segments')
ok(report:find('command /hello', 1, true) ~= nil, '/hooks lists the custom command')
ok(report:find('keybinding ctrl+g', 1, true) ~= nil, '/hooks lists the key declaration')
ok(report:find('source node', 1, true) ~= nil, '/hooks names the config file it read')

-- ---- the CLI list -------------------------------------------------------------------------------
-- `/hooks` is a real command: listed for the reader, handled by the REPL (scripts/test-command-parity.cjs
-- checks the arm; this asserts the row the help is generated from).
local commands = dofile('lua/core/commands.lua')
local names = commands.names()
local found = false
for _, name in ipairs(names) do if name == '/hooks' then found = true end end
ok(found, 'commands.lua lists /hooks for the REPL and for the window')
ok(commands.help():find('/hooks', 1, true) ~= nil, 'and the generated help prints it')

if failed > 0 then
  print(string.format('hooks mods: %d failed of %d checks', failed, checks))
  os.exit(1)
end
print(string.format('hooks mods ok (%d checks)', checks))
