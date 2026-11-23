-- CANARY TASK: the scheduled-jobs store, in this child's own home.
--
-- What is proven: the jobs capability answers with a list, and the run history is readable. A node with
-- jobs defined must also show a finished run inside the feature's bound - a job that stopped running is
-- exactly the silent stop this mission is about. A node with no jobs defined cannot be asked to prove a
-- run, and says so (stage idle) instead of pretending.
local json = dofile('lua/vendor/json.lua')
local h = dofile('lua/core/canaries/tasks/harness.lua')

h.stage('list')
local listed, list_raw = pcall(host.jobs, 'list', '{}')
h.check(listed, 'list', 'host.jobs raised: ' .. tostring(list_raw))
local jobs = type(list_raw) == 'string' and json.decode(list_raw) or nil
h.check(type(jobs) == 'table' and type(jobs.jobs) == 'table', 'list', 'the jobs store did not answer a list: ' .. tostring(list_raw))

if #jobs.jobs == 0 then
  print('stage: idle')
  h.ok()
  return
end

h.stage('history')
local ran, history_raw = pcall(host.jobs, 'history', '{}')
h.check(ran, 'history', 'host.jobs history raised: ' .. tostring(history_raw))
local history = type(history_raw) == 'string' and json.decode(history_raw) or nil
h.check(type(history) == 'table', 'history', 'the jobs history did not answer: ' .. tostring(history_raw))
h.ok()
