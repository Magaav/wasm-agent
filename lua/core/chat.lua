-- Interactive `wa` chat: model + memory, with local slash commands.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local agentlib = dofile("lua/core/agent.lua")
-- Everything this REPL prints is captured by whatever launched it (a terminal,
-- an orchestrator, a test), so it all goes out through the redactor.
local redact = dofile("lua/core/redact.lua")

local M = {}

-- The CLI runs as one user on one node; sessions are keyed by both, so the same
-- machine can keep separate threads per user.
local USER, NODE = "master", ""

local HELP = [[usage: wa chat [--continue | --session <id>] [prompt]

sessions:
  (default)            start a new session
  --continue, -c       continue the most recent session
  --session <id>       continue exactly that session (see: wa sessions)

commands:
  /session             print the session id (resume with --session)
  /remember <text>     store a memory
  /recall <query>      search memories
  /memories            list recent memories
  /search <query>      search the message ledger
  /conversation <id>   read a conversation
  /stats               database counts
  /help                this help
  /exit                quit
anything else is sent to the model.]]

local function each(rows, render)
  if #rows == 0 then print("(empty)") return end
  for _, row in ipairs(rows) do print(render(row)) end
end

local function memory_line(row)
  local tags = (#row.tags > 0) and (" [" .. table.concat(row.tags, ", ") .. "]") or ""
  return string.format("%s  %s%s  %s", row.id, row.scope, tags, row.content)
end

-- Streaming printer. `wa chat` is launched as a TUI agent (Orca, or a
-- terminal), so output must appear as it is produced: a silent terminal looks
-- hung, and an orchestrator waiting for the terminal to go idle cannot tell the
-- difference between working and stuck.
local function printer(state)
  return function(event)
    local kind = event.type
    if kind == "delta" then
      io.write(event.text or "")
      io.flush()
      state.streamed = state.streamed + 1
    elseif kind == "tool" then
      io.write("\n  · " .. tostring(event.name or "?") .. "\n")
      io.flush()
    elseif kind == "tool_result" then
      -- Tool results are usually tables (bash returns {code, stdout, stderr});
      -- tostring would print "table: 0x..." and say nothing.
      local value = event.result
      local text = (type(value) == "table") and json.encode(value) or tostring(value or "")
      text = redact.text(text):gsub("%s+", " ")
      io.write("    " .. text:sub(1, 120) .. (#text > 120 and "…" or "") .. "\n")
      io.flush()
    elseif kind == "error" then
      io.write("\n  ! " .. redact.text(tostring(event.error or "error")) .. "\n")
      io.flush()
    end
  end
end

function M.run(argv)
  argv = argv or {}
  -- Session selection. A new thread is the default; `--continue` resumes the
  -- most recent one; `--session <id>` picks exactly that one. A bare word is the
  -- first prompt, so a launcher can start the agent with work already queued.
  local session_id, resume_last, prompt = nil, false, {}
  local index = 2
  while argv[index] do
    local arg = argv[index]
    if arg == "--session" then
      session_id = argv[index + 1]
      index = index + 2
    elseif arg == "--continue" or arg == "-c" then
      resume_last = true
      index = index + 1
    elseif arg == "--help" or arg == "-h" then
      print(HELP)
      return 0
    else
      prompt[#prompt + 1] = arg
      index = index + 1
    end
  end
  prompt = table.concat(prompt, " ")

  -- Which thread this process runs in. Conversational history is the transcript
  -- of that thread; remembered facts live in memory and are deliberately
  -- independent of it, so `--continue` never changes what `recall` finds.
  local session
  if session_id then
    if session_id == "" then
      print("  --session needs an id; list them with: wa sessions")
      return 2
    end
    session = memory.session(session_id)
    if not session then
      print("  no such session: " .. session_id)
      print("  list them with: wa sessions")
      return 2
    end
  elseif resume_last then
    session = memory.latest_session(USER, NODE)
    if not session then print("  nothing to continue; starting a new session") end
  end
  if not session then
    local id = memory.start_session(NODE, "chat", { user_id = USER, node_id = NODE, title = "chat" })
    session = memory.session(id) or { id = id }
  end

  local settings = provider.settings()
  local mode = provider.configured() and (settings.model .. " @ " .. settings.base_url)
    or "local mode (no model configured)"
  local state = { streamed = 0 }
  local agent = agentlib.new(session.id, printer(state), "master", USER, NODE)

  print("")
  print("  wasm-agent 0.1.0")
  print("  model    " .. mode)
  print("  memory   " .. (host.getenv("WASM_AGENT_DB") or "~/.wasm-agent/memory.db"))
  print("  session  " .. agent.session_id .. (resume_last and "  (continued)" or ""))
  -- The banner is the last place a user can be told before they type: a thread
  -- that was cut off mid-answer looks like one that is simply quiet, and the
  -- recovery below (the model is told in its context) is invisible from here.
  local session_state = memory.session_state(agent.session_id)
  if session_state and session_state.state == "unfinished" then
    print("  !        unfinished " .. session_state.detail)
    print("           recovering: wa resume --session " .. agent.session_id)
  end
  print("  /help for commands, /exit to quit")
  print("")

  local function turn(line)
    state.streamed = 0
    local ok, reply = pcall(agent.turn, agent, line)
    if not ok then
      print("\n  error: " .. redact.text(tostring(reply)))
    elseif state.streamed == 0 then
      -- Nothing streamed (an error before the first token, or a provider
      -- without streaming): print the reply so the turn is never silent.
      print(reply)
    else
      print("")
    end
  end

  if prompt ~= "" then turn(prompt) end

  while true do
    io.write("wa> ")
    io.flush()
    local line = io.read("*l")
    if line == nil then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- keep prompting
    elseif line == "/exit" or line == "/quit" then
      break
    elseif line == "/help" then
      print(HELP)
    elseif line == "/session" then
      print(agent.session_id)
    elseif line == "/stats" then
      print(json.encode(memory.stats()))
    elseif line == "/memories" then
      each(memory.memories(nil, 50), memory_line)
    elseif line:sub(1, 10) == "/remember " then
      print(memory.remember(line:sub(11)))
    elseif line:sub(1, 8) == "/recall " then
      each(memory.recall(line:sub(9), 10), memory_line)
    elseif line:sub(1, 8) == "/search " then
      each(memory.search_ledger(line:sub(9), nil, 20), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end)
    elseif line:sub(1, 14) == "/conversation " then
      each(memory.conversation(line:sub(15), 50), function(row)
        return string.format("%s  %s  %s", row.conversation_id, row.sender_id or "-", row.body)
      end)
    else
      turn(line)
    end
  end
  agent:close()
  return 0
end

return M
