-- The node shapes a prompt golden is recorded for: every EXPLICIT mode, in both envelopes, plus a
-- child in the two modes that existed before this branch. Shared by the generator and the test, so a
-- case cannot be added to one and forgotten in the other.
--
-- NOT here, and why: @B@native@B@ does not exist on a27490af (its mode() answers 'only' for that value),
-- so a native golden could not be recorded FROM the base at all - it is asserted as a shape by
-- scripts/test-prompt-golden.lua and scripts/test-native-guidance.lua instead.
-- @B@subagent-only@B@ is not here either: a27490af emptied that child's list, but not because of the
-- mode - its A/B arm answered "fence" whenever WASM_AGENT_RAW_CODE was unset, and that arm's allow-list
-- (no tools) filtered the child. 1468bc53 made the arm read its own WA_AB_ARM switch, so this branch
-- declares what the policy says. Recording base's empty list would pin that defect, so the difference is
-- asserted, with its citation, in scripts/test-prompt-golden.lua.
return {
  { name = 'progressive-only', mode = 'only', envelope = 'progressive' },
  { name = 'progressive-first', mode = 'first', envelope = 'progressive' },
  { name = 'progressive-codemode', mode = 'codemode', envelope = 'progressive' },
  { name = 'progressive-off', mode = 'off', envelope = 'progressive' },
  { name = 'progressive-on', mode = 'on', envelope = 'progressive' },
  { name = 'progressive-stop', mode = 'stop', envelope = 'progressive' },
  { name = 'full-only', mode = 'only', envelope = 'full' },
  { name = 'full-first', mode = 'first', envelope = 'full' },
  { name = 'full-codemode', mode = 'codemode', envelope = 'full' },
  { name = 'full-off', mode = 'off', envelope = 'full' },
  { name = 'full-on', mode = 'on', envelope = 'full' },
  { name = 'full-stop', mode = 'stop', envelope = 'full' },
  { name = 'subagent-codemode', mode = 'codemode', envelope = 'full',
    subagent = { id = 'orchestration-worker', allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } } },
}
