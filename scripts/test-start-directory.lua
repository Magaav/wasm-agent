-- The starting directory of a shell, through the real host.
--
-- A directory the caller recorded can be gone by the time the shell starts: a session worktree is
-- released, a deploy worktree is pruned, and the operation record keeps naming it. On unix the
-- shell then does not fail at the command, it fails *before* it - it prints `shell-init: error
-- retrieving current directory: getcwd: cannot access parent directories: No such file or
-- directory` and treats every relative path as unresolvable, so a call that would have worked
-- dies on the way in with an empty stdout and no reason. That is the peer failure this covers.
--
-- What must hold: the shell still runs the command (a), the result says the recorded directory was
-- not used and names the one that was (b), and a directory that exists is untouched (c). The
-- markers are read through a *relative* path, so \"it ran\" is evidence about the directory the
-- shell actually started in, not only about what the record claims.
--
-- Run with an isolated home and database, as scripts/test.sh does. Like the other gate scripts it
-- assumes the node's shell can run the fixtures (`cat`, `rm`), which is how every `bash` call is
-- executed on a node with Git Bash.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error(label) end
end
local home = paths.home()
local marker = "visible from the fallback directory"

-- (a) and (b): the recorded directory is deleted before the shell starts.
local recorded = home .. "/start-directory-recorded"
ok(host.write_file(recorded .. "/marker.txt", "recorded marker") == true,
  "fixture directory created with a marker in it")
-- A marker in the agent home proves *where* the shell ran, not only what the result says.
ok(host.write_file(home .. "/start-directory-marker.txt", marker) == true, "home marker created")
local removed = json.decode(host.exec("rm -rf '" .. recorded .. "'"))
ok(removed.ok == true, "fixture directory deleted: " .. json.encode(removed))
ok(json.decode(host.list_dir(recorded)).error ~= nil, "the directory really is gone")

local substituted = json.decode(host.exec("cat start-directory-marker.txt", recorded))
ok(substituted.ok == true and substituted.stdout == marker,
  "(a) the shell ran the command somewhere usable: " .. json.encode(substituted))
ok(substituted.cwd_requested == recorded,
  "(b) the result records the directory that was requested: " .. json.encode(substituted))
ok(type(substituted.cwd_substitution) == "table"
  and substituted.cwd_substitution.requested == recorded
  and substituted.cwd_substitution.used == home
  and substituted.cwd_substitution.reason == "recorded_starting_directory_missing",
  "(b) the result names the substitution: " .. json.encode(substituted.cwd_substitution))
ok(substituted.cwd == home,
  "(b) the recorded directory is not reported as the one that was used: " .. json.encode(substituted))
local cwd_note = tostring(substituted.cwd_note)
ok(cwd_note:find(recorded, 1, true) ~= nil and cwd_note:find(home, 1, true) ~= nil,
  "(b) the note names both directories: " .. cwd_note)

-- (c): a directory that exists is unchanged, and the shell really starts in it.
local kept = home .. "/start-directory-kept"
local kept_marker = "in the recorded directory"
ok(host.write_file(kept .. "/marker.txt", kept_marker) == true, "kept fixture created")
local same = json.decode(host.exec("cat marker.txt", kept))
ok(same.ok == true and same.stdout == kept_marker,
  "(c) the shell started in the directory it was given: " .. json.encode(same))
ok(same.cwd == kept and same.cwd_requested == kept,
  "(c) and the result reports that directory: " .. json.encode(same))
ok(same.cwd_substitution == nil and same.cwd_note == nil,
  "(c) an unchanged call claims no substitution: " .. json.encode(same))

-- The peer/remote shape: a capability call names no directory, so the shell inherits the node's
-- own. Reading this very script through a relative path is what proves the inheritance - that path
-- only resolves from the checkout the node is running in.
local own = json.decode(host.exec("cat scripts/test-start-directory.lua"))
ok(own.ok == true and tostring(own.stdout):find("start directory ok", 1, true) ~= nil,
  "an ordinary call still runs in the node's own directory: " .. json.encode(own))
ok(own.cwd == "" and own.cwd_requested == "" and own.cwd_substitution == nil and own.cwd_note == nil,
  "an ordinary call stays unchanged: " .. json.encode(own))

-- The same guarantee through `operation start`, which is the other way a shell is spawned.
local launch = json.decode(host.operation("start", json.encode({
  command = "cat start-directory-marker.txt", cwd = recorded })))
ok(tostring(launch.operation_id):find("^op%-") ~= nil, "the operation was admitted: " .. json.encode(launch))
local await = json.decode(host.operation("await", json.encode({ id = launch.operation_id, wait_for = "settled" })))
ok(await.ok == true and await.stdout == marker,
  "an explicitly started operation also runs in the fallback: " .. json.encode(await))
ok(await.cwd_requested == recorded and await.cwd_substitution ~= nil and await.cwd == home,
  "and its record states the substitution too: " .. json.encode(await))

json.decode(host.exec("rm -f '" .. home .. "/start-directory-marker.txt'"))
json.decode(host.exec("rm -rf '" .. kept .. "'"))
print("start directory ok (" .. checks .. " checks)")
