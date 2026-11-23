# wit-one-source: the kernel interface had ten copies and seven contents

Branch `change/wit-one-source`, base 44479b7f. Commits that implement this report:
`0239592a` (generator, registry line, fast row, the regenerated copies), `85a888ee` (the wit-lint
baseline record the regeneration made visible), `07e204e8` (the component-pins record, measured).
Nothing was pushed, no fleet was called, no pin was moved.

## 0. The brief, re-measured (rule 9)

Confirmed on 44479b7f, with `sha256sum`, `wc -l` and `git log -1` per file:

| sha (8) | lines | last commit | path |
|---|---|---|---|
| 2dcec143 | 390 | 2026-11-08 | `wit/kernel-v2/kernel.wit` |
| 2dcec143 | 390 | 2026-11-08 | `rust/components/wa-email/wit/deps/kernel.wit` |
| 2dcec143 | 390 | 2026-11-08 | `rust/components/wa-whatsapp/wit/deps/kernel.wit` |
| 76e749b2 | 321 | 2026-11-07 | `rust/components/model-gateway/wit/deps/kernel.wit` |
| 7353cef3 | 206 | 2026-11-07 | `rust/components/svc-drain/wit/deps/kernel.wit` |
| 5391085b | 181 | 2026-11-06 | `rust/components/svc-queue-echo/wit/deps/kernel.wit` |
| 5391085b | 181 | 2026-11-07 | `rust/components/telemetry-sink/wit/deps/kernel.wit` |
| 13164eb3 | 161 | 2026-11-05 | `wit/kernel/kernel.wit` |
| 32eb6182 | 82 | 2026-11-07 | `wit/selfloop/deps/kernel/kernel.wit` |
| 90871417 | 45 | 2026-11-07 | `wit/memory/deps/kernel/kernel.wit` |

Ten files, seven contents. `clocks.wit`: 7 copies, 2 contents (5b593987, 161 lines, in
`wit/kernel-v2/deps/` and the three components that carry the whole thing; 436bd8fa, 104 lines, in
svc-drain/svc-queue-echo/telemetry-sink). `bus.wit`: 4 copies, 1 content. `queue.wit`: 5 copies, 1
content. `cli.wit`, `filesystem.wit`, `random.wit`, `sockets.wit`: 3 copies each, 1 content each.

What the brief had wrong, or left as a guess:

* **"canonical" is two files, not one.** All eight component copies declare `package wa:kernel@0.2.0`
  and are copies of `wit/kernel-v2/kernel.wit`; the memory and selfloop copies declare
  `wa:kernel@0.1.0` and are slices of `wit/kernel/kernel.wit` (for `types`) plus `wit/kernel/sql.wit`
  (for `sql`, a second file of the same package). Section 1 proves which file each is canonical from.
* **"a copy that DISAGREES on a function it shares is a real defect"** - measured, there is **no such
  copy**. Every block every copy shares with its canonical file is declaration-identical (comments
  stripped, whitespace collapsed; the method is in section 2). Nothing needed a semantic fix, and
  nothing was "fixed" that way.
* **What had actually drifted was the trimming**, and only in comments: `svc-queue-echo` and
  `telemetry-sink` kept the first line of the doc comment above `interface lifecycle` and dropped its
  three-line continuation, and `wit/memory/deps/kernel/kernel.wit` had lost all four doc comments
  inside `interface types`. Measured by diffing the raw line ranges, section 2.
* The brief's guess that "the dates climb with the line counts" holds for the first five rows and not
  for the two 0.1 seams (both 2026-11-07, different sizes, both hand trims).

## 1. Which file is canonical, proved from what the host serves

Two files, each canonical for its own package, and the proof is the `bindgen!` the host is built
with:

* `wa:kernel@0.2.0` -> **`wit/kernel-v2/kernel.wit`**:
  `rust/wa-kernel-runtime/src/service_components_v2.rs:54-56` binds `world: "service-component"` from
  `path: "../../wit/kernel-v2"` (the WASI 0.3 runner); `:81` binds `world: "service-drain"` from the
  same path; `vision_host.rs:23-24` binds `service-vision` from it; `wasi_ext_host.rs:28-29` binds
  `keyvalue-config` from it. Those are the worlds the 0.3 runner links.
* `wa:kernel@0.1.0` -> **`wit/kernel/kernel.wit`** (plus `wit/kernel/sql.wit`):
  `rust/wa-kernel-runtime/src/service_components.rs:34-36` binds `world: "service-component"` from
  `path: "../../wit/kernel"` - the WASI 0.2 runner, served side by side.
* The host's own statement of that, as a test: `imports.rs:323-326` reads the `world
  service-component` imports out of both files and asserts them against `KERNEL_V1`/`KERNEL_V2`
  (`imports.rs:65-66`), so a new interface in either file that the host does not serve is a red row.
  `KERNEL_V2_OPTIONAL` (`imports.rs:76`) is the host's superset beyond a world's obligations:
  `keyvalue`, `config`, `drain`, `vision`.
* One measured caveat, not a copy problem: `interface keystore` is declared in the canonical 0.2 file
  and named as a granted tier-B interface in `wasi_grants.rs:173` ("the host function lands with the
  WASI 0.3 component runner"), but nothing in `wa-kernel-runtime` binds `wa:kernel/keystore` - the
  only occurrences are that grant spec and the `wa-keystore` library. A component that imported it
  would not start today. The copies agree with the canonical text about it; the host is what lags.

## 2. Every copy against its canonical file

Method: strip `//` comments, split each file into its top-level `interface NAME {` / `world NAME {`
blocks by brace depth, and compare (a) the whole block whitespace-collapsed and (b) the raw line
range. The findings below are from the part before the change (`git show 44479b7f:<path>`).

Two canonical files, so two verdicts per copy.

**Against `wit/kernel-v2/kernel.wit` (canonical line numbers):**

| copy | verdict |
|---|---|
| `wa-email/wit/deps/kernel.wit` | byte-identical (whole file) |
| `wa-whatsapp/wit/deps/kernel.wit` | byte-identical (whole file) |
| `model-gateway/wit/deps/kernel.wit` | strict subset: drops `interface vision`@123, `interface keystore`@173, `world service-vision`@318 |
| `svc-drain/wit/deps/kernel.wit` | strict subset: 12 blocks not kept (vision@123, keystore@173, keyvalue@264, config@281, service-drain@310, service-vision@318, wasi-probe-env@335, wasi-probe-stdin@344, wasi-probe-fs@353, wasi-probe-net@364, keyvalue-config@376, wasi-probe-kv@383) |
| `svc-queue-echo/wit/deps/kernel.wit` | strict subset: 13 blocks not kept (the above plus `interface drain`@221); comment drift at `interface lifecycle` (doc continuation dropped) |
| `telemetry-sink/wit/deps/kernel.wit` | identical to svc-queue-echo's, same comment drift |

**Against `wit/kernel/kernel.wit` + `wit/kernel/sql.wit`:**

| copy | verdict |
|---|---|
| `wit/memory/deps/kernel/kernel.wit` | subset: keeps `types`, `sql` only; 9 blocks not kept (websocket@23, http@42, speech@66, kv@90, lifecycle@108, log@124, credentials@138, service@144, world service-component@151). Its `types` had lost the four doc comments on `variant error`'s cases (declarations identical) |
| `wit/selfloop/deps/kernel/kernel.wit` | same subset; its `sql` had the doc comments and its `types` had lost them - so the two copies of the SAME interface differed from each other in comments |

**`clocks.wit`:** the three 104-line copies are a strict subset of `wit/kernel-v2/deps/clocks.wit`,
keeping `types`@5, `monotonic-clock`@20, `system-clock`@66 and dropping `timezone`@107 and `world
imports`@152; every shared block is byte-identical. (The interface is `system-clock`, not
`wall-clock` - wasi:clocks 0.3.0 renamed it, and the keep list in the generator says so.)

**`bus.wit`, `queue.wit`, `cli.wit`, `filesystem.wit`, `random.wit`, `sockets.wit`:** one content each,
byte-identical everywhere.

**0.1 against 0.2** (two packages, so not a copy question, but the one place same-named interfaces
differ): `types`, `lifecycle`, `log`, `credentials` are identical; `websocket`, `http`, `speech`, `kv`,
`service` and `world service-component` differ by design (0.2 is the `async func` / `stream` /
`future` shape of the same contract).

**Does any component import something its own copy lacks?** Measured over the components' own `.wit`
files: model-gateway imports `credentials`, `http`, `kv`, `log`; svc-drain `drain`; wa-email `types`;
wa-whatsapp `drain` and `vision`; svc-queue-echo and telemetry-sink import nothing of `wa:kernel`'s.
Every one of those is present in its copy, which is why no build was broken - the copies lagged
harmlessly, exactly as the brief predicted a lagging copy would.

## 3. One source (what the diff implements)

`scripts/gen-wit-deps.lua` (`0239592a`) is the only thing that writes these files:

* 34 copies from 11 canonical files. Each copy is either the canonical file **byte for byte**
  (`keep = '*'`) or a **named list of blocks** sliced out of the canonical file in that file's own
  order, each with the doc comment (or `@since(...)`) directly above it, copied verbatim.
* A keep name that the canonical file no longer declares is a **named failure**, not a silent
  omission (`wit-deps: <out> keeps <name>, which <src> does not declare`), and so is a keep list that
  keeps nothing, a block sliced twice, a file with no `package` line, an unterminated block, and a
  path that is both a canonical file and a copy of one.
* `scripts/generators.txt` declares all 34 outputs on one line, so `bash scripts/regenerate.sh` runs
  it on every landing's merged tree (`regenerate: running lua5.4 scripts/gen-wit-deps.lua --write`).
* `scripts/test-wit-deps.lua` (`0239592a`) is the row: it recomputes every byte, names each copy that
  differs with its line, requires every `.wit` under a `deps/` directory to be either a declared copy,
  a declared canonical file, or a declared package-local file, runs the CLI the landing runs, and
  proves it can fail by editing one word of a declaration in memory and requiring the line to be
  reported. It writes nothing, so it needs no scratch home. **Wired in `scripts/lib/fast-rows.sh`,
  `wa_fast_core_rows`** - a never-dropped row, because it is a whole-tree row.
* `scripts/gen-wit-deps.lua` also names the one deps file that is nobody's copy:
  `wit/codemode/deps/kernel/quickjs.wit` is the only declaration of `interface quickjs` in this tree
  (`rg -l 'interface quickjs'`), so there is no canonical text to slice it from.

What the regeneration changed, 9 files, all comments and blank lines (line counts before -> after):
`model-gateway/deps/kernel.wit` 321 -> 305, `svc-drain/deps/kernel.wit` 206 -> 207,
`svc-queue-echo/deps/kernel.wit` 181 -> 182, `telemetry-sink/deps/kernel.wit` 181 -> 182, the three
`clock.wit` 104 -> 113, `wit/memory/deps/kernel/kernel.wit` 45 -> 121, `wit/selfloop/deps/kernel/
kernel.wit` 82 -> 121. The declarations are unchanged, checked by stripping comments and blank lines
from both sides of the diff for each of the nine files: `DECLARATIONS UNCHANGED` for all nine.

One consequence, recorded in `85a888ee`: with the doc comment back on `journal-entry.payload` in the
memory copy, `scripts/wit-lint.sh` rule 1 can finally see that field there, and the baseline gained
the line it already had for the same field in the other two files. `scripts/test-wit-lint.sh` pinned
the count (five) and now pins six (`6 baselined (4 json-name, 2 poll-without-future)`) - the same
assertion, on the set the tree really has. The comment in `wit-lint.sh` that cited the memory copy as
a shape "rule 1 cannot see" was rewritten, because it is no longer true.

## 4. Which components would change bytes - none, measured

Method: put the nine copies back to their bytes at 44479b7f, build, record; restore the generated
ones, build again, record. Same tree, same `CARGO_TARGET_DIR`, same path, and cargo recompiled the
component in **both** directions (`Compiling <name>` printed each time):

| component | sha256 of the wasm32-wasip2 build, old copies | with the generated copies |
|---|---|---|
| model-gateway | 4c8deb642fcf910fe3b9daf7ce228963fc8d16865d3084157598594e1c6824a6 | same |
| telemetry-sink | 9752efeb7a0dd11a325cc1322913906d9a6b6486095fccb35c719e81cc5a7151 | same |
| memory | 39b0e1e242efac6f4d95a6ea661dcfd4006255500b129a339346006a3e4df67a | same |
| selfloop | 239174ff52111daad1ce40e5c35eb70513d604927864d139e354c7002d82066a | same |

So **no pin needs to move**, and `components.lock` was not touched. The record is in the commit
trailer `Components-Unchanged:` for `model-gateway`, `telemetry-sink`, `memory` and `selfloop`
(`07e204e8`), which is the mechanism `scripts/test-component-pins.sh` provides for exactly this case;
`bash scripts/test-component-pins.sh --source-only` is green on all four.

`memory` and `selfloop` are in that list because their components compile `wit/memory` and
`wit/selfloop`, which is where two of the regenerated copies live. The pins row's input set is
`rust/components/<name>/**` plus `path =` dependencies, so it never asked about those two; I measured
them anyway. This is a gap in that row, named here and not fixed in this mission.

`svc-drain` and `svc-queue-echo` are not in `components.lock` (fixtures), so the row never judged
them; they build for wasm32-wasip2 with the regenerated files, which is also the proof that the
regenerated WIT is valid WIT (wit-bindgen parses the package and its `deps/` at compile time).

## 5. Would `wac` or `wasm-tools component wit` have caught this at build time?

No - not this, and mostly not at build time. Both tools read a **compiled artifact**, and it exists
only after a build: the drift lived in source files that a build had already accepted. `wasm-tools
component wit` prints the WIT of a component, which is what the guest *imports* after wit-bindgen has
elided everything it does not use - `svc-queue-echo`'s and `telemetry-sink`'s `kernel.wit` copies are
not in their artifacts at all (neither imports a `wa:kernel` interface), so the tool has nothing to
show and nothing to compare. `wac` composes/links components, and its link is type-directed: it would
fail on a copy that drops an interface the guest really imports, or that declares a different
signature for a function both sides declare - but that is exactly the case the runtime already
catches, and more cheaply, because the host here *is* the linker: wasmtime refuses to instantiate a
component that imports what its linker does not provide (`imports.rs::kernel_serves` is the same rule
checked before start). What neither tool can see is a copy that lags - a strict subset - while the
host serves the superset, and a comment-only difference such as the four doc comments missing from the
memory copy: both are invisible in a type section. The defects the copies could have had were
(a) a copy that drops a function the guest imports - caught at instantiate, on the components that
get instantiated, which is every one that ships and no fixture; (b) a copy that lags or drifts where
nobody looks - caught by nothing, because no build compares a vendored copy with the file it was cut
from. (b) is what this round's row catches, on all 34 copies, in seconds and with no toolchain.

## 6. How it is checked, run

`bash scripts/regenerate.sh && git status --short` -> the generator runs (`wit-deps: 34 deps copies
from 11 canonical file(s): 0 written, 34 already exact`, `regenerate: changed_count 0`) and
`git status --short` prints nothing.

A hand edit is caught by name. Reverting just `rust/components/model-gateway/wit/deps/kernel.wit` to
its 44479b7f bytes (a hand edit's shape) and running the row:

    lua5.4: scripts/test-wit-deps.lua:33: 1 of 34 vendored WIT copies differ from their canonical text
      - run bash scripts/regenerate.sh (or `lua5.4 scripts/gen-wit-deps.lua --write`):
      rust/components/model-gateway/wit/deps/kernel.wit is not what its canonical file says:
      line 1 should be "// GENERATED by scripts/gen-wit-deps.lua - do not edit by hand." and is
      "/// wa:kernel@0.2 - the 0.1 contract expressed for WASI 0.3 (native async)."

Green row: `wit deps: 16 checks passed - 34 vendored copies from 11 canonical files`.

**Does the row discriminate?** `bash scripts/test-discriminates.sh 44479b7f` reports
`unrevertable scripts/test-wit-deps.lua` - not because the row is vacuous, but because the branch
touches `rust/` and that tool will not run Lua rows against a base binary it did not build. The
equivalent, done by hand in a scratch worktree at 44479b7f with only the two new scripts checked out
(so the base's copies are what it judges): the row **fails**, `exit 1`, naming all nine copies that
were not what the canonical text says. On the branch the row is green against the committed copies and red against the base's, which is
the discrimination that matters here.

Also green on this branch: `scripts/test-fast-rows.sh` (`fast-rows ok (37 checks)`, including the
generator/reader pairing), `scripts/wit-lint.sh`, `scripts/test-wit-lint.sh` (`71 checks`),
`scripts/test-component-pins.sh --source-only`, and the four component builds above.

## 7. Texts to approve

Generator, operator-facing (stdout/stderr):

    wit-deps: wrote <out> from <sources>
    wit-deps: %d deps copies from %d canonical file(s): %d written, %d already exact
    wit-deps: STALE <out> (line %d: want %q, have %q)
    wit-deps: MISSING <out> (the manifest names it; run bash scripts/regenerate.sh)
    wit-deps: %d deps copies are exactly what their canonical files say
    wit-deps: %d of %d deps copies differ from their canonical files - run bash scripts/regenerate.sh
    wit-deps: canonical file %s is missing or unreadable
    wit-deps: %s has no `package ...;` line
    wit-deps: %s declares %s twice
    wit-deps: %s opens %s %s on line %d and never closes it
    wit-deps: %s keeps %s, which %s does not declare
    wit-deps: %s keeps %s from %s twice
    wit-deps: %s keeps nothing from %s - say '*' for a full copy
    wit-deps: %s sliced %d block(s) for %d kept name(s)
    wit-deps: %s is declared twice in this script
    wit-deps: %s is both a canonical file and a copy of %s

Header written into every trimmed copy:

    // GENERATED by scripts/gen-wit-deps.lua - do not edit by hand.
    //
    // A hand edit here fails scripts/test-wit-deps.lua, and `bash scripts/regenerate.sh` puts the
    // canonical text back. What is kept, and from where:
    //   <canonical file>: <comma separated block names>
    //
    // Every block below is a verbatim slice of its file, in that file's order, with the doc
    // comment above it. The canonical file is the source; this one only says what is kept.

Test row, on failure: `scripts/gen-wit-deps.lua must load: ...`, `the manifest must render: ...`, `the
manifest names no copy at all`, `<out> is not what its canonical file says: line %d should be %q and
is %q`, `%d of %d vendored WIT copies differ from their canonical text - run bash
scripts/regenerate.sh (or \`lua5.4 scripts/gen-wit-deps.lua --write\`)`, `a copy the manifest names
is gone`, `this row does not name an output the generator writes, so the never-dropped pairing in
scripts/test-fast-rows.sh cannot see it`, `this row names a path the generator does not write`, `the
manifest names files this tree does not have`, `the deps enumeration did not run: without it this row
cannot say whether an undeclared copy exists, and an unknown answer is not a pass`, `a WIT file is
vendored that no generator owns - add it to the manifest in scripts/gen-wit-deps.lua with what it
keeps, or delete it`, `lua5.4 scripts/gen-wit-deps.lua --check is not green, and scripts/regenerate.sh
runs exactly that: ...`, `the first copy declares a \`func\` for the mutation check`, `a one-word edit
in a declaration must be seen`, `the reported line must carry the edited text (line %d: %s)`. Its
verdict line: `wit deps: %d checks passed - %d vendored copies from %d canonical files`.

Changed test text (`85a888ee`): `the six shapes main has are the six this tree records, and the two
kinds are counted apart (four JSON-carrying names, two poll funcs)` (was `five`/`three`).

## 8. Not done, or not verified

* `scripts/test-component-pins.sh` half 2 (pin vs bytes) was not run - only `--source-only`. It needs
the published artifacts or a download; nothing was fetched.
* `test-discriminates.sh` could not judge the new Lua row (section 6); the hand equivalent in a base
worktree is the evidence instead.
* The `.wit` files are validated only by wit-bindgen parsing them in the four component builds; no
`wasm-tools`/`wac` binary is installed on this node, so nothing was checked with those tools. Section 5
is reasoning about what they would and would not have caught, not a measurement.
* `wit/codemode/deps/kernel/quickjs.wit` is left as it is: it is the only declaration of `interface
quickjs` in this tree, so there is nothing to generate it from. It is in the generator's
`PACKAGE_LOCAL` list with that reason, which is what lets the row's allow-list name it instead of
passing over it.
* Nothing on the fleet, no deploy, no release, no key, no pin, no push.
