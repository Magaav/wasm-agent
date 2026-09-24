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
M.usage = "usage: wa chat [--continue | --session <id>] [prompt]"
M.sessions = {
  { "(default)", "start a new session" },
  { "--continue, -c", "continue the most recent session" },
  { "--session <id>", "continue exactly that session (see: wa sessions)" },
}

-- The `/` commands, in the order the help lists them. `alias` holds a second spelling the REPL
-- accepts and the parity check therefore also requires an arm for.
M.commands = {
  { name = "/session", usage = "/session", hint = "print the session id (resume with --session)" },
  {
    name = "/new",
    usage = "/new",
    hint = "start a new session: the next turn lands in an empty session, the one you left is untouched",
  },
  { name = "/remember", usage = "/remember <text>", hint = "store a memory" },
  { name = "/recall", usage = "/recall <query>", hint = "search memories" },
  { name = "/memories", usage = "/memories", hint = "list recent memories" },
  { name = "/search", usage = "/search <query>", hint = "search the message ledger" },
  { name = "/conversation", usage = "/conversation <id>", hint = "read a conversation" },
  { name = "/stats", usage = "/stats", hint = "database counts" },
  { name = "/console", usage = "/console", hint = "toggle the console: every event and a tool's whole output, unclipped" },
  { name = "/update", usage = "/update", hint = "install the newest build in this node's tree (the sentinel does it, once idle)" },
  { name = "/merge", usage = "/merge", hint = "act as git orchestrator: merge every open branch into main, gate, push, sync" },
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
    lines[#lines + 1] = string.format("  %-" .. width .. "s%s", row[1], row[2])
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "commands:"
  for _, row in ipairs(M.commands) do
    lines[#lines + 1] = string.format("  %-" .. width .. "s%s", row.usage, row.hint)
  end
  lines[#lines + 1] = "anything else is sent to the model."
  return table.concat(lines, "\n")
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
      "\n  resume it with `wa chat --session %s`", previous, previous)
  end
  return message
end

return M
