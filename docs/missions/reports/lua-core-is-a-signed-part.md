# lua-core-is-a-signed-part

The Lua tree as a signed PART of a release, so a Lua-only landing ships ~1.6 MB instead of the 55.5 MB program. Branch `change/lua-core-is-a-signed-part`. **Everything below is DARK: no part is published, none is consumed, and the embedded tree still runs the node.**

## 1. Measured before writing code, and what it changed

The brief read as a whole new job. It was not: on main `90ba7814` the producer (`scripts/lua-part-build.sh`), the verifier (`scripts/lib/lua-part.sh`, 7 functions), the SIGNATURE check (`0399fe71` "the lock is accepted only under the same trusted-key signature as a node build"), the interface refusal (`d604b1af`, `c32b32cc`) and their rows (`lua part ok (21 checks)`, `lua part signature ok (17 checks)`) already existed and were green. `wa_version_changed_members` already answered WHICH parts changed (item 2 as names, not just a byte count). `wa --build-info` already printed `lua_tree` and `lua_tree_digest`.

What did NOT exist: a PIN. The line shape `lua-core <sha256> <bytes> interface=<digest>` lived only inside two test fixtures (`scripts/test-version-folders-real-restart.sh:131`, `scripts/test-version-sequence.sh:96`), so a published part could be verified against nothing.

## 2. Pinning exposed three producers that could not be pinned

1. **`tar czf` was not reproducible.** Three builds of the same tree gave 1746153, 1746155 and 1746157 bytes and three digests: tar embeds every file's mtime, gzip embeds its own timestamp. Now `--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner` and `gzip -n`.
2. **The build wrote its own manifest INTO the tree it packaged** and never removed it, so the next build saw a leftover file. My first committed pin (`8c3690e4`) was two bytes wrong for exactly that reason; `test-release-lock-pin.sh` caught it with `pin_is_not_this_tree`. The build now remembers whether the tree carried a manifest and removes the one it wrote.
3. **The commit was inside the part.** `manifest.txt` carried `commit <sha>`, so one `lua/` tree had as many digests as it had commits - the pin printed at one commit stopped matching at the next, and committing the pin moved the commit. Measured fix: the same `lua/` under `--commit 53157a2c` and `--commit deadbeef` gives ONE digest (`fb3b03af`, 1738760). The commit is now a label on the lock line.

Consequence that should be said out loud: `release.lock` pins a digest of `lua/`, so **any landing that touches `lua/` moves the pin** - the same discipline `components.lock` lives by (source and pin in one commit). main moved during the work (`878b1947`) and the pin went `fb3b03af/1738760` -> `ffd4b9f7/1740007`.

## 3. What is in the branch

- **`release.lock`** (new): one line, `lua-core ffd4b9f7e3e9707709e40c15bced328968b155509240a9ca0ca89764780b9c09 1740007 interface=8a0b442e...`. Not `components.lock` on purpose: `scripts/publish-components.sh` looks for `<name>.wasm` for every pinned name, so a `lua-core` line there fails `component_missing` - the q#119 class fixed for `vision` on 27/11.
- **`scripts/test-release-lock-pin.sh`** (new, 15 checks, seconds, registered in `scripts/test.sh` as `WA_BIN="$BIN" gate_run ...`): the pin parses; a FRESH build of this tree is the pinned bytes; the verifier accepts it; one changed byte is refused (`lua_part_digest_mismatch`); the part declares the host's interface; a foreign interface is refused (`lua_part_interface_mismatch`); a node holding the pinned part asks for no download; one holding another asks for exactly the pin; a first install asks for it; a malformed held digest is refused; the pinned part signed by a trusted key passes the signature gate; unsigned is refused (`lua_part_unsigned`); an untrusted key is refused (`lua_part_signed_by_untrusted_key`); the whole install path runs in order (decision -> verify -> fill -> tree present); and the publisher prints exactly the pinned line.
- **`scripts/lua-part-publish.sh`** (new): the producer a release calls - stage, build, `SHA256SUMS`, sign, print the lock line. It prints the line `release.lock` carries, which is judged rather than trusted.
  It has **NO default signing key**: with `WA_RELEASE_KEYS` unset it refuses
  `lua_part_no_signing_key: set WA_RELEASE_KEYS ...` before writing a part, and a path that is not a file is
  refused the same way. An earlier version defaulted to the repository fixture keys - a release would then
  have signed a real part with a worker TEST key and every check downstream would still have passed, which is
  worse than no signature because nothing refuses it. The fixture keys are passed ONLY by
  `scripts/test-release-lock-pin.sh`, which also judges the refusal (check 16); a release passes the vault
  keys. This correction came from the read, and the CODE changed - the report alone was not the fix.
- **`scripts/lib/lua-part.sh`**: `wa_lua_part_fetch_decision` - given the digest a node INSTALLED, answer with the line to fetch, or nothing. Its first version hashed the unpacked tree and compared it with a lock that pins a FILE digest; those can never be equal, and the row said so (`lua_part_digest_malformed` on a good install).

## 4. What is NOT done (blocked, not forgotten)

1. **Fetch wiring** - call `wa_lua_part_fetch_decision` from the release/fetch step.
2. **Switch** - `wa_lua_part_fill` then `wa_version_point`; note the fill takes FIVE values (part, lock, destination, host interface, THE VERIFIER PROGRAM) and checks the signature FIRST, before reading a byte.
3. **Fallback** - `rust/wa-host` keeps the embedded tree as first start and falls back on mismatch, SAYING so.
4. **Reporting** - `wa --build-info` gains `lua_part=<digest> source=embedded|pinned`.
5. **Publish hook** - call `scripts/lua-part-publish.sh` from `scripts/publish-components.sh` so the part and its `.sig` ship with the bundle.

Items 3 and 4 change the host, frozen before the v0.1.2 tag; 1, 2 and 5 touch the release path, read before it lands.

## 5. What I could not verify

- The switch and the fallback: nothing in the start path reads a part, so the "mismatch falls back and says so" behaviour is not exercised anywhere yet.
- The real signer: signing in these rows uses the repository test keys (`tests/fixtures/release-sign`), because
  the vault key is not on a worker node, and the publisher now refuses to sign at all without an explicit
  `WA_RELEASE_KEYS`. The contract (`wa release verify`) is the same; the key is not, and no release path has
  been exercised with the vault key.
- A real fetch of ~1.6 MB from a tree-less node: the produced part is 1,740,007 bytes, which is the number the brief asked for, but no node downloaded one.
