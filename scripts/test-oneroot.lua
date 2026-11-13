-- One root, one `wa clean`, one cap (docs/ONEROOT.md), proved from inside a running node.
--
-- What this covers, and why each one is here rather than only in the Rust unit tests:
--
--   * TMPDIR reaches a CHILD PROCESS. The promise is that a build, a test, a component or any shell the
--     node spawns writes its scratch inside the root - measured 12/11, `/tmp` was 98 % full on the `work`
--     node and broke deploys while the node's own state root was 0.4 GB. A Rust assertion about the spec
--     would prove the intent; this runs a real `bash` and reads what it saw.
--   * the one command: `wa clean --dry-run` deletes nothing and names what would go, then the real run
--     deletes it and reports the bytes.
--   * pins: a pinned path survives, and a pin outside the root is refused by name.
--   * the landed-worktree rule, the `..`/symlink guard and retention live in Rust
--     (`rust/wa-capabilities/src/disk_tests.rs`); this file proves the node's own wiring of them.
--   * the cap: a node whose filesystem is past its cap refuses NEW HEAVY WORK by name (`disk_cap`)
--     instead of filling the disk. That needs its own process, because the cap is read where the node
--     starts and a running node's environment cannot be rewritten underneath it.
--
-- Every path used here is inside this row's own scratch root, and the fast path gives every row one.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local clean = dofile("lua/core/clean.lua")

local function check(condition, message)
  if not condition then
    io.stderr:write("FAIL oneroot: " .. message .. "\n")
    os.exit(1)
  end
end

local function decode(text)
  if type(text) ~= "string" then return text end
  local ok, value = pcall(json.decode, text)
  if not ok then return nil end
  return value
end

-- `host.exec` answers a JSON string, not a table (docs/HOST.md).
local function run(command)
  local answer = decode(host.exec(command, ""))
  check(type(answer) == "table", "host.exec answered no table for: " .. command)
  return answer
end

local root = paths.data()
check(type(root) == "string" and root ~= "", "the node must have a state root")
check(host.disk ~= nil, "this host has no host.disk(): the one root is not wired")

-- ---- 1. the child process sees TMPDIR inside the root, and writes there ---------------------------
local seen = run('printf %s "$TMPDIR"')
local tmpdir = seen.stdout or ""
check(tmpdir ~= "", "a child process saw no TMPDIR at all")
local normalise = function(text) return (tostring(text):gsub("\\", "/"):gsub("/+$", "")) end
check(normalise(tmpdir) == normalise(root .. "/tmp"),
  "a child's TMPDIR must be the root's tmp/, saw " .. tmpdir .. " for root " .. root)
local wrote = run('printf oneroot > "$TMPDIR/oneroot-child.txt" && printf %s "$TMPDIR/oneroot-child.txt"')
local written = (wrote.stdout or ""):gsub("%s+$", "")
check(written ~= "", "the child did not report where it wrote")
check(normalise(written) == normalise(root .. "/tmp/oneroot-child.txt"),
  "a child's scratch file must land under the root, saw " .. written)
check(host.read_file(written) == "oneroot", "the file the child wrote must be readable under the root")

-- ---- 2. status: the root, its disk, the cap, and the last clean -----------------------------------
local status = decode(host.disk("status", "{}"))
check(type(status) == "table" and status.ok == true, "host.disk status must answer a table")
check(normalise(status.root) == normalise(root), "status must name this node's root, saw " .. tostring(status.root))
check(tonumber(status.bytes) and tonumber(status.bytes) > 0, "status must measure the root's size")
check(tonumber(status.cap_percent) == 85, "the default cap is 85%, saw " .. tostring(status.cap_percent))
check(tonumber(status.days) == 7, "the default retention is 7 days, saw " .. tostring(status.days))
check(status.disk == nil or tonumber(status.disk.used_percent) ~= nil,
  "a measurable filesystem reports its usage; an unmeasurable one says so")
local line = clean.status_line()
check(type(line) == "string" and line:find("disk", 1, true) ~= nil and line:find("last clean", 1, true) ~= nil,
  "the `wa status` root line must carry the disk and the last clean, saw: " .. tostring(line))

-- ---- 3. `wa clean`: a dry run frees nothing, the real run frees and reports it ---------------------
local old = root .. "/tmp/oneroot-old.txt"
run('mkdir -p "' .. root .. '/tmp" && printf xxxxxxxx > "' .. old .. '"')
run('touch -d "10 days ago" "' .. old .. '"')
local dry = decode(host.disk("clean", json.encode({ dry_run = true, days = 7 })))
check(type(dry) == "table" and dry.ok == true, "a dry run must answer a table")
check(dry.dry_run == true, "a dry run must say it was a dry run")
check((tonumber(dry.freed_bytes) or -1) == 0, "a dry run must free nothing")
check(tonumber(dry.would_free_bytes) >= 8, "a dry run must still report the bytes it would free")
check(host.read_file(old) ~= nil, "a dry run must delete nothing")

local real = decode(host.disk("clean", json.encode({ days = 7 })))
check(type(real) == "table" and real.ok == true, "a real clean must answer a table")
check(tonumber(real.freed_bytes) >= 8, "a real clean must report what it freed, saw " .. tostring(real.freed_bytes))
check(host.read_file(old) == nil, "a temp file past retention must be gone")
check(host.read_file(root .. "/clean/last.json") ~= nil, "a real clean must record what it freed for `wa status`")

-- ---- 4. pins: a pinned path survives; a pin outside the root is refused by name -------------------
local keep = root .. "/tmp/oneroot-pinned"
run('mkdir -p "' .. keep .. '" && printf pinned > "' .. keep .. '/data.txt"')
run('touch -d "30 days ago" "' .. keep .. '/data.txt"')
local pinned = decode(host.disk("pin", json.encode({ path = "tmp/oneroot-pinned" })))
check(type(pinned) == "table" and pinned.ok == true, "a pin inside the root must be accepted")
local after_pin = decode(host.disk("clean", json.encode({ days = 1 })))
check(type(after_pin) == "table" and after_pin.ok == true, "clean must still answer with a pin present")
check(host.read_file(keep .. "/data.txt") == "pinned", "a pinned path is never deleted, whatever its age")
local refused_pin = decode(host.disk("pin", json.encode({ path = "../../etc" })))
check(type(refused_pin) == "table" and refused_pin.ok == false,
  "a pin outside the root must be refused")
check(tostring(refused_pin.error):find("outside_root", 1, true) ~= nil
  or tostring(refused_pin.error):find("pin_refused", 1, true) ~= nil,
  "a refusal outside the root must name itself, saw " .. tostring(refused_pin.error))
local unpinned = decode(host.disk("unpin", json.encode({ path = "tmp/oneroot-pinned" })))
check(type(unpinned) == "table" and unpinned.ok == true, "a pin can be released")

-- ---- 5. the cap refuses new heavy work by name ----------------------------------------------------
-- A child node of its own, because the cap is read when the node starts and a running process's
-- environment is not something this test may rewrite underneath it. `WASM_AGENT_DISK_CAP=1` on a
-- filesystem that is already more than 1 % full is the trigger; the answer must be the named refusal.
local info = decode(host.runtime_info()) or {}
local binary = info.binary_path
check(type(binary) == "string" and binary ~= "", "the running node must name its own binary")
local home = root .. "/tmp/oneroot-cap-home"
local script = root .. "/tmp/oneroot-cap.lua"
host.write_file(script, [[
local json = dofile("lua/vendor/json.lua")
-- A capability answers a JSON string, not a Lua table (the same contract `host.exec` has); decoding it
-- here is what makes the child's answer readable by the parent as one object.
print(json.encode({ guard = json.decode(host.disk("guard", json.encode({ trigger = "build" }))) }))
]])
local function child(cap)
  local command = string.format(
    'WASM_AGENT_HOME="%s" WASM_AGENT_DISK_CAP=%s WA_SCRIPT="%s" "%s" --db "%s/cap.db" 2>&1',
    home, cap, script, binary, home .. "/.wasm-agent")
  return run(command)
end
local under = child(100)
local under_answer = decode((under.stdout or ""):match("{.*}"))
check(type(under_answer) == "table" and type(under_answer.guard) == "table",
  "a node under its cap must answer the guard: " .. tostring(under.stdout) .. tostring(under.stderr))
check(under_answer.guard.ok == true and under_answer.guard.cleaned == false,
  "under the cap the guard admits the work and cleans nothing")
local over = child(1)
local over_text = tostring(over.stdout) .. tostring(over.stderr)
check(over_text:find("disk_cap", 1, true) ~= nil,
  "past the cap the node must refuse new heavy work by name (disk_cap), saw: " .. over_text)

-- ---- 6. the command itself: `wa clean --dry-run` --------------------------------------------------
local cli = run(string.format('env -u WA_SCRIPT WASM_AGENT_HOME="%s" "%s" clean --dry-run 2>&1', home, binary))
local cli_text = tostring(cli.stdout)
check(cli_text:find("dry run", 1, true) ~= nil,
  "`wa clean --dry-run` must say it deleted nothing, saw: " .. cli_text)
check(cli_text:find("wa clean", 1, true) == nil or cli_text:find("unknown command", 1, true) == nil,
  "`wa clean` must be a known command")

-- ---- 6. the one build root: a child per tree, named the same way in Rust and in build-target.sh ----
-- ONE FLAT shared `CARGO_TARGET_DIR` for every tree on a node was reproduced on this node on 13/11 and is
-- WRONG: two checkouts of one workspace give a member the same metadata hash, so the second tree's
-- `libbase` overwrote the first's and the first tree's binary printed the other tree's value
-- (scripts/test-onebuild.mjs keeps that measurement). So the node has ONE build root,
-- `<root>/build/target`, with ONE CHILD PER TREE inside it - one directory to own, one `wa clean`, one
-- cap, and no artifact crossing a tree. The two programs that must agree on a child's name are the Rust
-- side (`host.disk("island", ...)`) and `scripts/lib/build-target.sh`. This is the check that they do.
-- It also pins the refusal: the node sets no CARGO_TARGET_DIR for an ordinary shell, because a
-- `cd other-tree && cargo build` would compile one tree into another tree's build dir.
local iso = decode(host.disk("island", json.encode({ path = root })))
check(type(iso) == "table" and iso.ok == true, "host.disk island must answer the build dir for a tree")
check(normalise(iso.target):find(normalise(root .. "/build/target/"), 1, true) == 1,
  "every build dir lives under the root's one build root (build/target/), got " .. tostring(iso.target))
check(normalise(iso.island) == normalise(iso.target),
  "the island IS the cargo dir now, got " .. tostring(iso.island) .. " vs " .. tostring(iso.target))
local name = tostring(iso.target):match("([^/]+)$") or ""
local repo = os.getenv("WASM_AGENT_LUA_ROOT") or "."
local expected = run(string.format('bash "%s/scripts/lib/build-target.sh" target "%s"', repo, tostring(iso.tree)))
local expected_name = tostring(expected.stdout):match("([^/]+)$") or ""
check(name == expected_name,
  "the build dir's name must match build-target.sh: node=" .. name .. " script=" .. tostring(expected.stdout))
local plain = run('printf %s "${CARGO_TARGET_DIR:-unset}"')
check(tostring(plain.stdout) == "unset" or not tostring(plain.stdout):find(normalise(root), 1, true),
  "an ordinary shell must not be handed a build dir, got " .. tostring(plain.stdout))
-- A tree that goes takes its build output with it, with the name the build itself used: `wa clean`
-- removes a worktree and its island in one decision, and a released session worktree asks for the same.
os.execute(string.format('mkdir -p "%s/release-marker"', normalise(iso.target) .. "/wa-island-probe"))
local forgot = decode(host.disk("forget", json.encode({ path = iso.tree })))
check(type(forgot) == "table" and forgot.ok == true, "host.disk forget must answer for a tree")
local still = run(string.format('test -e "%s" && echo there || echo gone', normalise(iso.target)))
local still_text = (tostring(still.stdout):gsub("%s+$", ""))
check(still_text == "gone", "forget must delete the tree's build output, saw " .. still_text)

print("oneroot ok: child TMPDIR, status line, dry run, pins, guard, one build root, wa clean")
