-- The command surface of `wa chat`: how a session is chosen, and the `/` commands the REPL answers.
--
-- One list, read by three readers: the REPL's `/help`, the parity check
-- (`scripts/test-command-parity.cjs`) that fails when the window offers a command the CLI does not,
-- and whoever adds the next command. Before this the commands lived twice inside `chat.lua` - once as
-- prose in the help string, once as `elseif` arms - so a command could be listed without an arm or
-- armed without being listed, and the window's `/new` was absent from the CLI entirely with nothing
-- in the repo saying so. Two surfaces kept in step by memory is how *the* one they forget drifts.
--
-- A row is the name, the usage and the promise - not the behaviour. The arm that keeps the promise
-- stays in `lua/core/chat.lua`, beside the REPL it belongs to, and the parity check is what notices
-- when a row has no arm. Adding a command is therefore two edits (a row, an arm) and the check
-- refuses the change that makes only one.
--
-- The promises are deliberately narrow, and each says what the node can do to itself and nothing
-- more: `/new` moves the REPL, `/update` *queues* an install for the sentinel (a process cannot
-- replace itself while it is the process being replaced), and `/merge` is a brief rather than an
-- operation because the worktrees live outside this process. Nothing here deletes a transcript: the
-- ledger is append-only, so a command that removed history would make the record a claim it cannot
-- support.
local memory = dofile("lua/core/memory.lua")

local M = {}

-- The session-selecting flags, and the usage line above them. Kept here with the commands so
-- `M.help()` aligns the whole block once; the parser for them is in `chat.lua`, and the parity check
-- asserts every flag named below is a flag `chat.lua` actually accepts.
M.usage = "usage: wa [chat] [--continue | --resume <id> | --session <id>] [--once] [--dev <dir>] [prompt]"
M.sessions = {
  { "(default)", "start a new session" },
  { "--continue, -c", "continue the most recent thread with messages, its transcript printed again" },
  { "--resume <id>", "continue exactly that session, its transcript printed again (see: wa sessions)" },
  { "--session <id>", "the same as --resume" },
  { "--once, -p", "run this turn (and any lines on stdin) then exit with the run's status - what a stdin that is not a terminal already means, for a caller whose stdin is one" },
  { "--dev <dir>", "reload the UI and command layer from that checkout (the directory that contains lua/) at the next frame or command; the status bar says dev reload" },
}

-- Input modes: what the first character of a line does. Not `/` commands, so not in the slash menu or
-- the window's list; `chat.lua` handles them before the commands.
M.modes = {
  { "!<command>", "bash mode: run it here, show the output, keep it as context for the next turn (no model turn)" },
}

-- The `/` commands, in the order the help lists them. `alias` holds a second spelling the REPL
-- accepts and the parity check therefore also requires an arm for.
M.commands = {
  { name = "/session", usage = "/session", hint = "print the session id (resume with wa --resume <id>)" },
  { name = "/status", usage = "/status", hint = "this session's id, the model, and each provider's usage and limits" },
  { name = "/wakes", usage = "/wakes", hint = "list this session's pending self-wakes (next due, cadence, last error)" },
  { name = "/wake", usage = "/wake cancel <id>", hint = "cancel one pending self-wake" },
  { name = "/vault", usage = "/vault <name> <value>", hint = "store a key as <name>.key: the agent uses it by name, never sees it" },
  {
    name = "/new",
    usage = "/new",
    hint = "start a new session: the next turn lands in an empty session, the one you left is untouched",
  },
  { name = "/remember", usage = "/remember <text>", hint = "store a memory" },
  { name = "/recall", usage = "/recall <query>", hint = "search memories" },
  { name = "/memories", usage = "/memories", hint = "list recent memories" },
  {
    name = "/login",
    usage = "/login",
    hint = "sign in to a provider: ChatGPT by device code, or paste an API key (kept in wa-vault)",
  },
  { name = "/model", usage = "/model", hint = "pick the model from what the active provider serves" },
  { name = "/reasoning", usage = "/reasoning", alias = { "/thinking" }, hint = "set how much the model reasons (low, high, max...)" },
  { name = "/provider", usage = "/provider", hint = "pick the provider for the next turns" },
  { name = "/stats", usage = "/stats", hint = "database counts" },
  { name = "/console", usage = "/console", hint = "toggle the console: every event and a tool's whole output, unclipped" },
  {
    name = "/efficiency_report",
    usage = "/efficiency_report",
    hint = "deterministic cost/context report: token domination, KV cache, USD, and a readable prefix artifact",
  },
  { name = "/orchestration", usage = "/orchestration", alias = { "/ochestration" }, hint = "toggle native task routing on/off; workers merge and report, coordinator alone updates" },
  { name = "/update", usage = "/update", hint = "install the newest build in this node's tree (the sentinel does it, once idle); the footer shows 'Update available (<sha>)' when a newer release is published" },
  { name = "/merge", usage = "/merge", hint = "merge internal branches; leave open PR work for review" },
  { name = "/merge all", usage = "/merge all", hint = "include all open PRs after review and required checks" },
  { name = "/bind", usage = "/bind [service]", hint = "two-sided fabric consent; permanent asks for no expiry; status/renew/run stay local" },
  { name = "/unbind", usage = "/unbind", hint = "revoke remote access; retain local identity and history" },
  { name = "/nodes", usage = "/nodes [pending]", local_view = true, hint = "browse the cluster's nodes, or administrator pairing requests" },
  { name = "/accept", usage = "/accept <code>", hint = "confirm exact pairing request as network guest" },
  { name = "/promote", usage = "/promote <node>", hint = "confirm network master, never administrator" },
  { name = "/demote", usage = "/demote <node>", hint = "confirm network guest; preserve local CLI" },
  { name = "/revoke", usage = "/revoke <node>", hint = "confirm exact binding revocation" },
  { name = "/restart", usage = "/restart", hint = "restart wa into this session (also automatic when a new build is installed)" },
  {
    name = "/hooks",
    usage = "/hooks [reload]",
    hint = "list the active hook points and mods, and the last outcome; `reload` rereads the config files",
  },
  {
    name = "/approve",
    usage = "/approve [on|off]",
    hint = "approve outgoing WhatsApp drafts: the switch, the queue, and Enter / e / r to send, edit or reject",
    name = "/reload",
    usage = "/reload",
    hint = "live reload: which tree the UI comes from, what was swapped and what failed",
  },
  {
    name = "/mcp",
    usage = "/mcp [<key>] [on|off]",
    hint = "every MCP connector, here and from peers: state, tools, and the exact names the model is given; on/off changes one",
  },
  { name = "/help", usage = "/help", hint = "this help" },
  { name = "/exit", usage = "/exit", alias = { "/quit" }, hint = "quit" },
}

-- Where a hint starts. A fixed column, and wide enough for the longest row, so the list reads as a
-- table: a column that shifts with every long usage makes a one-command change a diff of every line.
-- A usage longer than the column pushes the hints right rather than running into them, and the parity
-- check refuses a row that wide so the help is never quietly unreadable.
M.COLUMN = 21

-- The help the REPL prints, generated from the rows above so a command cannot be documented without
-- being listed or listed without a promise.
function M.help()
  local width = M.COLUMN
  for _, row in ipairs(M.sessions) do width = math.max(width, #row[1]) end
  for _, row in ipairs(M.commands) do width = math.max(width, #row.usage) end
  local lines = { M.usage, "", "sessions:" }
  for _, row in ipairs(M.sessions) do
    lines[#lines + 1] = string.format("%-" .. width .. "s%s", row[1], row[2])
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "commands:"
  for _, row in ipairs(M.commands) do
    lines[#lines + 1] = string.format("%-" .. width .. "s%s", row.usage, row.hint)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "modes:"
  for _, row in ipairs(M.modes) do
    lines[#lines + 1] = string.format("%-" .. width .. "s%s", row[1], row[2])
  end
  lines[#lines + 1] = "anything else is sent to the model."
  return table.concat(lines, "\n")
end

-- What the editor's slash menu offers (`host.input_commands`): the same rows, with whether a command
-- takes arguments (so Tab completes it with a space rather than running it).
function M.menu()
  local list = {}
  for _, row in ipairs(M.commands) do
    list[#list + 1] = { name = row.name, args = row.usage ~= row.name, hint = row.hint }
  end
  return list
end

-- Every name this file promises, with its aliases: the list `chat.lua` must have an arm for.
function M.names()
  local names = {}
  for _, row in ipairs(M.commands) do
    names[#names + 1] = row.name
    for _, alias in ipairs(row.alias or {}) do names[#names + 1] = alias end
  end
  return names
end

-- The commands that are a read-only view rather than an operation (`local_view = true`).
--
-- The distinction is the whole point of `lua/core/local_views.lua`: a read-only view can be drawn by
-- the client from a snapshot while a run is in flight, and an operation cannot - it changes state,
-- so it keeps queuing behind the turn, which is correct. `/status` is the same class but has had its
-- own one-panel channel for longer (`host.status_snapshot`), so it is not published here.
function M.local_views()
  local names = {}
  for _, row in ipairs(M.commands) do
    if row.local_view then names[#names + 1] = row.name end
  end
  return names
end

-- `/new`: start an empty session, and leave the one being left exactly as it is.
--
-- The promise the window's `/new` makes is the promise here: the *next* turn lands in a new session,
-- and the previous one keeps its messages, its id and its place in the ledger. Nothing is deleted -
-- the ledger is append-only, so a command that removed a transcript would make the record a claim it
-- cannot support - and `memory.finish_session` is deliberately *not* called on the session being
-- left: "finished" is a statement about a conversation, and the CLI does not know this one is over.
-- The reader may come back to it with `wa chat --session <id>`.
--
-- Returns the new id and the sentence to print. The caller owns the REPL: moving its agent to the new
-- session is what makes the promise observable, and that belongs beside the loop it changes.
function M.new_session(opts)
  opts = opts or {}
  local node = opts.node or ""
  local id = memory.start_session(node, "chat", {
    user_id = opts.user or "master", node_id = node, title = "chat",
  })
  return id, M.started_notice(id, opts.previous)
end

-- Says which session the REPL moved to, and where the one it left still is. Both ids are printed in
-- full and both instructions are the CLI's own: a window prints a pointer to its engine view here,
-- and this prints a pointer to the two commands that resume a thread (`wa sessions`, `wa chat
-- --session <id>`), because a reader of one cannot use the other's.
function M.started_notice(id, previous)
  local message = string.format("  new session %s - the next turn lands in an empty session.", id)
  if previous and previous ~= "" then
    message = message .. string.format(
      "\n  the session you left (%s) is unchanged and still listed by `wa sessions`:" ..
      "\n  resume it with `wa --resume %s`", previous, previous)
  end
  return message
end

return M
