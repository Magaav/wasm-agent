-- Operator approval of outgoing WhatsApp drafts (docs/APPROVE.md): the switch, the gate, the ballon's
-- three decisions, the queue that outlives a restart, and the evaluation record.
--
-- Hermetic: everything runs in this row's own WASM_AGENT_HOME, the account is this node (so the gate
-- is the real `whatsapp_approve` beside the real `whatsapp_send`), no component is started and
-- nothing is sent to anybody. The one thing that is NOT faked is the gate itself: the message has to
-- really be stopped before the queue, and the way to prove that is to ask the capability that would
-- have queued it.
--
-- What it pins:
--   * the default is OFF: a node nobody configured sends exactly as it did before this existed;
--   * ON stops the send BEFORE anything is queued - no job id, no queue, `state: "pending"`, a draft
--     handle - and the draft is on disk under the node's own root;
--   * per-chat rules: `only` gates the listed chats and no others, `except` the other way round;
--   * a send from a SECOND node (routed through `remote_call`) stops at the account node's gate, and
--     the caller's handle is the draft;
--   * a send made from inside a code-mode script (the nested dispatch, and the op the sandbox keeps)
--     is gated the same way, and its op can be cancelled - because nothing was sent yet;
--   * no terminal attached: the drafts wait, and they survive the process (read back through a fresh
--     module load, exactly like a restart);
--   * the three decisions and the words they answer with: sent unchanged (message id), sent with the
--     operator's edits (the final text), rejected (the note) - plus cancelled;
--   * the balloon: Enter / [e] / [r] as the page's own option links and keys;
--   * every decision lands in the evaluator's own store as one line - the chat as a digest, the draft
--     and the final text kept, the edit distance and the time to decide measured - and `wa eval
--     report`'s approval section is those numbers.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local whatsapp = dofile("lua/core/whatsapp.lua")
local approve = dofile("lua/core/approve.lua")

local checks, skipped = 0, 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function skip(label) skipped = skipped + 1; print("skip " .. label) end

-- `codemode_nested` is the in-script path: these are connector tools, so the call made from inside a
-- script is the one this row measures (`lua/core/codemode_policy.lua`).
local ctx = { user_id = "master", role = "master", codemode_nested = true }
local function call(name, args, local_ctx) return tools.dispatch(memory, name, args, "master", local_ctx or ctx) end

-- The chats this row uses. Both are exact JIDs of shapes the outbox sends to; neither exists.
local LAURA = "5511999999999@lid"
local BRUNO = "5511888888888@lid"

-- A writer that records instead of drawing: the balloon's own `for_view` is what a terminal gets, so
-- what is measured here is the text and the pages it would have drawn.
local function recorder()
  local io = { said = {}, shown = {} }
  io.say = function(lines)
    if type(lines) == "table" then
      for _, line in ipairs(lines) do io.said[#io.said + 1] = tostring(line) end
    else
      io.said[#io.said + 1] = tostring(lines)
    end
  end
  io.print = io.say
  io.show = function(pages) io.shown[#io.shown + 1] = pages; return { action = "printed" } end
  io.ask = function(page) io.asked = page; return io.answer end
  io.text = function() return table.concat(io.said, "\n") end
  return io
end

if type(host.whatsapp_send) ~= "function" or type(host.whatsapp_approve) ~= "function" then
  -- A binary that predates the gate cannot be tested for it. Reported in its own words, never as a
  -- pass: "ok" would then read as "the gate was exercised here".
  skip("the gate: this binary has no host.whatsapp_approve beside host.whatsapp_send")
  print(string.format("%d checks, %d skipped", checks, skipped))
  return
end

-- ---- the default: off ----------------------------------------------------------------------------
local status = approve.policy()
ok(status.ok == true, "the account node answers its policy: " .. json.encode(status))
ok(status.on == false, "a node nobody configured does NOT gate: today's behaviour is the default")

local before = call("mcp_whatsapp_send", { chat = LAURA, text = "primeira mensagem", wait_s = 0 })
ok(before.ok == true and type(before.id) == "number", "with approval off the send is queued as it always was: " .. json.encode(before))
ok(before.draft == nil, "and no draft is made")
ok(before.queue_state == "queued", "the job is the queue's: " .. tostring(before.queue_state))

-- ---- the switch ----------------------------------------------------------------------------------
local io = recorder()
approve.run("/approve on", io, ctx)
local on = approve.policy()
ok(on.on == true and on.mode == "all", "`/approve on` gates every chat: " .. json.encode(on))
ok(io.text():find("approval is ON", 1, true) ~= nil, "and says so to the operator: " .. io.text())

-- ---- the gate: nothing is queued ------------------------------------------------------------------
local gated = call("mcp_whatsapp_send", { chat = LAURA, text = "bom dia, tudo bem?", wait_s = 0 })
ok(gated.ok == true, "a gated send still answers ok: " .. json.encode(gated))
ok(gated.state == "pending", "and its state is pending, because nothing was sent")
ok(type(gated.draft) == "string" and gated.draft:sub(1, 2) == "d-", "the handle is the draft: " .. tostring(gated.draft))
ok(gated.id == nil, "NO job id: nothing was queued")
ok(gated.queue_state == nil, "and no queue state either")
ok(gated.approval == "waiting", "the answer says what it is waiting for")
ok(gated.effect == "none", "and that it had no effect")
ok(type(gated.resume) == "string" and gated.resume:find("draft", 1, true) ~= nil,
  "the resume names the draft, not a job: " .. tostring(gated.resume))
local first = gated.draft

-- The draft really is on the account node's own root, and it is the text that was asked for.
local listed = approve.list(ctx)
ok(listed.ok == true and #listed.drafts == 1, "the account node holds one draft: " .. json.encode(listed.waiting))
local record = listed.drafts[1]
ok(record.handle == first and record.chat == LAURA and record.text == "bom dia, tudo bem?",
  "the draft is the chat and the text: " .. json.encode(record))
ok(record.state == "pending", "and it is waiting")

-- ---- per-chat rules ------------------------------------------------------------------------------
io = recorder()
approve.run("/approve only " .. LAURA, io, ctx)
local only = approve.policy()
ok(only.on == true and only.mode == "only" and only.chats[1] == LAURA,
  "`only <jid>` gates that chat alone: " .. json.encode(only))
local excluded = call("mcp_whatsapp_send", { chat = BRUNO, text = "oi Bruno", wait_s = 0 })
ok(type(excluded.id) == "number" and excluded.draft == nil,
  "a chat the rule does not name goes out as written: " .. json.encode(excluded))
local included = call("mcp_whatsapp_send", { chat = LAURA, text = "outra coisa", wait_s = 0 })
ok(type(included.draft) == "string", "and the listed chat waits: " .. json.encode(included))

io = recorder()
approve.run("/approve except " .. BRUNO, io, ctx)
local except = approve.policy()
ok(except.mode == "except" and except.chats[1] == BRUNO, "`except <jid>` flips the list: " .. json.encode(except))
ok(type(call("mcp_whatsapp_send", { chat = BRUNO, text = "oi de novo", wait_s = 0 }).id) == "number",
  "the excepted chat goes out")
ok(type(call("mcp_whatsapp_send", { chat = LAURA, text = "e de novo", wait_s = 0 }).draft) == "string",
  "every other chat waits")

-- Back to gating everything, for the rest of this row.
io = recorder()
approve.run("/approve on", io, ctx)

-- A name that is not a chat is refused with the word, and the switch is left alone.
io = recorder()
approve.run("/approve only NaoExisteNinguem", io, ctx)
ok(approve.policy().mode == "all", "a name that resolves to no chat changes nothing: " .. io.text())

-- ---- a send from a SECOND node -------------------------------------------------------------------
-- The node that asks runs no `wa-whatsapp` component, so its capability answers absent and the send
-- is routed to the account node - which is this same scratch node's REAL gate, reached through the
-- remote call. `owner_catalog` is the fleet; `remote_call` is the hop.
local real_send, real_approve = host.whatsapp_send, host.whatsapp_approve
local asked = {}
host.whatsapp_send = function()
  return json.encode({ ok = false, error = "whatsapp_component_absent", owner = "acct-node", effect = "none" })
end
local routed_ctx = {
  user_id = "master", role = "master",
  owner_catalog = function()
    return { peers = { ["acct-node"] = { name = "acct-node", connectors = { { whatsapp_account = true } } } } }
  end,
  remote_call = function(node, name, args)
    asked[#asked + 1] = { node = node, name = name, args = args }
    if name == "mcp_whatsapp_approve" then return json.decode(real_approve(json.encode(args))) end
    -- The account node's own enqueue: the same capability the gate lives in.
    local copy = {}
    for key, value in pairs(args) do copy[key] = value end
    copy.wait_s = 0
    return json.decode(real_send(json.encode(copy)))
  end,
}
local second = whatsapp.call("mcp_whatsapp_send", { chat = LAURA, text = "da outra ponta", wait_s = 0 }, routed_ctx)
host.whatsapp_send = real_send
ok(asked[1] ~= nil and asked[1].node == "acct-node" and asked[1].name == "mcp_whatsapp_send",
  "a send from another node is routed to the node that holds the account")
ok(type(second.draft) == "string" and second.id == nil,
  "and stops at THAT node's gate: no job, a draft handle - " .. json.encode(second))
ok(second.asked_owner == "acct-node" or second.served_by == "acct-node",
  "the answer says which node holds the draft: " .. json.encode(second))
local routed_drafts = approve.list(ctx)
local routed_found = false
for _, draft in ipairs(routed_drafts.drafts) do if draft.handle == second.draft then routed_found = true end end
ok(routed_found, "the routed draft is on the account node, where the operator will find it")

-- ---- a send from inside a code-mode script -------------------------------------------------------
local pending = dofile("lua/core/codemode_pending.lua")
local nested = call("mcp_whatsapp_send", { chat = BRUNO, text = "de dentro de um script" })
ok(nested.jastate ~= "done", "a script's send does not claim to have sent")
ok(type(nested.draft) == "string", "a send made inside a code-mode script is gated the same way: " .. json.encode(nested))

-- A script calls with `wait_s: 0` and gets an OP for the draft: wait / pending / cancel.
local function dispatch(name, args) return call(name, args) end
local started = pending.EXECUTORS["mcp_whatsapp_send"].start(dispatch, {}, { chat = LAURA, text = "op de rascunho" }, "{}")
ok(type(started.op) == "string" and started.op:sub(1, 6) == "draft-",
  "the sandbox keeps an op for the draft, not for a job: " .. json.encode(started))
ok(started.draft ~= nil and started.id == nil, "and the op carries the draft handle")
local polls = 0
local polled, why = pending.EXECUTORS["mcp_whatsapp_send"].poll(dispatch, {}, { op = started.op, draft = started.draft, tool = "mcp_whatsapp_send" }, 0)
ok(polled ~= nil and polled.settled == false and why == "still_running",
  "pending reads the draft's state and says it is still waiting: " .. json.encode(polled))
local cancelled = pending.EXECUTORS["mcp_whatsapp_send"].cancel(dispatch, {}, { op = started.op, draft = started.draft, tool = "mcp_whatsapp_send" })
ok(cancelled.cancelled == true, "a DRAFT can be cancelled - nothing was sent yet: " .. json.encode(cancelled))
local after_cancel = approve.status(ctx, started.draft)
ok(after_cancel.draft.state == "cancelled", "and the draft says so: " .. json.encode(after_cancel.draft.state))
-- A queued message keeps the old answer, in its own words.
local still_sent = pending.EXECUTORS["mcp_whatsapp_send"].cancel(dispatch, {}, { op = "msg-1", id = 1, tool = "mcp_whatsapp_send" })
ok(still_sent.cancelled == false and still_sent.why == "a sent message stays sent",
  "a queued message is still not cancellable: " .. json.encode(still_sent))

-- ---- no terminal: the drafts wait, and they survive a restart ------------------------------------
-- Nothing above has decided the first draft, and the only reader was the capability itself.
local fresh = dofile("lua/core/approve.lua")  -- a fresh load: the same thing a restarted process does
local survived = fresh.list(ctx)
local found = false
for _, draft in ipairs(survived.drafts) do if draft.handle == first and draft.state == "pending" then found = true end end
ok(found, "a draft nobody decided is still pending after a restart, and was never sent")
io = recorder()
fresh.run("/approve list", io, ctx)
ok(io.shown[1] ~= nil, "/approve list shows the queue to a reader with no terminal")
ok(#survived.drafts >= 2, "every draft is in the queue: " .. tostring(#survived.drafts))

-- ---- the balloon: Enter / [e] / [r] --------------------------------------------------------------
local page = approve.page(survived.drafts[1], 1, #survived.drafts)
ok(page.options[1].label == "Send as is" and page.options[1].run == "/approve send " .. survived.drafts[1].handle,
  "Enter is the first option and it sends the draft as it is: " .. json.encode(page.options[1]))
ok(page.options[2].label == "Edit the text" and page.options[2].run == "/approve edit " .. survived.drafts[1].handle,
  "[e] edits it")
ok(page.options[3].label == "Reject with a note" and page.options[3].run == "/approve reject " .. survived.drafts[1].handle,
  "[r] rejects it with a note")
ok(page.keys.e == 2 and page.keys.r == 3, "the letters are on the page, and only there")
ok(table.concat(page.lines, "\n"):find(LAURA, 1, true) ~= nil, "the page names the chat by its JID")
ok(table.concat(page.lines, "\n"):find("bom dia", 1, true) ~= nil, "and shows the text that would be sent")
ok(approve.edit_page(survived.drafts[1]).value == survived.drafts[1].text,
  "the edit page starts with the draft in its field, so it is an edit and not a retype")
ok(approve.link("veja https://exemplo.com/a?b=1 agora") == "https://exemplo.com/a?b=1", "a link is previewed")
ok(approve.link("sem link") == nil, "and a text without one says nothing")

-- ---- send as it is: the message id comes back through the handle ---------------------------------
local target = survived.drafts[1]
io = recorder()
local decided = approve.run("/approve send " .. target.handle, io, ctx)
ok(decided.ok == true, "the operator sends it: " .. io.text())
local settled = approve.status(ctx, target.handle)
ok(settled.draft.state == "sent", "the draft is decided and sent: " .. tostring(settled.draft.state))
ok(settled.draft.outcome == "unchanged", "and says the operator changed nothing")
ok(type(settled.draft.job) == "number", "the send became a job on the outbox: " .. tostring(settled.draft.job))
ok(settled.draft.final == target.text, "the text that was sent is the draft's own")
-- The same call again is a refusal, not a second message.
local twice = approve.decide(ctx, target.handle, "send")
ok(twice.ok == false and twice.error == "whatsapp_approve_already_decided",
  "a decided draft cannot be decided twice: " .. json.encode(twice.error))

-- The outcome the agent reads, with a message id: the wait reads a draft whose job came back.
local done = whatsapp.settle_draft(target.handle, 0,
  function() return { ok = true, draft = { handle = target.handle, state = "sent", outcome = "unchanged",
    job = 7, message_id = "3EB0UNCHANGED", chat = LAURA, final = target.text } } end,
  { sleep = function() end })
ok(done.ok == true and done.state == "done" and done.outcome == "unchanged", "unchanged settles as done: " .. json.encode(done))
ok(done.message_id == "3EB0UNCHANGED", "with the message id WhatsApp gave it")
ok(done.draft == target.handle, "and the handle the agent was holding")

-- ---- edit: the operator's text is what is sent ---------------------------------------------------
local to_edit = call("mcp_whatsapp_send", { chat = LAURA, text = "texto que eu escrevi", wait_s = 0 }).draft
io = recorder()
io.answer = "texto que o operador escreveu"
local edited_line = approve.run("/approve edit " .. to_edit, io, ctx)
ok(edited_line.ok == true, "the edit is accepted: " .. io.text())
local edited = approve.status(ctx, to_edit).draft
ok(edited.outcome == "edited", "the decision is an edit: " .. tostring(edited.outcome))
ok(edited.final == "texto que o operador escreveu", "and the final text is the operator's: " .. tostring(edited.final))
ok(edited.text == "texto que eu escrevi", "the draft it came from is kept as it was")
-- What reached the queue is the EDITED text, proved by the queue's own dedupe key: the same chat
-- with the final text is the same job; with the original text it is a different one.
local same_as_final = json.decode(host.whatsapp_send(json.encode({ chat = LAURA, text = "texto que o operador escreveu" })))
local same_as_draft = json.decode(host.whatsapp_send(json.encode({ chat = LAURA, text = "texto que eu escrevi" })))
ok(same_as_final.id == edited.job, "the queue holds the OPERATOR's text under the draft's job: " .. json.encode({ queued = same_as_final.id, job = edited.job }))
ok(same_as_draft.id ~= edited.job, "and never the draft's own text under it")
local edited_out = whatsapp.settle_draft(to_edit, 0,
  function() return { ok = true, draft = { handle = to_edit, state = "sent", outcome = "edited", job = 8,
    message_id = "3EB0EDITED", chat = LAURA, final = "texto que o operador escreveu" } } end,
  { sleep = function() end })
ok(edited_out.state == "done" and edited_out.outcome == "edited", "an edited send settles as done: " .. json.encode(edited_out))
ok(edited_out.text == "texto que o operador escreveu", "and the agent is told the final text")
ok(edited_out.note:find("edited", 1, true) ~= nil, "with a sentence saying so: " .. tostring(edited_out.note))

-- ---- reject: a note, and nothing sent ------------------------------------------------------------
local to_reject = call("mcp_whatsapp_send", { chat = BRUNO, text = "muito formal, nao", wait_s = 0 }).draft
io = recorder()
io.answer = "fala como a gente fala"
local rejected = approve.run("/approve reject " .. to_reject, io, ctx)
ok(rejected.ok == true, "the rejection is accepted: " .. io.text())
local rejection = approve.status(ctx, to_reject).draft
ok(rejection.state == "rejected" and rejection.outcome == "rejected", "the draft is rejected: " .. tostring(rejection.state))
ok(rejection.note == "fala como a gente fala", "with the operator's note kept: " .. tostring(rejection.note))
ok(rejection.job == nil, "and no job was ever written")
-- The agent's handle settles as rejected, carrying the note, through the same call it used to wait.
local answer = whatsapp.call("mcp_whatsapp_send", { draft = to_reject, wait_s = 0 }, ctx)
ok(answer.ok == true and answer.state == "rejected", "the pending handle settles as rejected: " .. json.encode(answer))
ok(answer.note == "fala como a gente fala", "and hands the note back to the agent")
ok(answer.message_id == nil, "rejected claims no message id")

-- A reject without a note is allowed, and says what happened.
local to_reject_bare = call("mcp_whatsapp_send", { chat = BRUNO, text = "sem nota", wait_s = 0 }).draft
approve.decide(ctx, to_reject_bare, "reject")
local bare = approve.status(ctx, to_reject_bare).draft
ok(bare.state == "rejected" and bare.note == nil, "a rejection without a note is a rejection: " .. json.encode(bare.state))

-- ---- a wait that is not decided yet says pending, and never sends --------------------------------
local still_waiting = call("mcp_whatsapp_send", { chat = LAURA, text = "ainda esperando", wait_s = 0 }).draft
local waiting = whatsapp.call("mcp_whatsapp_send", { draft = still_waiting, wait_s = 0 }, ctx)
ok(waiting.state == "pending" and waiting.draft == still_waiting, "an undecided draft answers pending: " .. json.encode(waiting))
ok(waiting.approval == "waiting" and waiting.id == nil, "with no job id anywhere in it")
ok(type(waiting.resume) == "string" and waiting.resume:find(still_waiting, 1, true) ~= nil,
  "and the resume names the draft: " .. tostring(waiting.resume))

-- ---- the evaluation record -----------------------------------------------------------------------
local decisions = approve.records_path()
local text = host.read_file(decisions) or ""
ok(text ~= "", "every decision is one line in the evaluator's own store: " .. decisions)
local rows = 0
for line in text:gmatch("[^\n]+") do
  local decoded = json.decode(line)
  rows = rows + 1
  ok(decoded.chat_hash ~= nil and #decoded.chat_hash == 64, "the chat is recorded as a digest: " .. line)
  ok(decoded.outcome ~= nil and decoded.edit_distance ~= nil, "with what the operator did and how far they moved it")
  ok(decoded.decided_after_ms ~= nil, "and how long the decision took")
end
ok(rows >= 4, "one line per decision (" .. rows .. ")")
ok(text:find(LAURA, 1, true) == nil, "the chat's JID is NOT in the record - a digest, never the address")
ok(text:find("texto que o operador escreveu", 1, true) ~= nil, "but the final text is: that is the evidence")
local edit_row
for line in text:gmatch("[^\n]+") do
  local decoded = json.decode(line)
  if decoded.outcome == "edited" then edit_row = decoded end
end
ok(edit_row ~= nil, "the edited decision is there")
ok(edit_row.edit_distance == approve.edit_distance("texto que eu escrevi", "texto que o operador escreveu"),
  "and its distance is the distance between the two texts: " .. tostring(edit_row and edit_row.edit_distance))
ok(approve.edit_distance("abc", "abc") == 0, "an untouched text is zero characters away")
ok(approve.edit_distance("abc", "abd") == 1, "one character replaced is one")
ok(approve.edit_distance("", "abc") == 3, "and an empty one is three")

local report = approve.report()
ok(report.ok == true and report.total >= 4, "wa eval report's approval section counts them: " .. tostring(report.total))
local report_text = table.concat(report.lines, "\n")
ok(report_text:find("unchanged", 1, true) ~= nil and report_text:find("edited", 1, true) ~= nil,
  "per chat: unchanged, edited and rejected")
ok(report_text:find("median edit", 1, true) ~= nil, "and the median edit size: " .. report_text)

-- ---- off again: today's behaviour returns --------------------------------------------------------
io = recorder()
approve.run("/approve off", io, ctx)
ok(approve.policy().on == false, "/approve off is off")
ok(io.text():find("approval is OFF", 1, true) ~= nil, "and says so: " .. io.text())
local free = call("mcp_whatsapp_send", { chat = LAURA, text = "voltou ao normal", wait_s = 0 })
ok(type(free.id) == "number" and free.draft == nil, "a send is a job again: " .. json.encode(free))

-- ---- the status page a reader sees ---------------------------------------------------------------
io = recorder()
approve.run("/approve", io, ctx)
ok(io.shown[1] ~= nil, "/approve alone draws the status page")
local page_text = table.concat(io.shown[1][1].lines, "\n")
ok(page_text:find("approval is OFF", 1, true) ~= nil, "which starts with the switch: " .. page_text)
ok(page_text:find("off: every send goes out as written", 1, true) ~= nil, "and says what off means")

print(string.format("%d checks, %d skipped", checks, skipped))
