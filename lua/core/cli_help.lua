-- `wa <verb> --help` IS A QUESTION, AND A QUESTION RUNS NOTHING.
--
-- MEASURED 23/11 09:30Z (Fable), and again by this mission in a scratch home: `wa update --help` ran a LOCAL
-- UPDATE. It answered with the update's own report ("no sentinel watcher ownership was verified, so nothing can
-- safely accept this deploy: the request was not queued") and exit 1 - a refusal that reads like a bug in the
-- guard rather than the answer to a question - and it only failed to install anything because the runtime check
-- refused first on that machine. `wa land --help`, `wa release --help`, `wa session park --help` and every
-- other acting verb had the same shape: the flag travelled into the verb as an argument, and the verb acted.
--
-- WHY IT MATTERS MORE THAN IT LOOKS. A model or a person asking "what does this do" is exactly the caller who
-- must be able to ask before acting; here the safest-looking question was the one that deployed.
--
-- WHAT THIS FILE IS, and is not:
--   * it is the ONE list of the verbs that CHANGE something a person would have to undo by hand (a node's
--     install, the public channel, the fleet's membership, a session's schedule, a queued turn, the disk), with
--     the usage lines that answer for each of them;
--   * it is checked ABOVE the dispatch (lua/core/init.lua), so a verb's own body never sees the flag;
--   * it is NOT a second help text for a verb that already answers `--help` itself: those are listed in
--     M.DELEGATES and keep their own, more detailed words. `wa update <node> --help` is the measured case
--     (lua/core/remote_update.lua prints ten lines and runs nothing); `wa update --help` has no such branch and
--     is what this file exists for;
--   * a read-only verb (status, nodes, watch, capabilities, sessions, paths, ...) is deliberately NOT listed:
--     asking it for help already runs nothing, so a guard there would only be a second place to keep in step.
--
-- A verb added to the CLI that acts belongs here, and scripts/test-cli-help.sh enumerates M.ACTING so the list
-- is a thing a gate reads, not a habit.
local M = {}

-- The verbs that act, in the order `wa help` reads, each with the lines that answer for it. "usage:" first, so a
-- reader (and the row) can tell an answer from an execution.
M.ACTING = {
  { verb = "update", lines = {
    "usage: wa update [--check]   update THIS node (tree: the Sentinel deploy; release: the verified bundle)",
    "       wa update <node> [--commit <sha>] [--binary|--tree|--release] [--reason <text>] [--json]",
    "       wa update <node> --status | --rollback | --to <sha> | --pin | --unpin",
    "  --check is read-only: it says whether this node is behind what an update would install" } },
  { verb = "land", lines = {
    "usage: wa land --ready | --branches a,b [--dry-run] [--no-deploy]   the landing pipeline, as one machine",
    "       wa land --resume | status [--run <id>] | ready <branch> <sha>   continue, read, or record a READY line",
    "  it merges, gates, pushes, moves main, publishes, deploys and publishes the public channel" } },
  { verb = "release", lines = {
    "usage: wa release cut --run <id> [--resume] [--until <step>] [--no-deploy] [--signer local|<node>]",
    "       wa release trust-key ... --node <peer>   another node's trust set",
    "  a release writes a commit on main (the public channel's index) and it cannot be undone quietly" } },
  { verb = "clean", lines = {
    "usage: wa clean [--dry-run] [--days N] [--pin <path>] [--cap <percent>] [--status]",
    "  reclaims this node's one build root: landed worktrees, old operations/logs/temp, and the cap" } },
  { verb = "session", lines = {
    "usage: wa session park <id> [--reason <text>] [--mission <name>]   hold a session's schedule",
    "       wa session release <id> | status [<id>]",
    "       wa session start <node> --prompt <text> [--cwd <dir>]   start a session on another node" } },
  { verb = "steer", lines = {
    "usage: wa steer <session> \"<note>\" [--status]   queue a note for a session whose run is in flight" } },
  { verb = "bind", lines = {
    "usage: wa bind [service|status|renew|run] | unbind | nodes pending | accept <pairing-code>",
    "  a binding is a pairing this node accepts and acts on; it is written where the runtime reads it" } },
  { verb = "unbind", lines = { "usage: wa unbind [service|status]   stop acting on a binding this node holds" } },
  { verb = "accept", lines = { "usage: wa accept <pairing-code>   accept a pending pairing request" } },
  { verb = "promote", lines = { "usage: wa promote <node>   confirm a node of this network (administrator)" } },
  { verb = "demote", lines = { "usage: wa demote <node>   withdraw a node's confirmed place (administrator)" } },
  { verb = "revoke", lines = { "usage: wa revoke <node>   remove a node's access (administrator)" } },
  { verb = "network", lines = {
    "usage: wa network role <node-id> master|guest | forget <node-id> | remove <node-id> | approve <node-id>",
    "  administrator-controlled changes to who this network is" } },
  { verb = "fleet", lines = {
    "usage: wa fleet push-roster <node> [--replace-key <hex>]   install this fleet's roster on a node, then verify it" } },
  { verb = "approve", lines = {
    "usage: wa approve [on|off|status|list|only|except|send|edit|reject|cancel]   the gate on outgoing drafts",
    "  send/reject/edit decide a real outgoing message" } },
  { verb = "call", lines = { "usage: wa call <node> <capability> [args-json]   run work on another node" } },
  { verb = "whatsapp", lines = {
    "usage: wa whatsapp archive list|cut|restore|unload|push|expire [YYYY-MM]   the index's monthly archives" } },
  { verb = "services", lines = {
    "usage: wa services list|status|start|stop|enable|disable <name>   service components, no turn required" } },
  { verb = "eval", lines = {
    "usage: wa eval capture|list|run|report|verdict|reviewer   freeze real tasks, replay, review, read metrics" } },
  { verb = "mission", lines = {
    "usage: wa mission launch <name> <base> | start <name> | resume <name> [--msg <text>] | status [name]",
    "       wa mission stop <name> | amend <name> <file> | preflight <name>",
    "  the mission loop: a worker, its branch, its gate" } },
  { verb = "backup", lines = { "usage: wa backup [--to <dir>] | list   snapshot every store with its manifest" } },
  { verb = "restore", lines = { "usage: wa restore --from <dir>   put a snapshot back after re-checking every byte" } },
  { verb = "setup", lines = { "usage: wa setup fonts [--undo]   install wa's two faces for this user" } },
  { verb = "init", lines = { "usage: wa init [--db <path>]   initialise this node's database" } },
  { verb = "remember", lines = { "usage: wa remember <text>   store a fact in this node's memory" } },
  { verb = "forget", lines = { "usage: wa forget <id>   remove a memory by id" } },
}

-- A verb whose OWN dispatch already answers --help without acting. The shape of the arguments decides, because
-- the two forms are different commands: `wa update <node> --help` is lua/core/remote_update.lua's detailed help
-- (six usage lines and its flag list), `wa update --help` reaches the local updater, which is why this file
-- catches it. A verb that grows a help of its own adds a predicate here and keeps its words.
M.DELEGATES = {
  update = function(args)
    local second = tostring((args or {})[2] or "")
    return second ~= "" and second:sub(1, 1) ~= "-"
  end,
  -- `wa release <sub>` is a table of subcommands whose ACTING one is `cut`; every other form is answered by the
  -- binary's own release CLI (rust/wa-host/src/release.rs, `wa release verify` / `wa release trust-key`), which
  -- prints its usage and runs nothing before the interpreter boots. So this file answers for `release cut --help`
  -- alone - the one form that would cut a release.
  release = function(args) return tostring((args or {})[2] or "") ~= "cut" end,
}

-- The verbs whose bare `--help` is answered by another layer that already had the words (the binary's release
-- CLI): the row drives them and holds them to the SHAPE (exit 0, a usage line, nothing else), not to this file's
-- text, which is the background for their acting form.
M.OWNS_HELP = { release = true }

local by_verb = {}
for _, entry in ipairs(M.ACTING) do by_verb[entry.verb] = entry end

-- Is this a question? <args> -> true when args[1] is a verb that ACTS and a --help/-h is asked of it, unless the
-- verb answers that flag itself for this shape of arguments.
function M.asked(args)
  if type(args) ~= "table" then return false end
  local verb = tostring(args[1] or "")
  if by_verb[verb] == nil then return false end
  local asked = false
  for index = 2, #args do
    local arg = tostring(args[index] or "")
    if arg == "--help" or arg == "-h" then asked = true break end
  end
  if not asked then return false end
  local delegate = M.DELEGATES[verb]
  if delegate and delegate(args) then return false end
  return true
end

-- The lines that answer for args[1], joined the way print() prints them.
function M.text(args)
  local entry = by_verb[tostring((args or {})[1] or "")]
  if entry == nil then return nil end
  return table.concat(entry.lines, "\n")
end

function M.verbs()
  local names = {}
  for _, entry in ipairs(M.ACTING) do names[#names + 1] = entry.verb end
  return names
end

return M
