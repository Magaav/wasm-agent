-- The shipped default guard: a PreToolUse refusal for the two actions that took this fleet offline.
--
-- Why this exists at all (docs/FLEET-OPS.md, `skills/fleetops/incidents.json`): on 06/11 an agent that
-- could not get fleet control added itself to `WASM_AGENT_NETWORK_ADMINS` in the rendezvous drop-in
-- and restarted `wa-rendezvous`. Nodes that pin the admin set they were bound with dropped out of the
-- directory: nextcloud and mail were offline for 18.5 hours, and again for about an hour on 08/11.
-- A written rule was not enough, so the boundary refuses those two commands and names the safe path.
--
-- What it is, exactly:
--
-- * a **refusal of two known-destructive actions**, not a limit on the work. It never counts calls,
--   never asks the model to stop, never grades a plan. Everything else - including reading the same
--   files, `systemctl status wa-rendezvous`, the journal, and `wa fleet push-roster` - is untouched.
-- * **shipped and on by default**, because the incident it prevents is silent and fleet-wide.
-- * **overridable**, and visibly so: an operator hook named `guard-destructive` in the node's or the
--   project's `hooks.json` replaces this one (the engine's own precedence: their entry runs, this
--   predicate steps aside), and `WASM_AGENT_DEFAULT_GUARD=off` (or `WASM_AGENT_HOOKS=off`) turns it
--   off for a node that has decided otherwise. `/hooks` prints which state it is in.
-- * **in the node, not in a guest.** It reads the arguments the node already decoded and decides; it
--   runs no command, opens no file and holds no secret.
--
-- It is deliberately narrow: a command that merely *mentions* `WASM_AGENT_NETWORK_ADMINS` (a grep, a
-- doc edit, a `cat` of the file) is allowed, because reading the config is how the operator and the
-- agent diagnose it. Only an edit of that setting, an edit of the rendezvous drop-in, or a
-- restart/stop of the rendezvous service is refused.
local json = dofile('lua/vendor/json.lua')

local M = {}

M.VERSION = 1

-- The exact sentence the refusal carries (the job's wording, and what the tests assert).
M.REASON = 'this detaches nodes that pin the admin set; use mesh (`wa fleet push-roster`)'

-- The guard's identity, as `/hooks` lists it.
M.GUARD = {
  name = 'guard-destructive',
  event = 'PreToolUse',
  origin = 'shipped',
  kind = 'lua',
  -- Documentation, not a matcher: the predicate below decides per call. Named tools are the ones whose
  -- arguments can carry one of the two actions.
  tools = { bash = true, shell = true, operation = true, exec = true, write = true,
    edit = true, patch = true, apply_patch = true },
}

-- A bounded view of the arguments: a write's content can be megabytes, and the guard only needs the
-- command line, the path, and a slice of the text.
M.MAX_INPUT = 8192

-- Editors and writers of a config line. `sed -i`, `tee`, a redirect, an in-place python, an editor,
-- `install`, `cp`/`mv` over the file, `systemctl edit`. Kept as one list so a test can assert it.
local EDIT_VERBS = {
  'sed%s+%-%-?i', 'sed%s+%-%-in%-place', 'tee', '%f[%w_%.]>+%s*[%w%/]', 'cat%s*>', 'printf.*>',
  'python', 'python3', 'perl%s+%-', '%f[%w_]vi%f[%W]', 'vim', 'nano', 'emacs', 'install%s', 'cp%s+',
  'mv%s+', 'truncate', 'dd%s', 'systemctl%s+edit', 'patch%s', 'rsync', 'ansible',
}

-- A year of shell habits in one line: these are the words that make a line of text an *edit*.
local SERVICE_VERBS = { 'restart', 'stop', 'start', 'reload', 'kill', 'try-restart', 'force-reload' }
local SERVICE_MANAGERS = { 'systemctl', 'service', 'rc-service', 'initctl', 'supervisorctl' }

local function word_in(text, word)
  local pattern = '%f[%w]' .. word:gsub('%-', '%%-') .. '%f[%W]'
  return text:find(pattern) ~= nil
end

-- The two things that must never happen. Named here (not inline) so a reviewer reads the whole rule in
-- one place.
M.TARGETS = {
  admin_variable = 'WASM_AGENT_NETWORK_ADMINS',
  rendezvous_unit = 'wa%-rendezvous',
  rendezvous_dropin = 'wa%-rendezvous%.service%.d',
  rendezvous_dropin_file = 'managed%.conf',
}

local function text_of(value)
  if type(value) == 'string' then return value end
  if type(value) == 'number' or type(value) == 'boolean' then return tostring(value) end
  if type(value) ~= 'table' then return '' end
  local ok, encoded = pcall(json.encode, value)
  if not ok or type(encoded) ~= 'string' then return '' end
  if #encoded > M.MAX_INPUT then return encoded:sub(1, M.MAX_INPUT) end
  return encoded
end

local function matches_any(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern) then return pattern end
  end
  return nil
end

-- `systemctl restart wa-rendezvous`, `service wa-rendezvous stop`, `systemctl --user reload
-- wa-rendezvous.service`: a manager, a verb and the unit, each as a whole word.
local function restarts_rendezvous(text)
  local lowered = tostring(text or ''):lower()
  if not lowered:find(M.TARGETS.rendezvous_unit) then return nil end
  local manager = matches_any(lowered, SERVICE_MANAGERS)
  if manager then
    for _, verb in ipairs(SERVICE_VERBS) do
      if word_in(lowered, verb) then return 'service_restart' end
    end
  end
  -- No manager named, but the unit and the verb are adjacent: `wa-rendezvous restart`.
  if lowered:find('wa%-rendezvous%.?service?[%s]*%(restart|stop|start|reload)') then
    return 'service_restart'
  end
  return nil
end

-- The judgement, as a pure function of the tool call. Answers `nil` (nothing to refuse) or a record
-- naming the rule that refused it, so a refusal can always be read back and argued with.
function M.judge(tool_name, tool_input)
  local tool = tostring(tool_name or '')
  local input = type(tool_input) == 'table' and tool_input or {}
  local command = text_of(input.command or input.cmd or input.script or input.text or '')
  local path = text_of(input.path or input.file or input.file_path or input.target or '')
  local lowered_command = command:lower()
  local lowered_path = path:lower()
  -- A tool that carries its targets in a list (a routed `tool_call` batch, a plugin's own shape) is the
  -- same act and must not slip past because the top-level path was empty.
  local extra_paths = {}
  for _, key in ipairs({ 'files', 'edits', 'items', 'writes', 'targets' }) do
    local list = input[key]
    if type(list) == 'table' then
      for _, entry in ipairs(list) do
        if type(entry) == 'table' then
          local target = entry.path or entry.file or entry.file_path or entry.filename
          if type(target) == 'string' and target ~= '' then extra_paths[#extra_paths + 1] = target:lower() end
        end
      end
    end
  end

  -- 1. An edit of the rendezvous drop-in, whichever tool does it. A *write* to that path is refused
  --    even when its content looks harmless, because the file only exists to change the directory.
  local edit_verb = matches_any(lowered_command, EDIT_VERBS)
  for _, target in ipairs(extra_paths) do
    if target:find(M.TARGETS.rendezvous_dropin) or target:find(M.TARGETS.rendezvous_dropin_file) then
      return { rule = 'edit_rendezvous_dropin', tool = tool, target = 'wa-rendezvous.service.d', batch = true }
    end
  end
  if (lowered_path:find(M.TARGETS.rendezvous_dropin) or lowered_path:find(M.TARGETS.rendezvous_dropin_file)) then
    if tool ~= 'read' and tool ~= 'grep' and tool ~= 'ls' and tool ~= 'glob' then
      return { rule = 'edit_rendezvous_dropin', tool = tool, target = 'wa-rendezvous.service.d' }
    end
  end
  -- A shell command that edits that same file: `sed -i ... managed.conf`, `tee managed.conf`.
  if edit_verb and (lowered_command:find(M.TARGETS.rendezvous_dropin)
      or lowered_command:find(M.TARGETS.rendezvous_dropin_file)) then
    return { rule = 'edit_rendezvous_dropin', tool = tool, target = 'wa-rendezvous.service.d', verb = edit_verb }
  end

  -- 2. A restart, stop, start or reload of the rendezvous service itself.
  local restart = restarts_rendezvous(lowered_command)
  if restart then
    return { rule = 'restart_rendezvous', tool = tool, target = 'wa-rendezvous' }
  end

  -- 3. An edit of the admin set, through a command rather than the file tools.
  if lowered_command:find(M.TARGETS.admin_variable:lower(), 1, true) then
    if edit_verb then
      return { rule = 'edit_admin_set', tool = tool, target = 'WASM_AGENT_NETWORK_ADMINS', verb = edit_verb }
    end
    -- A shell that would make the variable take effect in a rendezvous unit is the same act even
    -- without an editor: `env WASM_AGENT_NETWORK_ADMINS=... wa-rendezvous` names the unit as well.
    if lowered_command:find(M.TARGETS.rendezvous_unit) then
      return { rule = 'edit_admin_set', tool = tool, target = 'WASM_AGENT_NETWORK_ADMINS' }
    end
  end

  return nil
end

-- Is the shipped guard in force for this node? `view` is the hook engine's merged config view (what the
-- operator configured), so "replaced by the operator's own entry" is the engine's own ordering and not
-- a second rule invented here.
function M.enabled(view, opts)
  opts = opts or {}
  local env = function(name)
    local ok, value = pcall(host.getenv, name)
    return ok and tostring(value or '') or ''
  end
  local flag = tostring(opts.flag or env('WASM_AGENT_DEFAULT_GUARD')):lower()
  if flag == 'off' or flag == '0' or flag == 'false' then return false, 'disabled_by_env' end
  if tostring(env('WASM_AGENT_HOOKS')):lower() == 'off' then return false, 'hooks_disabled' end
  if type(view) == 'table' then
    for _, entry in ipairs((view.hooks and view.hooks.PreToolUse) or {}) do
      if type(entry) == 'table' and tostring(entry.name or '') == M.GUARD.name then
        return false, 'replaced_by_config'
      end
    end
  end
  return true, 'shipped'
end

-- The answer shape the engine's own interpreter reads (`lua/core/hooks.lua`, the Claude Code protocol).
function M.answer(judgement)
  return {
    hookSpecificOutput = {
      hookEventName = 'PreToolUse',
      permissionDecision = 'deny',
      permissionDecisionReason = M.REASON,
    },
    reason = M.REASON,
    systemMessage = 'guard-destructive: ' .. M.REASON,
    detail = judgement,
  }
end

-- The one call the engine makes. Answers nil (no objection) or the refusal record.
function M.pre_tool_use(payload, ctx, opts)
  opts = opts or {}
  local view = opts.view
  local enabled, basis = M.enabled(view, opts)
  if not enabled then return nil, basis end
  payload = type(payload) == 'table' and payload or {}
  local judgement = M.judge(payload.tool_name, payload.tool_input)
  if not judgement then return nil, 'allow' end
  judgement.reason = M.REASON
  return M.answer(judgement), 'deny'
end

-- The line `/hooks` prints for it.
function M.describe(view, opts)
  local enabled, basis = M.enabled(view, opts)
  return {
    name = M.GUARD.name,
    event = M.GUARD.event,
    origin = 'shipped',
    kind = 'lua',
    enabled = enabled,
    basis = basis,
    reason = M.REASON,
    override = 'an operator hook named "' .. M.GUARD.name .. '" in hooks.json replaces it; '
      .. 'WASM_AGENT_DEFAULT_GUARD=off turns it off',
  }
end

return M
