-- The operator-directed send on the Rust/WASI path: prepare -> approve -> send -> status, with the
-- signature, the approval digest, the exact scope and the one-dispatch rule. Hermetic: no phone, no
-- component; the send is the node's real outbox producer, so what is queued is real, and nothing
-- connects to WhatsApp because no component takes the job.
--
-- The same state machine ran in the Go connector (connectors/whatsapp/operator.go); the contract is
-- docs/WHATSAPP-OPERATOR-MANAGEMENT.md and the wire is docs/SERVICE-COMPONENTS.md ("the operator
-- send"). The gate this test cannot exercise without a component is the reply source and the echo
-- (`host.whatsapp_message` answers `..._slow` with no worker): those are covered by the component's
-- own tests (`outbox::dispatch_refusal`) and by the Phase 3 proof on a live account.
local json = dofile('lua/vendor/json.lua')
local operator = dofile('lua/core/whatsapp_operator.lua')

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error('WHATSAPP OPERATOR CHECK FAILED: ' .. label) end
end
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then error('WHATSAPP OPERATOR CHECK FAILED: ' .. label .. ' (got ' .. tostring(actual) .. ', want ' .. tostring(expected) .. ')') end
end

local home = assert(host.getenv('WASM_AGENT_HOME'), 'the runner provides a private home')
local dir = home .. '/operator'
local account = '5511000000000@s.whatsapp.net'
local chat = '5511999999999@s.whatsapp.net'
local token = string.rep('a', 64)

-- The three provisioned files: one authority config and two separate capability files. The directory
-- itself may not exist yet; host.write_file creates the parent (the node writes requests the same way).
ok(host.write_file(dir .. '/dispatch.token', token .. '\n'), 'dispatch capability written')
ok(host.write_file(dir .. '/approval.token', string.rep('b', 64)), 'approval capability written')
ok(host.write_file(dir .. '/operator-management-test.json', json.encode({
  kind = 'whatsapp-operator-v1', account = account, generation = 2,
  conversations = { chat }, dispatch_token_file = dir .. '/dispatch.token',
  approval_token_file = dir .. '/approval.token',
})), 'authority profile written')

local profiles = operator.profiles(dir)
ok(profiles.test ~= nil, 'the profile is discovered')
eq(profiles.test.account, account, 'the account is the one provisioned')
eq(profiles.test.conversations[1], chat, 'the exact chat is the one provisioned')

local function call(action, request)
  return operator.call({ action = action, profile = 'test', request = request }, dir)
end

-- ---- unknown profile and out-of-scope chat ------------------------------------------------------
eq(operator.call({ action = 'prepare', profile = 'none', request = { conversation_id = chat, body = 'oi' } }, dir).error,
  'operator_profile_unknown', 'an unknown profile is refused')
eq(call('prepare', { conversation_id = '5511888888888@s.whatsapp.net', body = 'oi' }).error,
  'operator_conversation_outside_profile', 'a chat the profile does not name is refused')
eq(call('prepare', { conversation_id = '5511999999999', body = 'oi' }).error,
  'operator_exact_scope_required', 'a bare number is not a chat')

-- ---- prepare: the signature, the digest, the exact body ------------------------------------------
local prepared = call('prepare', { conversation_id = chat, body = 'olá, tudo bem?' })
ok(prepared.ok == true, 'prepare succeeds')
eq(#prepared.intent_id, 64, 'the intent id is a sha256 hex')
eq(#prepared.approval_digest, 64, 'the approval digest is a sha256 hex')
eq(prepared.state, 'prepared', 'prepare stores a prepared intent')
eq(prepared.body, operator.SIGNATURE .. '\nolá, tudo bem?', 'the signature is composed at prepare')
ok(prepared.body:find(operator.SIGNATURE, 1, true) == 1, 'the signature is the first line')
eq(call('prepare', { conversation_id = chat, body = operator.SIGNATURE .. '\nolá, tudo bem?' }).intent_id,
  prepared.intent_id, 'a body already signed is the same intent, not a second signature')
eq(call('prepare', { conversation_id = chat, body = 'olá, tudo bem?' }).approval_digest,
  prepared.approval_digest, 'prepare is idempotent while the intent is fresh')

-- ---- approve: the exact binding and the separate capability -------------------------------------
eq(call('approve', { conversation_id = chat, body = 'olá, tudo bem?', intent_id = prepared.intent_id,
  approval_digest = string.rep('0', 64) }).error, 'operator_approval_binding_mismatch', 'a wrong digest is refused')
eq(call('approve', { conversation_id = chat, body = ('olá, tudo bem?'):gsub('olá', 'ola'), intent_id = prepared.intent_id,
  approval_digest = prepared.approval_digest }).error, 'operator_approval_binding_mismatch', 'changed text is refused')
local approved = call('approve', { conversation_id = chat, body = 'olá, tudo bem?', intent_id = prepared.intent_id,
  approval_digest = prepared.approval_digest })
ok(approved.ok == true, 'approve accepts the exact binding')
eq(approved.state, 'approved', 'approve stores approved')
ok(call('approve', { conversation_id = chat, body = 'olá, tudo bem?', intent_id = prepared.intent_id,
  approval_digest = prepared.approval_digest }).ok == true, 'approve is idempotent')

-- ---- send: one dispatch, a real queue job, and no second write ----------------------------------
local sent = call('send', { conversation_id = chat, intent_id = prepared.intent_id })
ok(sent.ok == true, 'send succeeds')
eq(sent.state, 'dispatched', 'send stores the durable dispatch intent')
ok(type(sent.job) == 'number' and sent.job > 0, 'the outbox producer returned the job id')
local again = call('send', { conversation_id = chat, intent_id = prepared.intent_id })
eq(again.job, sent.job, 'a repeated send returns the same job, never a second one')
eq(again.state, 'dispatched', 'the repeated send changes nothing')
local status = call('status', { conversation_id = chat, intent_id = prepared.intent_id })
eq(status.job, sent.job, 'status reads the same intent')
eq(status.state, 'dispatched', 'status reports the queued job (no component took it here)')
eq(call('prepare', { conversation_id = chat, body = 'olá, tudo bem?' }).intent_id, prepared.intent_id,
  'a dispatched intent is returned as it is, not re-prepared')

-- ---- a second, different text is its own intent -------------------------------------------------
local second = call('prepare', { conversation_id = chat, body = 'segunda mensagem' })
ok(second.intent_id ~= prepared.intent_id, 'a different text is a different intent')
-- The first intent is dispatched, so a newer prepare for the same chat refuses to open a second
-- dispatch window until the first is settled (the Go path's unknown-recipient guard).
eq(second.error, 'operator_unknown_recipient_intent_requires_reconciliation',
  'a second dispatch for the same chat waits for the first')

-- ---- bad values are words ------------------------------------------------------------------------
eq(call('prepare', { conversation_id = chat, body = '' }).error, 'operator_exact_text_required', 'empty text is refused')
eq(call('prepare', { conversation_id = chat, body = string.rep('x', 5000) }).error,
  'operator_text_invalid_or_too_large', 'text over the bound is refused')
eq(call('prepare', { conversation_id = chat, body = 'oi', reply_to = 'not an id' }).error,
  'operator_reply_to_invalid', 'a reply id with whitespace is refused')
eq(call('prepare', { conversation_id = chat, body = 'oi', mentions = { 'nope@example.com' } }).error,
  'operator_mention_list_invalid', 'a non-WhatsApp mention is refused')
eq(call('status', { conversation_id = chat, intent_id = 'short' }).error, 'operator_intent_id_required',
  'a status without an exact intent id is refused')

-- ---- a missing capability file is a provisioning refusal, not a send ----------------------------
host.write_file(dir .. '/dispatch.token', '')
local blocked = call('prepare', { conversation_id = chat, body = 'terceira' })
eq(blocked.error, 'operator_private_capability_file_required', 'empty capability file is refused')
host.write_file(dir .. '/dispatch.token', token)

print('whatsapp operator ok (' .. checks .. ' checks)')
