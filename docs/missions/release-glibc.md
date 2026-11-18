# Mission change/release-glibc — a release binary never needs a newer glibc than the fleet has

Measured 18/11: mail (Ubuntu, glibc 2.35, aarch64) was down 2 days. The installed 14963b6f binary needs
GLIBC_2.39 (`objdump -T wa | grep GLIBC_ | sort -V | tail -1`); the sentinel retried 424 times
("GLIBC_2.39 not found"). The 15/11 binary (842868c1) needed GLIBC_2.30. Fix both ends:
1. Build: linux release binaries (x86_64 and aarch64, wa + wa-sentinel) target a fixed glibc floor
   (zig/cargo-zigbuild `-gnu.2.31` style target or equivalent; see arm.sh/cross.sh/publish-node-binaries.sh).
   The publish step measures each artifact's max GLIBC symbol and refuses to publish above the floor.
2. Install: fleet-install.sh / upgrade.sh / deploy.sh refuse a binary whose max GLIBC symbol exceeds the
   host's (`ldd --version`), before swapping, with both versions in the message; the old binary keeps running.
3. Floor documented in docs/INSTALL.md with the measured fleet (mail 2.35; nextcloud git 2.25 era = older).
Proof: a test with a fake binary needing a newer glibc is refused at install; a built artifact's max symbol
is <= the floor. Build here only; commit locally; never push.
