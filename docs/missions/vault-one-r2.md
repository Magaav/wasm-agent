# vault-one round 2 — independent security review of 5cd9a710: DO NOT LAND AS IS

Same worktree/branch (change/vault-one, on top of 5cd9a710). The tool surface is clean; the claim "the model
can use a secret but never read it" fails against the model's own bash. Each finding: fix + a test that fails on
5cd9a710 and passes after (an adversarial one, run as the model would: bash, a second call, ps, a pty), appended
to REPORT.md. Commit locally; never push.

1. Operator impersonation via the CLI. cli.rs:128 grants the operator actor from a plain `--operator` flag; from
   bash the model can `wa vault delete ssh/<node> --operator`, `wa vault fleet enroll ...` (rewrite mesh_key/
   host_key), `wa vault sign`. `reveal` (cli.rs:172) only checks a tty, which `script -qc ... /dev/null` fakes.
   secret_guard does not refuse `wa vault`. Fix: operator subcommands refuse inside node/agent context
   (WASM_AGENT_* run env, operation spawn marker) and require an operator credential the agent never holds;
   add `wa vault` operator verbs to secret_guard. State the remaining same-user limit in VAULT.md.
2. Global redaction removed. keys.lua values() returns {}; only the command using the placeholder is redacted.
   `echo {{vault:x}} > /tmp/f` then `cat /tmp/f` in a later call leaks. Restore: every secret entry is in the
   node's redaction set for all output, every call. <4-byte values: refuse to store or redact anyway. Docs say
   encoded copies (base64/rev) escape.
3. Value in argv and on disk. host.rs:1233 puts the substituted value in `sh -c <cmd>` (/proc/<pid>/cmdline,
   visible to a parallel `ps`); operations.rs:112 writes long commands to command-*.sh. Pass values through
   environment variables (placeholder becomes "$WA_VAULT_<n>"), never in argv or staged scripts. Check whether
   the operation index stores argv and fix it if so.
4. ssh pin bypass (vault_api.rs:203): `{user}@{host}` from model args -> `user="-oProxyCommand=..."` is an
   option; model-supplied `jump` uses default known_hosts; an entry without host_key runs unpinned (and
   fleet::decide never writes one); known_hosts at predictable /tmp/wa-known-hosts-{pid}-{port} via fs::write
   (follows symlinks, never removed). Validate user/host/port strictly, `--` before the destination, refuse
   without host_key, pin the jump host too, private 0600 temp file created atomically and removed.
5. Announce replay: ts signed but never compared (lib.rs:745); `|` in fields not escaped. Store last_ts per node,
   require strictly increasing; reject `|` (or length-prefix) in signed fields.
6. ssh-agent dir (agent.rs:33): create_dir_all accepts an existing dir, chmod error ignored. Create atomically,
   fail on error, verify owner+mode.
7. Admin/login weaker than the Python service: Origin/instance checked only if present (service.rs:385-394);
   token compare not constant-time; /login/opencode-go on :8810 unauthenticated and accepts cross-site
   text/plain POST; 4096-byte key cap dropped. Require Origin+instance on admin, constant-time compare,
   /login requires application/json + no cross-site Origin + size cap.
8. Existing nodes lose :8810: nothing starts `wa vault serve`; no automatic migration of the Python store; scripts
   test-release-signing.sh / test-land-signing.sh still point at wa_vault.py. Provide the service unit/sentinel
   wiring, an operator `import-legacy` path proven against a Python-store fixture, and fix the two scripts.
9. Minor: migration trims only one trailing \n (old: all whitespace - CRLF leaks \r); first_start_at_boot runs in
   every wa process with no cross-process lock.

10. /login stored a key with a leading UTF-8 BOM (\ufeff) and whitespace; the proxy then crashed on every request (UnicodeEncodeError latin-1 at "Bearer \ufeff...") and the node reported "network appears down". Strip a leading BOM and surrounding whitespace at /login (and at import), or refuse it by name; never store a value that cannot be sent as a header. Test with a BOM+CRLF key.
