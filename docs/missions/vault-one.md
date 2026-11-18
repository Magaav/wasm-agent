# Mission change/vault-one — one vault, keys the model uses but never reads, fleet SSH recovery

Base: fresh origin/main (74d48431 or later). Own worktree, one reused build dir. Land via the queue.

## Measured state (origin/main 74d48431, 18/11)

Three separate secret stores share no code or storage:

1. wa-vault service, Python (`vault/wa_vault.py`, client `lua/core/vault.lua`): provider proxy :8810
   (opencode-go), admin :8801, `release-signing` ed25519 (`scripts/lib/release-signing.sh` calls admin).
2. `/vault <name> <value>` (`lua/core/keys.lua`): 0600 files in `~/.wasm-agent/keys/`; the agent reads
   them with `$(cat ...)`; only exact-value redaction protects them (VAULT.md says "not isolation").
3. Rust vault component + kernel keystore (`rust/wa-vault`, `wa-keystore`, `vault_host.rs`, `wa vault`):
   sealed entries, audit chain, ed25519 sign, reveal policy.

Gaps: two ed25519 signers (1 and 3); `vault_host::migrate_keys` is called only by its tests, although
VAULT.md says keys migrate "on first start"; the name "wa-vault"/`vault.json` belongs to both 1 and 3;
`/vault` writes to 2 while `wa vault` works on 3.

## Required behaviour

A. ONE vault = front 3 (Rust component + kernel keystore). One implementation per behaviour.
   - `/vault <name> <value>` (CLI and window) writes a front-3 entry. No more `.key` files.
   - First start migrates `~/.wasm-agent/keys/*.key` into the vault (wire `migrate_keys`), verifies each
     entry, then removes the source file. The report lists names only.
   - Provider proxy routes (:8810 opencode-go) and release signing (`release-signing`, admin only, no proxy
     route, one offline backup) are served by front 3. `vault/wa_vault.py`, `vault/Dockerfile`, and
     `scripts/migrate-go-vault.py` are retired with a migration of the live Go key and release key
     (operator-run, names-only report, no plaintext backup).
   - One name: "vault". VAULT.md rewritten to describe only what exists.

B. The model can LIST, USE, CREATE, ROTATE and DELETE entries. It can never READ one.
   - Tools: `vault.list` (names + metadata), `vault.set` (value from the operator line or generated inside
     the vault, never typed by the model into a transcript), `vault.delete`, `vault.rotate`.
   - Use by reference, decided by the kernel, never `$(cat ...)`:
     - secret → `{{vault:name}}` placeholder in a command or header, substituted by the kernel at spawn;
       output redacted by exact value.
     - ssh key → the kernel loads the key into a per-run `ssh-agent` (protocol cannot export private
       keys) and gives the run only `SSH_AUTH_SOCK`. `ssh -o IdentitiesOnly=yes user@host` works; no
       key file is ever written.
   - `secret_guard` refuses every agent tool access to the vault directory and the keystore files.
   - Entries tagged `fleet` (see C) cannot be deleted by the model; only the operator (`wa vault delete
     --operator`) can delete them. Every operation goes in the audit chain.
   - Honest boundary, written in VAULT.md: the agent runs as the same OS user, so the tool surface
     enforces "never read", not the OS. Real isolation = the vault in its own user/service (follow-up).

C. Fleet SSH recovery, deterministic.
   - Each node has a recovery keypair generated INSIDE the vault (`ssh/<node>`, kind ed25519, tag
     `fleet`). The public half goes into the node's `~/.ssh/authorized_keys` as a marked line
     (`wa-fleet-recovery <node>`) during enrollment, with Victor's go per node.
   - Entry metadata (not secret): user, host, port, jump host if any, host-key fingerprint, last-seen.
   - Torus: every node's vault holds the recovery entries of its ring neighbours plus openclaw and
     wasm_the_first. No single vault is the only copy.
   - When a node comes online (mesh attach), it publishes its SSH endpoint, signed with its mesh
     identity. Each vault holding `ssh/<node>`:
     - same host key + new IP/port/user → update metadata, audit line `ssh_endpoint_changed`;
     - host-key change → REFUSE and alert the operator (a possible MITM, never auto-trusted);
     - signature invalid/unknown node → refuse, audit line.
   - Recovery: `wa ssh <node>` (and the model tool) uses the entry by reference through B's ssh-agent,
     with the jump host if one is set, even when the node's wa/sentinel is dead. This is the case of
     13/11: mail and nextcloud lost after the sentinel was stopped mid-update.

## Done when (proofs, quoted output in REPORT.md)

1. `/vault ssh_mail_ip_user.key <value>` → `vault.list` shows the name; the model cannot output the value
   in any way tried (cat, env, read tool, ls of the vault dir, `vault.reveal` without grant); the audit
   chain verifies.
2. The model uses that key to ssh into a throwaway sshd container (no real node), via ssh-agent; no key
   file appears on disk (`find` before/after).
3. Migration: a home with 3 `.key` files → 3 entries, files removed only after verification; second start
   is a no-op.
4. Provider proxy + release signing pass their existing tests (`test-vault.py`, `test-vault-sign.py` ported)
   against front 3; the Python service is gone from the tree.
5. Endpoint update: simulate an IP change → metadata updated; a host-key change → refused + alert; a
   forged announce → refused.
6. Model `vault.delete` on a `fleet` entry → refused by name.
7. Full suite green; no real node touched; enrollment on real nodes is NOT part of this mission.

## Constraints

No real node state, keys or user data. No push/gh. No busy loops. Remote calls < 30 s. Enrollment of real
nodes (authorized_keys) is a separate step with Victor's go per node, after landing.
