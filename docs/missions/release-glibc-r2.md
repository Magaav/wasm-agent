# release-glibc round 2 — independent review of a9b60cc9: land after one fix

Same worktree/branch. Each: fix + test failing before / passing after; append to REPORT.md; fix the report's
dates (it says 19/11; the probes ran 18/11). Commit locally; never push.
1. deploy.sh guard comes after the candidate is executed (~1137): NEW is run at ~1010 (--capability-digest),
   ~1052 (--lua-tree), ~1127 (graph proof), so a too-new binary dies at 1011 with "cannot state its capability
   digest" and glibc_floor_exceeded is never reached for the node binary. Move the guard to right after NEW and
   NEW_SENTINEL are final (after ~593/672/993), before the first execution. Test: a fixture candidate needing a
   newer glibc gets glibc_floor_exceeded from deploy.sh, not the digest error.
2. fleet-install.sh refuses without the lib beside it (50-57): a standalone/curl copy now fails
   glibc_floor_lib_missing. Make the check self-contained for fleet-install.sh (inline the few functions, kept
   identical to the lib by a test that diffs them) - one behaviour, provably one implementation.
3. `sort -V` hidden dependency (wa_glibc_covers): no -V (busybox sort on a glibc host) -> empty -> every binary
   refused. Empty/failed comparison = "unknown" -> allow with a printed note, like musl.
4. Note only (no code): the byte scan counts any GLIBC_x.y string in the file; add a test asserting the scan
   equals the ELF verneed max on the built artifacts, so an embedded doc string would be caught.
