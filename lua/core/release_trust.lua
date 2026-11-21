-- The trust set of ANOTHER node, from this one: "wa release trust-key <id> <hex> --node <peer>".
--
-- WHY THIS MODULE EXISTS (21/11, hand fix 2 of the node-7ddbfa98036a rollout). Nothing in wa wrote a
-- trusted-keys file: an operator wrote one by hand, and a file without the "wa-trusted-keys v1" header made
-- every release on that node refuse as release_unsigned_or_forged. The local writer is the binary's own verb
-- (rust/wa-host/src/release.rs, "wa release trust-key"), which writes the file atomically, keeps a backup and
-- READS IT BACK through the same parser a verification uses before it says ok. This module is only the fleet
-- door to it: the same command, run on the node whose trust set is changing, through the mesh capability the
-- rest of the fleet verbs use (lua/core/land.lua M.node_bash), under that node's own admission rules.
--
-- NOTHING IS COMPOSED HERE THAT THE PEER COULD NOT TYPE ITSELF: the body is one "exec <its own wa> release
-- trust-key ..." line, the key id and hex are quoted arguments, and a peer that cannot find its binary
-- refuses by name instead of executing something else.
local M = {}

M.CAPABILITY = 'release_trust'

M.USAGE = {
  'wa release trust-key <id> <public hex> [--file <path>]              trust a release key on THIS node',
  'wa release trust-key <id> <public hex> --node <peer> [--file <path>] trust it on another node, through the mesh',
  'wa release trust-key <id> --retire [--node <peer>]                  stop trusting it (the file is rewritten)',
  '  the file is written atomically, the one it replaces is kept as <path>.bak, and it is read back',
  '  through the parser a release verification uses before the command says ok.',
}

local function trim(text) return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function slashes(text) return (tostring(text or ''):gsub('\\', '/')) end
-- One argument, as a shell word: a key id and a path are the only things quoted here, and an id with a quote
-- in it is refused by the binary's own parser anyway.
local function quote(text) return "'" .. tostring(text or ''):gsub("'", "'\\''") .. "'" end

-- The fabric's own remote call, as land.lua and remote_update.lua use it: capability "bash" on a named node.
local function call()
  local ok, nodes = pcall(dofile, 'lua/core/nodes.lua')
  if not ok or type(nodes) ~= 'table' or type(nodes.remote_call) ~= 'function' then
    error('lua/core/nodes.lua is unavailable, so no peer can be reached')
  end
  return nodes.remote_call
end

-- Run one shell command on <node>. Answers the reply, or nil and a named refusal - a node that answers
-- nothing is a refusal, never a pass.
local function node_bash(node, command)
  local ok, reply = pcall(call(), tostring(node), 'bash', { command = command })
  if not ok or type(reply) ~= 'table' then
    return nil, { error = 'node_unreachable', observed = tostring(reply or 'the call produced nothing') }
  end
  if reply.error then
    return nil, { error = 'node_refused',
      observed = tostring(reply.error) .. ((reply.note and (' - ' .. tostring(reply.note))) or '') }
  end
  return reply
end

-- WHICH wa ON THE PEER. The same lesson as the deploy path (scripts/lib/node-runtime.sh): a shell that runs
-- for a node through the mesh does not carry the PATH an interactive login has, so "wa" alone is not an
-- answer. The places a node installs itself are searched in order, and a node with none of them refuses BY
-- NAME rather than running something else - the one thing this module must never guess is which binary holds
-- that node's trust file.
local function binary_prelude()
  return table.concat({
    'B=""',
    'for c in "$WA_BIN" "$HOME/.local/bin/wa" "/usr/local/bin/wa" "/usr/bin/wa" "$(command -v wa 2>/dev/null)"; do',
    '  if [ -n "$c" ] && [ -x "$c" ]; then B="$c"; break; fi',
    'done',
    '[ -n "$B" ] || { echo "node_binary_missing: the peer has no executable wa (looked at WA_BIN, its own install, /usr/local/bin, /usr/bin and PATH), so its trust set cannot be written" >&2; exit 2; }',
  }, '\n')
end

-- <id> <hex|nil> <retire> <file|nil> --node <peer> -> an "exec" line the peer runs verbatim.
local function remote_command(id, hex, retire, file)
  local argv = { '"$B"', 'release', 'trust-key', quote(id) }
  if retire then
    argv[#argv + 1] = '--retire'
  else
    argv[#argv + 1] = quote(hex)
  end
  if file and file ~= '' then
    argv[#argv + 1] = '--file'
    argv[#argv + 1] = quote(slashes(file))
  end
  return binary_prelude() .. '\nexec ' .. table.concat(argv, ' ')
end

-- The parsed CLI. Returns an exit code, or nil when this is not the verb's shape (so the caller can fall
-- through). --node is required here: without it the binary's own verb has already answered locally, before
-- the interpreter booted.
function M.cli(argv)
  argv = type(argv) == 'table' and argv or {}
  if tostring(argv[2] or '') ~= 'trust-key' then return nil end
  local id, hex, node, file, retire, as_json = nil, nil, nil, nil, false, false
  local index = 3
  while argv[index] do
    local word = tostring(argv[index])
    if word == '--node' or word == '--to' or word == '--file' then
      local value = argv[index + 1]
      if type(value) ~= 'string' or value == '' or value:sub(1, 2) == '--' then
        print('wa release trust-key: ' .. word .. ' needs a value')
        return 1
      end
      if word == '--node' then node = value else file = value end
      index = index + 2
    elseif word == '--retire' then
      retire = true; index = index + 1
    elseif word == '--json' then
      as_json = true; index = index + 1
    elseif word == '--help' or word == '-h' then
      for _, line in ipairs(M.USAGE) do print(line) end
      return 0
    elseif word:sub(1, 2) == '--' then
      print('wa release trust-key: unknown option ' .. word .. '; nothing was asked')
      return 1
    else
      if id == nil then id = word elseif hex == nil then hex = word else
        print('wa release trust-key: unexpected argument ' .. word .. ' (the arguments are the key id, then its public hex)')
        return 1
      end
      index = index + 1
    end
  end
  if id == nil or id == '' then
    print('wa release trust-key: name the key id (wa release trust-key <id> <public hex> [--node <peer>])')
    return 1
  end
  if not retire and (hex == nil or hex == '') then
    print('wa release trust-key: name the public key, or retire the id with --retire')
    return 1
  end
  if node == nil or node == '' then
    -- The binary answers the local form; reaching here means it declined, which is a bug worth naming.
    print('wa release trust-key: no --node was named and the local writer did not answer; nothing was written')
    return 1
  end
  if hex and not hex:match('^%x+$') then
    print('wa release trust-key: "' .. hex .. '" is not hex')
    return 1
  end
  local reply, problem = node_bash(node, remote_command(id, hex, retire, file))
  if not reply then
    local message = 'wa release trust-key: ' .. tostring(problem.error) .. ' on ' .. tostring(node) ..
      ' (' .. tostring(problem.observed) .. ')'
    if as_json then print('{"ok":false,"node":' .. ('"' .. tostring(node) .. '"') .. ',"error":' ..
      ('"' .. tostring(problem.error) .. '"') .. '}') else print(message) end
    return 1
  end
  local out = trim(reply.stdout)
  local code = tonumber(reply.code or 0) or 0
  if code ~= 0 then
    local why = trim(reply.stderr)
    if why == '' then why = out end
    if as_json then
      print('{"ok":false,"node":"' .. tostring(node) .. '","code":' .. tostring(code) .. ',"observed":"' ..
        tostring(why):gsub('"', '\\"'):gsub('\n', ' ') .. '"}')
    else
      print('wa release trust-key: ' .. tostring(node) .. ' refused (' .. tostring(code) .. '): ' .. why)
    end
    return 1
  end
  if as_json then
    print('{"ok":true,"node":"' .. tostring(node) .. '","detail":"' .. tostring(out):gsub('"', '\\"'):gsub('\n', ' ') .. '"}')
  else
    -- The peer's own sentence is the answer: it is the one that says the file was read back.
    print(tostring(node) .. ': ' .. out)
  end
  return 0
end

return M
