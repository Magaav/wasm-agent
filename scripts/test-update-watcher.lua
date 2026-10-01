-- `/update` must not report a request as queued when no watcher can perform it.
--
-- The live shape this exists for: a deploy request sat in the sentinel's box for over an hour while the
-- installed app stayed on the old commit, because no watcher was running - and `/update` had already
-- answered that the sentinel would deploy the tree. `wa-sentinel request` writes a file and returns;
-- the *watcher* is what performs it, so the pre-queue path has to prove there is one before it says
-- queued, and it must not answer "queued" for a request nothing can claim.
--
-- Runs without building anything, and reads nothing of this machine's: a stub host answers the same
-- shell questions the module would ask, over an in-memory file system, so the real install, config
-- directory and request box are never touched. Every shell command the module issues is recorded, which
-- is how "nothing was queued" and "no watcher was started" are checked rather than assumed.
--
--   WA_SCRIPT=scripts/test-update-watcher.lua wa --db /tmp/wa-update-watcher.db
--
-- Prints `update watcher decision ok`; a failed check raises, so the gate reads a verdict and not a
-- summary.

local home = "fixture:/home"
local install = home .. "/install"
local sentinel_dir = home .. "/.wasm-agent/sentinel"
local sentinel = install .. "/wa-sentinel.exe"
local tree = home .. "/tree"

-- ---- the host the module is given ------------------------------------------

local vfs, issued, alive = {}, {}, {}
local verified_lock = true
local request_answer   -- nil: the stub sentinel accepts. A table: a scripted answer.

local function escaped(text)
  return (tostring(text or ""):gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

-- The operation wrapper `host.exec` returns, as JSON: `code` says whether the command succeeded.
local function wrapper(code, stdout, stderr)
  return '{"code":' .. tostring(code) .. ',"stdout":"' .. escaped(stdout) .. '","stderr":"' .. escaped(stderr) .. '"}'
end

local function listing(dir)
  local names = {}
  local prefix = dir .. "/"
  for path in pairs(vfs) do
    if path:sub(1, #prefix) == prefix then
      local name = path:sub(#prefix + 1)
      if name ~= "" and not name:find("/", 1, true) then names[#names + 1] = name end
    end
  end
  table.sort(names)
  return table.concat(names, "\n")
end

local real_host = host

-- The module is loaded through the *real* host, before the stub below exists. `scripts/test.sh` exports
-- WASM_AGENT_LUA_ROOT so that the gate tests the tree and not the copy embedded in the binary, and the
-- host resolves `dofile` through `host.read_file`: a stub whose file system is an empty table would
-- make the module unloadable (`lua_root_unreadable`) - and the checks would then run against the
-- embedded copy, passing while proving nothing about the file under test.
local update = dofile("lua/core/update.lua")
local json = dofile("lua/vendor/json.lua")

host = {
  platform = function()
    return { os = "windows", arch = "x86_64", shell = "sh -c", pathSeparator = "/", cwd = home }
  end,
  paths = function()
    return { home = home, config = home .. "/.wasm-agent", data = home, cache = home .. "/cache", temp = home }
  end,
  getenv = function(name) return os.getenv(name) end,
  now = function() return os.time() end,
  read_file = function(path) return vfs[path] end,
  write_file = function(path, text) vfs[path] = text; return true end,
  exec = function(command)
    issued[#issued + 1] = command
    local path = command:match('^test %-s "(.*)"$')
    if path then
      return wrapper((vfs[path] ~= nil and #vfs[path] > 0) and 0 or 1, "", "")
    end
    if command:find(" preflight", 1, true) then
      local pid = (vfs[sentinel_dir .. "/sentinel.pid"] or ""):match("(%d+)")
      local pending = {}
      for path,text in pairs(vfs) do
        if path:find(sentinel_dir .. "/requests/",1,true) == 1 or path:find(sentinel_dir .. "/claimed/",1,true) == 1 then
          local ok, request = pcall(json.decode,text)
          if ok and request.verb == "deploy" then pending[#pending+1]=path:sub(#sentinel_dir+2) end
        end
      end
      return wrapper(0,json.encode({schema=1,watcher=alive[pid] and (verified_lock and "running" or "unverified") or "not_running",
        watcher_pid=tonumber(pid),ownership="watcher_lifetime_lock",stop_file=vfs[sentinel_dir .. "/stop"] ~= nil,
        pending_deploys=pending,capabilities={health_free=true,atomic_deploy_dedupe=true}}),"")
    end
    local dir = command:match("^ls %-1 %-%- '(.*)' 2>/dev/null$")
    if dir then return wrapper(0, listing(dir), "") end
    if command:find("request deploy", 1, true) then
      if request_answer then return request_answer() end
      return wrapper(0, "  requested deploy: " .. sentinel_dir .. "/requests/1700000000-99.json\n", "")
    end
    return wrapper(1, "", "this test scripts no answer for: " .. command)
  end,
}
-- Anything this test does not script (the host's own bookkeeping around a script) still comes from the
-- real host, so the stub cannot turn a missing field into a failure of the test itself.
setmetatable(host, { __index = function(_, key) return real_host[key] end })

-- ---- the fixture ----------------------------------------------------------

vfs[install .. "/runtime-worktree.txt"] = tree .. "\n"
vfs[install .. "/installed.txt"] = "commit=abc1234\n"
vfs[sentinel] = "#!/bin/sh - the fixture's sentinel\n"

local function ask()
  -- One case's evidence only: what was issued while *this* question was answered.
  issued = {}
  return update.run({ install = install, sentinel_dir = sentinel_dir, skip_source_sync = true,
                      reason = "the watcher test" })
end

local function queued(fragment)
  local found = 0
  for _, command in ipairs(issued) do
    if command:find(fragment, 1, true) then found = found + 1 end
  end
  return found
end

local checks = 0
local function ok(condition, label, detail)
  checks = checks + 1
  if not condition then error("FAIL " .. label .. (detail and (" - " .. tostring(detail)) or ""), 2) end
  print("  ok: " .. label)
end

-- 1. No watcher at all: two refusals that must not read as a queue.
vfs[sentinel_dir .. "/sentinel.pid"] = "4242\n"
local report = ask()
ok(report.ok == false and report.error == "no_watcher", "a stale watcher pid is refused, got " .. tostring(report.error))
ok(not report.queued and report.status == "no_watcher", "and it is not reported as queued")
ok(report.message:find("was not queued", 1, true) ~= nil, "the answer says the request was not queued")
ok(report.observed:find("sentinel.pid", 1, true) ~= nil, "the refusal names the file it looked at", report.observed)
ok(report.next:find(sentinel .. " start", 1, true) ~= nil, "and the command that starts a watcher", report.next)
ok(report.next:find("schtasks /Run /TN wasm-agent-sentinel", 1, true) ~= nil,
  "and the registered Windows task, which is what survives a logoff")
ok(queued("request deploy") == 0, "no request was written for it")
ok(queued(" start") == 0, "/update did not start a watcher itself")

-- 2. No pid file at all is the same answer: the sentinel's own rule for "not running".
vfs[sentinel_dir .. "/sentinel.pid"] = nil
report = ask()
ok(report.error == "no_watcher", "a missing pid file is refused the same way, got " .. tostring(report.error))
ok(queued("request deploy") == 0, "and nothing was written for it")

-- 3. A watcher that IS running, with nothing pending: the request is written, once, and no second
--    watcher is started beside it.
alive["4242"] = true
vfs[sentinel_dir .. "/sentinel.pid"] = "4242\n"
report = ask()
ok(report.queued == true and report.status == "queue", "a running watcher still queues, got " .. tostring(report.status))
ok(report.observed:find("a watcher is running (pid 4242)", 1, true) ~= nil,
  "and the answer says which watcher will perform it", report.observed)
ok(queued("request deploy") == 1, "exactly one request was written")
ok(queued(" start") == 0, "and no second watcher was started")

-- 4. A deploy already in the box: not a second one.
vfs[sentinel_dir .. "/requests/1700000000-98.json"] = '{"verb":"deploy","reason":"/update: the first ask"}'
report = ask()
ok(report.ok == false and report.error == "already_pending",
  "a pending deploy is not duplicated, got " .. tostring(report.error))
ok(report.message:find("wrote nothing", 1, true) ~= nil, "the answer says nothing new was written")
ok(report.pending == "requests/1700000000-98.json", "and names the request that is already waiting", report.pending)
ok(queued("request deploy") == 0, "no second request was written")

-- 5. A pending request of another verb is not a duplicate deploy.
vfs[sentinel_dir .. "/requests/1700000000-98.json"] = '{"verb":"restart","reason":"something else"}'
report = ask()
ok(report.queued == true, "a pending restart does not block a deploy, got " .. tostring(report.status))
ok(queued("request deploy") == 1, "and the deploy was written")

-- 6. A claimed deploy is being performed, so it counts as pending too.
vfs[sentinel_dir .. "/requests/1700000000-98.json"] = nil
vfs[sentinel_dir .. "/claimed/1700000000-97.json"] = '{"verb":"deploy","reason":"/update: the first ask"}'
report = ask()
ok(report.error == "already_pending", "a deploy being performed is not duplicated, got " .. tostring(report.error))
vfs[sentinel_dir .. "/claimed/1700000000-97.json"] = nil

-- 7. An intentional stop is never reversed. The stop file is the operator's, so this refuses - and
--    does not remove it, start a watcher, or queue anything the stop would strand.
vfs[sentinel_dir .. "/stop"] = "1700000000\n"
report = ask()
ok(report.ok == false and report.error == "sentinel_stopped",
  "a stopped sentinel is refused, got " .. tostring(report.error))
ok(report.next:find("does not clear a stop you made", 1, true) ~= nil,
  "and the answer says the stop is left alone", report.next)
ok(queued(" start") == 0, "nothing started it")
ok(queued("request deploy") == 0, "and nothing was queued for it")
ok(vfs[sentinel_dir .. "/stop"] ~= nil, "the stop file is still there")
vfs[sentinel_dir .. "/stop"] = nil

-- 8. The refusals below the new check still work: a sentinel that refuses, and one that cannot be run.
request_answer = function() return wrapper(2, "", "unknown verb \"deploy\"") end
report = ask()
ok(report.error == "sentinel_refused" and not report.queued, "a refusing sentinel is not a success")
request_answer = function() return "not JSON at all" end
report = ask()
ok(report.error == "sentinel_unreachable" and not report.queued, "a sentinel that answers nothing is not a success")
request_answer = function() return wrapper(0,"existing deploy request: /fixture/claimed/concurrent.json\n","") end
report = ask()
ok(report.error == "already_pending" and not report.queued,"atomic concurrent duplicate is reported without a new queue")
request_answer = function() return wrapper(0,"","") end
report = ask()
ok(report.error == "sentinel_unverifiable" and not report.queued,"exit zero without durable request evidence is refused")
request_answer = nil
verified_lock = false
report = ask()
ok(report.error == "no_watcher" and not report.queued,"a live recycled/legacy pid without a lifetime lock is refused")
ok(queued("request deploy") == 0,"unverified watcher never writes a request")
ok(queued("/health") == 0 and queued(sentinel .. "' status") == 0,"preflight never calls node health or sentinel status")

print("update watcher decision ok (" .. checks .. " checks)")
host = real_host
