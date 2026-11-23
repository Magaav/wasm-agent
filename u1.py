p = "lua/core/deploy_wait.lua"
s = open(p, encoding="utf-8").read()
old = '''function M.refusal(wait, now)
  return "deploy_waiting: " .. M.say(wait, now) .. ". This node starts no new turn while a build is "
    .. "waiting for it or being installed - a turn in flight is exactly what keeps the node from going "
    .. "idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work "
    .. "starts again once the swap is done. A running turn pauses after its current step instead "
    .. "(lua/core/deploy_pause.lua). To stop waiting, withdraw the request: "
    .. "wa-sentinel request withdraw " .. tostring(wait and wait.id or "<id>")
end'''
new = '''function M.refusal(wait, now)
  return "deploy_waiting: " .. M.say(wait, now) .. ". This node starts no new turn while a build is "
    .. "waiting for it or being installed - a turn in flight is exactly what keeps the node from going "
    .. "idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work "
    .. "starts again once the swap is done. A running turn pauses after its current step instead "
    .. "(lua/core/deploy_pause.lua). To stop waiting, withdraw the request: "
    .. "wa-sentinel request withdraw " .. tostring(wait and wait.id or "<id>")
    .. ". " .. M.RETRY
end'''
assert old in s, 'refusal'
s = s.replace(old, new, 1)

old = '''function M.refusal_redacted()'''
new = '''-- THE LAST WORDS OF EVERY REFUSAL, so a script can tell a WAIT from a FAILURE without parsing the prose
-- (Fable's review, 23/11 ~17:10Z: a worker's run ended rc=2 and nothing in the sentence said what to do about it).
-- It is a constant because three sentences carry it - this module's two and the pause's own fallback - and a
-- caller greps for it the same way it greps for `deploy_waiting`.
M.RETRY = "retry when idle: nothing was asked and nothing ran, so ask again once the node is back"

function M.refusal_redacted()'''
assert old in s, 'redacted anchor'
s = s.replace(old, new, 1)

old = '''    .. "idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work starts "
    .. "again once the swap is done."
end'''
new = '''    .. "idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work starts "
    .. "again once the swap is done. " .. M.RETRY
end'''
assert old in s, 'redacted end'
s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
print('deploy_wait: every refusal ends in "retry when idle"')
