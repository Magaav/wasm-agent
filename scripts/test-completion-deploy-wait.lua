-- A CHILD-RETURN REMINDER IS NEVER LOST TO A WAITING DEPLOY (23/11, Fable's review 1b).
--
-- Two defects, both measured on this tree before the change:
--   * `completions.tick` had no deploy gate, so a `ready` settlement was admitted as a run while a deploy waited
--     - one more turn holding the node that the deploy cannot pass over;
--   * and the run's own gate then refused that turn, `pcall` succeeded, and `wa_completion_run` recorded the row as
--     `delivered` with the refusal as a note - so the summary a coordinator had earned was gone. A reminder that
--     silently never fires is worse than a slow deploy.
--
-- Run from the repo root, in a scratch home (this row writes a sentinel box and a ledger):
--   WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-completion-deploy-wait.lua wa --db <that home>/t.db
local json = dofile('lua/vendor/json.lua')
local why_home = dofile('scripts/lib/scratch-home.lua').guard('test-completion-deploy-wait')
if why_home then print('REFUSED test-completion-deploy-wait: ' .. why_home); os.exit(2) end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local paths = dofile('lua/core/paths.lua')
local original = dofile
local refused_text = 'deploy_waiting: waiting for the install of 8082b42e1111 (deploy request x, asked 0s ago).'

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label, 2) end
end

-- The deploy request in the sentinel's own box, exactly the shape the reader reads
-- (lua/core/deploy_wait.lua): verb, target, when it was asked for.
local box = paths.data() .. '/sentinel/requests'
host.exec("mkdir -p '" .. box .. "'", "", 30)
local REQUEST = box .. '/1795402546196179687-2690687-00000000000000000000.json'
local function deploy_waiting(waiting)
  if waiting then
    local text = json.encode({ verb = 'deploy', target_commit = '8082b42e11112222333344445555666677778888',
      queued_at = os.time(), reason = 'the fix Victor is waiting for' })
    ok(host.write_file(REQUEST, text), 'the request is in the box')
  else
    host.exec("rm -f '" .. REQUEST .. "'", "", 30)
  end
end

-- Loaded with the node's own users/nodes replaced: this row is about dispatch, not about authority.
local function with_stubs(fn)
  dofile = function(path)
    if path == 'lua/core/users.lua' then
      return { find = function() return { role = 'master' } end,
        is_master = function(role) return role == 'master' end }
    end
    if path == 'lua/core/nodes.lua' then return { is_master = function() return true end } end
    if path == 'lua/core/agent.lua' then
      return { new = function()
        return { run = function(self) self.turn_refused = refused_text; return refused_text end }
      end }
    end
    return original(path)
  end
  local answer = fn()
  dofile = original
  return answer
end

local completions = with_stubs(function() return original('lua/core/completions.lua') end)
local session = memory.start_session('', 'parent', { user_id = 'owner' })
local ctx = { user_id = 'owner', role = 'master', session_id = session }
local api = { control = function(a)
  return { subagent_id = a.id, state = 'completed', settled = true, session_id = 'child:' .. tostring(a.id) }
end }

local enqueued = 0
with_stubs(function()
  host.enqueue_completion = function() enqueued = enqueued + 1; return json.encode({ accepted = true, run_id = 4242 }) end
end)

-- 1. A deploy waits: the outbox does not advance, and nothing is claimed or dispatched.
deploy_waiting(true)
with_stubs(function()
  completions.watch('child-a', ctx)
  completions.tick(api)
  completions.tick(api)
end)
ok(enqueued == 0, 'no child-return wake is admitted while a deploy waits (enqueued ' .. enqueued .. ')')
local row = completions.status('child-a', 'owner')
ok(row and row.state ~= 'delivered', 'the settlement is not recorded as delivered: ' .. tostring(row and row.state))

-- 2. The deploy ends: the same settlement is delivered, exactly once.
deploy_waiting(false)
for _ = 1, 4 do with_stubs(function() completions.tick(api) end) end
ok(enqueued == 1, 'the settlement is delivered once the deploy ends (enqueued ' .. enqueued .. ')')
row = completions.status('child-a', 'owner')
ok(row.state == 'accepted', 'and is recorded as accepted: ' .. tostring(row and row.state))

-- 3. A RUN THE NODE REFUSED IS NOT A DELIVERY: the row goes back to ready, with the refusal beside it, so the
--    next tick after the deploy delivers it - instead of vanishing as `delivered`.
local queued_child = 'child-refused'
with_stubs(function()
  completions.watch(queued_child, ctx)
  completions.tick(api)
end)
-- the row is claimed as `accepted` by the delivery above only for child-a; make this one look dispatched:
host.sql_exec("UPDATE child_completions SET state='accepted', run_id='7' WHERE child_id=?", json.encode({ queued_child }))
local answer = with_stubs(function()
  return wa_completion_run(json.encode({ id = queued_child, owner = 'owner', session_id = session,
    packet = '{}' }))
end)
local decoded = json.decode(answer)
row = completions.status(queued_child, 'owner')
ok(row.state == 'ready', 'a refused run returns the row to ready, not delivered: ' .. tostring(row.state))
ok(tostring(row.detail or ''):find('deploy_waiting', 1, true) ~= nil,
  'and the row says why: ' .. tostring(row.detail))
ok(decoded.not_started == true, 'and the caller is told nothing started: ' .. tostring(answer))

-- 4. After the deploy, that row is delivered once - the reminder still arrives.
deploy_waiting(false)
local before = enqueued
for _ = 1, 4 do with_stubs(function() completions.tick(api) end) end
ok(enqueued == before + 1, 'the refused settlement is delivered after the deploy (enqueued ' .. enqueued .. ')')
row = completions.status(queued_child, 'owner')
ok(row.state == 'accepted', 'and recorded as accepted: ' .. tostring(row and row.state))

print('completion deploy wait ok (' .. checks .. ' checks: held while a deploy waits, delivered once after it, a refused run is not a delivery)')

