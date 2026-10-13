# Bounded repository survey views

Repository research collectors retain full GitHub metadata, pinned commit/tree
JSON, README text and selected source files in session-owned evidence scratch.
They must not print all README excerpts or recursive file inventories as one tool
reply: the real six-repository survey produced59,910 bytes and clipped candidates.

## Use the retained cache

The read-only helper lives at
`skills/code-graph/scripts/repo-survey.mjs`. It has no network, installation,
subprocess or write effects. Feed it a completed cache, not a live account:

```
node <repo>/skills/code-graph/scripts/repo-survey.mjs --cache <absolute-cache> --max-bytes 8192
```

Collectors call the exported `surveyView({cache: out, maxBytes: 8192})` only
**after** retaining the complete results and raw evidence. Print that one JSON
object, not the original `results` array. The original collector's existing-cache
refusal remains: do not rerun a network collection to repair its display.

Cache format:
- `receipt.json`: `{results:[{repo,ok,commit,readme_bytes?,error?,...}]}`.
- Successful repositories retain `owner--repo/metadata.json`, `commit.json`,
  `tree.json` and, when captured, `README.md`.
- Extra README excerpts, source inventories and source files stay in the cache;
  the model view explicitly labels omitted fields and supplies relative paths.

The output preserves every candidate's repository, source tip/date, license,
archive status and remote-tree completeness. It reports `total`, `returned`,
`failed_total`, `complete`, `omitted_after` and `next_offset`. `collection_ok:false`
means collection failures remain; CLI exit1 preserves those rows and their errors.
`ok:true` means the view was constructed, not that the candidates were benchmarked.

## Pagination and evidence

The default reply budget is8KiB, validated against the **encoded JSON plus newline**;
explicit2048–51200-byte budgets are supported. No host/tool budget is changed.
When `complete:false`, continue with both `next_offset` and `snapshot`. The snapshot
binds the manifest and retained metadata/commit/tree/README bytes; changed evidence,
missing files, invalid UTF-8, inconsistent commits, unsafe paths and duplicate
records refuse. A capture changed while reading also refuses. Full source files
outside those named evidence inputs remain available but are not certified by this
view's snapshot; read them with their own version receipts. Repository judgement
and source inspection remain inference, never replaced by this metadata page.

```
node <helper> --cache <absolute-cache> --offset <next_offset> --snapshot <sha> --max-bytes 8192
```

`repo-survey-cached-view` records a deterministic single-page view of retained
candidates. Required worktrees use the verified direct CLI, not unsupported spell
replay. Large surveys use the explicit continuation above; a spell's complete-page
refusal is correct, not a reason to discard candidates or raise global budgets.

## Focused verification

```
node <repo>/skills/code-graph/scripts/test-repo-survey.mjs <absolute-evidence-scratch>
```

Private offline fixtures check causal oversized old output, all-candidate coverage,
whole-reply byte bounds, pagination, changed snapshots, preserved source bytes,
Unicode, failed collections, invalid/missing evidence and path escape. Report
actual checks and skips. This is not a full release gate or a web-provider quality
benchmark. The helper is usable directly from the source checkout; using it does
not require replacing the node or installing a search/scraping service.
