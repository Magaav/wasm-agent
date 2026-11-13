-- `/nodes` as a view the *client* can draw while a turn is in flight.
--
-- The bug: `/status` is answered instantly during a run because the interpreter published its panel
-- before the run (`host.status_snapshot`) and the host's reader thread draws it. `/nodes` had no such
-- channel, so typing it mid-run queued it behind the turn: for a long turn, nothing happened.
--
-- What is tested here is the half that lives in Lua - the snapshot the interpreter publishes, how old
-- it may get, that a round boundary never reaches for the network, that a refused snapshot is
-- reported rather than swallowed, that an older binary loses nothing, and that the specs are the very
-- ones the interactive panel draws (one builder, two renderers). The other half - the client taking
-- the line out of its queue instead of queueing it - is `rust/wa-cli-views/tests/console_reader.rs`,
-- because the queue lives in the host binary and Lua cannot run while a run is in flight.
--
-- Hermetic: no rendezvous (the roster is this node alone), no model, no network.
local json = dofile("lua/vendor/json.lua")

local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. label) end
end
local function has(list, text)
  for _, line in ipairs(list or {}) do if tostring(line):find(text, 1, true) then return true end end
  return false
end

-- One clock for the whole test, so "how old is this snapshot" is a number and not a sleep.
local clock = 1000
host.now = function() return clock end

-- `host.local_view` as the client will provide it: it records what it was handed and answers the way
-- the host function does. `refuse` makes it answer the way it does for a spec that failed a check.
local published, refuse = {}, nil
host.local_view = function(name, spec_json)
  if refuse then return json.encode({ ok = false, error = refuse, detail = "test" }) end
  local decoded, spec = pcall(json.decode, spec_json)
  if not decoded then return json.encode({ ok = false, error = "spec_unreadable" }) end
  published[#published + 1] = { name = name, spec = spec, json = spec_json }
  return json.encode({ ok = true, command = spec.command, views = #spec.views, captured_at = spec.captured_at })
end

local local_views = dofile("lua/core/local_views.lua")
local nodes_cli = dofile("lua/core/nodes_cli.lua")
local commands = dofile("lua/core/commands.lua")
local cli_input = dofile("lua/core/cli_input.lua")

-- ---- the channel and the registry -----------------------------------------------------------------
ok(local_views.available(), "this binary offers the local-view channel (the stub above)")
ok(has(local_views.names(), "/nodes"), "the published views include /nodes: " .. table.concat(local_views.names(), ", "))
ok(has(commands.local_views(), "/nodes"), "the command registry declares /nodes a read-only local view")

-- ---- what `/nodes` publishes -----------------------------------------------------------------------
local count, problem = local_views.refresh({ max_age = 60 })
ok(problem == nil, "the first publish reports no problem, got " .. tostring(problem))
ok(count == #local_views.names() and #published == count,
  "every published view went out, got " .. tostring(count) .. "/" .. tostring(#published))
-- `/nodes` is what this test is about: the other builders (`/mcp`, `/login`, `/help`) are read the same
-- way by the same channel, and each has its own test.
local first
for _, entry in ipairs(published) do if entry.name == "/nodes" then first = entry end end
ok(first and first.name == "/nodes", "it is filed under the command it answers")
ok(first.spec.command == "/nodes" and first.spec.captured_at == 1000, "the snapshot says what it answers and when it was taken")
ok(first.spec.nodes == nil, "only what the client draws crosses the channel, not the raw roster")

local root = first.spec.views and first.spec.views[1]
ok(root and root.title == "Nodes", "views[1] is the list")
ok(root and has(root.lines, "Cluster:") and has(root.lines, "0 peers"), "the list carries the cluster and the peer count")
ok(root and root.options and #root.options == 1, "one option for the one node there is")
ok(root and root.options[1].view == 1, "the option opens the node's page: 0-based, as the client indexes it")
local page = first.spec.views and first.spec.views[2]
ok(page and has(page.lines, "Node id: "), "views[2] is the node's page")
ok(page and page.options and page.options[1].pop == true and page.options[1].label == "Back", "the page's way back is the Back option")

-- One builder, two renderers: the client is handed the specs the interactive panel draws.
local drawn = {}
nodes_cli.run({ print = function() end, panel = function(spec) drawn[#drawn + 1] = spec; return { action = "cancel" } end })
ok(drawn[1] and drawn[1].title == root.title, "the published list and the interactive panel share a title")
local same_labels = drawn[1] and #drawn[1].options == #root.options
for index = 1, #(drawn[1] and drawn[1].options or {}) do
  same_labels = same_labels and drawn[1].options[index].label == root.options[index].label
    and drawn[1].options[index].hint == root.options[index].hint
end
ok(same_labels, "and the same options, label for label: the two surfaces cannot drift")

-- ---- staleness: an old snapshot is not re-published on every round, and is re-published after its
-- ---- max age, so a long run's reader sees "snapshot 2m ago" and not a frozen first picture.
clock = 1010
ok(select(1, local_views.refresh({ max_age = 60 })) == 0, "a fresh snapshot is not rebuilt")
clock = 1100
ok(select(1, local_views.refresh({ max_age = 60 })) == #local_views.names(), "a snapshot older than its max age is")
local again
for _, entry in ipairs(published) do if entry.name == "/nodes" then again = entry end end
ok(again and again.spec.captured_at == 1100, "and it says when it was taken")

-- ---- a round boundary never reaches for the network -------------------------------------------------
host.http = function() error("a local view must never make the model wait on a network read") end
local cached_ok, cached = pcall(local_views.refresh, { max_age = 0, cached = true })
ok(cached_ok and cached == #local_views.names(), "a snapshot taken inside a run reads no network, got " .. tostring(cached))

-- ---- a refused snapshot is reported, the old one keeps working --------------------------------------
refuse = "spec_too_large"
local refused_count, refused_problem = local_views.refresh({ max_age = 0 })
ok(refused_count == 0 and type(refused_problem) == "string" and refused_problem:find("/", 1, true) ~= nil
  and refused_problem:find("spec_too_large", 1, true) ~= nil,
  "a refusal names the view it was for, got " .. tostring(refused_problem))
refuse = nil
ok(select(1, local_views.refresh({ max_age = 0 })) == #local_views.names(), "the next free moment publishes it again")

-- ---- an older binary: no capability, no error, no change -------------------------------------------
host.local_view = nil
ok(local_views.available() == false, "the channel is reported absent rather than assumed")
local absent_ok, absent_count, absent_problem = pcall(local_views.refresh, { max_age = 0 })
ok(absent_ok and absent_count == 0 and absent_problem == nil,
  "a binary without the channel publishes nothing and fails at nothing: /nodes behaves as before")

-- ---- and the half that works today: the line never becomes model input -----------------------------
-- While a run is in flight, `/nodes` is REPL control. `take_steering` must leave it in the queue for
-- the REPL (where the client's snapshot answers it, or the REPL arm does after the turn) and must not
-- hand it to the model as a note - which is the other way this bug could have hurt.
local input = cli_input.new({ deps = {
  start = function() return '{"started":true,"editor":true}' end,
  take = function() return '{"lines":["/nodes"],"eof":false,"running":true}' end,
} })
local steering = input:take_steering()
ok(#steering == 0, "a /nodes typed during a run is not sent to the model")
ok(input:waiting() == 1, "it is still one entry in the REPL's queue, not lost")

if failed > 0 then print("nodes instant: " .. failed .. " failed of " .. checks .. " checks"); os.exit(1) end
print("nodes instant ok (" .. checks .. " checks)")
