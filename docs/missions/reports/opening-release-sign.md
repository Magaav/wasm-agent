# opening-release-sign: the signing row's fixture after the font became a release asset (24/11)

Red on main, bisected singly (green on c8b3a911, red on 7f6cf82a):
`scripts/test-release-sign.lua:76` - "release signing: 2 of 4 checks failed", the failing line
`a signed set ships: expected exit 0, got 8: publish-artifacts-branch: publisher: bash
scripts/publish-node-binaries.sh --commit … --out …`.

## The cause, file:line

Not the publisher, and not the font being missing from the sums: the FIXTURE built a set this publisher
can no longer produce.

`scripts/test-release-signing.sh`'s `stub_release()` (the fixtures at `scripts/test-release-signing.sh:281-302`)
assembled a release directory from two ELF stubs and `node-<sha>.manifest`, and then signed it
(`scripts/lib/release-fixture-sign.py`, which sums every regular file in the directory). A real set from this
tree holds one more file since item 7 (`5df877b7`): `scripts/publish-node-binaries.sh:412-413` copies
`assets/fonts/waIcons-Regular.ttf` beside the binaries and REFUSES a set without it, and `:713` puts it in
`$assets`, the list the sums are built from (`:742-746`).

So on the ship step the row re-ran the publisher over the fixture set, the publisher found a set without
the font, added it, and therefore wrote NEW sums - and the fixture's signature was over the old ones:

```
release_signature_invalid: …SHA256SUMS.sig is about 9e4edeb0…, the sums here are 26321f5e…
publish-node-binaries: signature_stale: … is not a signature over the sums just written (they changed after
  it was made), so nothing is published; sign the new …/SHA256SUMS where the vault is …
```

That refusal is the PRODUCT working: a signature over other bytes must never ship. The FRAME was wrong -
a fixture set that models a release without its font.

## The fix (product untouched, no check weakened)

`scripts/test-release-signing.sh`'s `stub_release()` now installs
`assets/fonts/waIcons-Regular.ttf` into the fixture directory BEFORE it signs, so the fixture models the set
a real publish produces: the fixture signer sums the font with the rest, the publisher's `sums_match` holds
("checksums reused"), the signature stays valid, and the shipped ref carries the font.

And the row got STRONGER, on the shipped bytes (after the ref is read back and before the suite says ok):

* the shipped ref must carry `waIcons-Regular.ttf` (`the shipped ref <ref> does not carry …`);
* the shipped `SHA256SUMS` must name it (`… so the font ships unsigned`) - a sums row for a file the ref did
  not carry is the exact defect this suite exists for.

The suite went from 84 to 86 checks and is green; no assertion was removed or relaxed.

## The real publish puts the font in the release and in the signed SHA256SUMS

| what | where |
|---|---|
| the font is copied into the release directory (a set without it is refused `font_missing`) | `scripts/publish-node-binaries.sh:412-413` |
| it joins `$assets`, the list the sums are built from | `scripts/publish-node-binaries.sh:713` |
| `SHA256SUMS` gets one row per `$assets` member - the font included | `scripts/publish-node-binaries.sh:742-746` |
| `$asset_paths` is that same list, for `gh release create` / `gh release upload` | `scripts/publish-node-binaries.sh:800-805`, `:818-826` |
| the artifacts commit carries it and re-verifies its sha before pushing | `scripts/publish-artifacts-branch.sh:119-127` (and the `ASSETS … in_git == want` loop) |
| the vault signs `SHA256SUMS` (the file that now names the font) | `scripts/publish-node-binaries.sh`'s signing step; `wa_release_verify_sums` in `scripts/lib/release-signing.sh` |

The linux BUNDLE path (`scripts/release-linux.sh`) stages `wa`, `wa-sentinel`, `ui/` and `scripts/` - it does
not carry `assets/`, and its `SHA256SUMS` covers the bundle. That is a different artifact (a sandbox image),
and `/icons`'s download line names the NODE release asset, which is the one that exists. Named here so nobody
reads the bundle's sums as the place the font should be.

## Rows run

* `scripts/test-release-sign.lua` (drives the shell suite + the vault suite): **release signing ok (5 checks)**;
* `scripts/test-release-signing.sh` alone: **ok (86 checks)**
  (`WA_RELEASE_BIN=/home/victor/.local/bin/wa`, the installed 7f6cf82a binary);
* `scripts/test-icons.lua`: **267 checks, 0 failed** (the row that owns the font's own claims).

No new operator-facing text: the two added strings are failure messages of this suite.
