# mcp-list-is-simple - /mcp lists two groups, a mark, a name and a tool count

H item, week 1. Branch `change/mcp-list-is-simple`, based on `origin/main` (345e51be). Nothing was landed,
pushed or deployed by this mission; the work is three commits on the branch.

## What was asked, and what it now does

Victor, 24/11: "we should list wasm-agent built-in MCPs and User MCPs and simplificate just list how many
tools it has" - after `/mcp` on the laptop read `Services - 9 services - 1 built-in, 8 MCP - 8 connected -
42 tools callable now`, then nine numbered rows of which six were called "WhatsApp", one row whose NAME was a
whole sentence, and a right column cut off.

- **Two groups, in this order**, each with its heading: `wasm-agent built-in MCPs` then `User MCPs`. The page
title is `MCP servers`, and under it `<n> servers` where n is the number of rows the two groups show.
- **One row per connector on this node**: a mark (`✔` connected, `!` not), a short name (32 characters at
most, cut with an ellipsis), then `<n> tools` - or, when the connector is not healthy, the state in at most
two words in place of the count (`needs token`, `server changed`, `not reachable`, `disabled`). No number, no
description, no transport, no `callable now` sentence, no node column.
- **A name is a NAME**: `Quarterly reports from the acco...` - a description never appears in a row.
- **The same connector on other nodes is not a row of its own**: one folded row at the end,
`On other nodes - <n> hidden`, which opens to rows named `<connector> on <node>`.
- **Retired entries are folded, not dropped**: `<n> retired`, whose page says why (the program went; the
tools are not offered any more). They are not dropped because the registry row is still the operator's to
remove, and a reader who wonders where it went must find it.
- **Enter opens what it opened before**: the connector's own page (type, where it runs, state, error in full,
approval), then its tools, then each tool's input fields, with the same actions (`Reconnect`, `Turn on`/`Turn
off`, `Sign in`). The detail pages are untouched beyond the list's shorter names.
- **`wa mcp list`** prints the same groups and columns as plain text (`wa mcp list --all` also prints what
the list folds away, because a pipe cannot open a row).

## The commits

| commit | what it implements |
|---|---|
| `9832ab08` | `lua/core/mcp_list.lua` (the rows), `M.views` rebuilt around it, `balloon` heading + unnumbered pages, fixture, snapshots at 80 and 120, the three tests that pinned the old rows |
| `a8049eaf` | `wa mcp list` (`mcp_cli.run_cli`), the `mcp` verb in `lua/core/init.lua`, `scripts/test-mcp-list.lua`, the fixture's `refuse_token` mode |
| `6b958b3c` | the live panel: `PanelOption.heading` + `Panel.numbered` in `rust/wa-term`, `ViewOption.heading` + `View.numbered` in `rust/wa-cli-views` |

Every claim below cites one of those three (`git log -S`, `git show`).

## Premises, re-measured before writing code

- "Ours on the laptop shows `<n> services - ... tools callable now`, then numbered four-column rows" -
  **true of the balloon**, `lua/core/mcp_command.lua` `M.views` (the header line and `row_hint` before
  `9832ab08`), and pinned by `tests/snapshots/balloon/mcp-list-80x24.txt`: `4 services - 1 built-in, 3 MCP -
  2 connected - 5 tools callable now`, then `1. WhatsApp   built-in - account on openclaw - connected - 36
  chats`. The web panel (`ui/components.js`) has the same wording on its own line; it is NOT touched here.
- "`wa mcp list` prints the same groups and columns" - **the verb did not exist**. Measured:
  `rg -n "wa mcp" ` over the tree found nothing, and `lua/core/init.lua` had no `mcp` command (the `/mcp` of
  `wa chat` is `lua/core/mcp_cli.lua`). So §7 was new code, not a reformat: `a8049eaf` adds the verb and one
  line to `wa help`.
- "Shares the built-in / added-on-this-node test with `mcp_command.origin_of`" - **it exists and is the only
  implementation**: `origin_of` decides `built-in` when a connector's arguments name a script in
  `mcp.RUNTIME` (`mcp-mail.mjs`), else `custom`; `local_connector` carries the answer as `entry.origin`.
  `mcp_list` reads that field and never re-runs the test - `git log -S "entry.origin"` shows it entering at
  `9832ab08`, and the same commit is the only place `origin_of` occurs outside its own definition.
- "The mark and the right column carry state in at most two words" - the registry's own words are
  `enabled`/`failing`/`stale`/`disabled`, translated once by `mcp_command.state_label` into
  `connected`/`failed`/`stale`/`needs login`. `mcp_list.STATE_WORDS` is the last step to the two-word row.
  An unknown state is printed as its own (bounded) word and never as `connected`.
- "Nothing in a row is cut off at 80 columns" - the old row was cut because it carried a whole sentence of
  description; the new row's widest part is 34 characters (mark, space, 32-character name). Measured by the
  snapshot at 80 and 120 and by `widest()` in both tests.

## The two decisions I had to make, and why

1. **An empty group has no heading.** The renderer draws a heading above the row that starts a group (a
   heading is never a choice, so it cannot be an option of its own without teaching both renderers a
   non-selectable row). On a node with nothing added yet there is no row to carry `User MCPs`, and a heading
   with nothing under it reads as a bug. So the list says it under the count instead:
   `no user connector: nothing has been added on this node`. On every node with one connector in each group -
   which is the case the brief describes, and the capture below - both headings are there, in order.
2. **The peer connector in the capture** comes from the catalogue cache `federation.refresh` keeps, filled
   with a connector composed by `federation`'s own peer-side code (`federation.connectors()`). There is no
   seam to inject a transport into a refresh, and a real two-node rendezvous is not what this mission changes:
   nothing in this change crosses a node boundary (the peer rows arrive already, and only their folding is
   new). The wire is unchanged and is proven by `scripts/test-federation.lua` and
   `scripts/test-two-node-images.lua`. The test says so in its own comment.

## Captures (real scratch node, 80 and 120 columns)

From `scripts/test-mcp-list.lua` (`a8049eaf`) in a scratch home: the registry built through `mcp.control`
(`put`, then `probe`, then `enable`) with one built-in surface (WhatsApp), two user connectors - `Healthy`,
whose probe passed against a real `scripts/fixtures/mcp-peer.mjs` - and `Bills`, whose far end answered `401
unauthorized`, one connector on a peer node and one retired entry. No account name and no connector secret
appears in either capture.

```
---- capture: wa mcp list at 80 ----
MCP servers

3 servers

wasm-agent built-in MCPs
❯ ! WhatsApp                  unknown

User MCPs
  ✔ Healthy                 1 tool
  ! Bills                     needs token
  On other nodes - 1 hidden
  1 retired

Enter opens a connector · Esc or ← closes
---- capture: the same list at 120 ----
MCP servers

3 servers

wasm-agent built-in MCPs
❯ ! WhatsApp                  unknown

User MCPs
  ✔ Healthy                 1 tool
  ! Bills                     needs token
  On other nodes - 1 hidden
  1 retired

Enter opens a connector · Esc or ← closes
```

`wa mcp list` prints that text character for character: the test asserts
`table.concat(printed, "\n") == text80`, where `text80` is `balloon.text` of the same page.

WhatsApp reads `! WhatsApp  unknown` here because a scratch node holds no WhatsApp account and no node in its
fleet says it does: `unknown` is the built-in row's own state word, and the row does not claim `connected`.
The 80-column snapshot of the shared fixture, which HAS a connected WhatsApp, is
`tests/snapshots/balloon/mcp-list-80x24.txt`:

```
MCP servers

5 servers

wasm-agent built-in MCPs
❯ ✔ Gmail                            2 tools
  ✔ WhatsApp                         3 tools

User MCPs
  ✔ Quarterly reports from the acco… 3 tools
  ! Filesystem reads                   not reachable
  ! Gated reports                      needs token
  On other nodes - 2 hidden
  1 retired

Enter opens a connector · Esc or ← closes
```

## Tests

- **`scripts/test-mcp-list.lua` (new, 67 checks)** - wired into the fast path by being a `scripts/test-*.lua`
  that is not in `scripts/fast-path.exclude` (`scripts/fast.sh` runs every such file with its own scratch
  home). It refuses to run against the operator's store (`scripts/lib/scratch-home.lua`) and refuses when no
  node runtime is found, instead of passing on a half-proved row. It measures the rules on the snapshot
  fixture AND on the real scratch store, and prints the two captures above.
- **Changed tests**: `scripts/test-cli-balloon.lua` (the list is two groups, five rows plus two folded rows,
  WhatsApp once, no number, no type/node column, both headings, the published spec carries `numbered` and the
  heading), `scripts/test-mcp-command.lua` (one row per connector on this node, the mark, the two-word state,
  the constructor refused by name, the folded peer page), `scripts/test-hotreload.lua` (its planted edit moved
  from the page title - which now lives in `mcp_list.lua` - to the page hint, which `mcp_command.lua` still
  owns).
- **Snapshots**: `tests/snapshots/balloon/mcp-list-80x24.txt` regenerated, `mcp-list-120x24.txt` added (the
  brief's second capture); `scripts/gen-balloon-snapshots.lua` writes both. The `before-*` snapshots (the old
  path's golden) are untouched.
- **Rust**: `a_group_heading_is_a_row_of_its_own_and_never_a_choice` (wa-term: heading rows, the blank row
  between groups, no `1.`, the selection/Down/Enter indices unchanged, a menu still numbered) and
  `a_page_of_groups_carries_its_headings_and_its_unnumbered_flag` (wa-cli-views: the fields travel through
  `panel_spec`, absent means numbered, a 201-character heading is refused).
- **Discriminating, measured**: `scripts/test-discriminates.sh origin/main` run on this branch names all
  four changed Lua rows `unrevertable` - its own rule, because the branch changes `rust/` and a Lua row would
  run against this tree's binary rather than the base's - so I judged them the way that rule asks, by hand:
  a worktree at the base commit (`345e51be`, never `git stash`) with ONLY the branch's four test files copied
  in, run with the base tree's Lua (`WASM_AGENT_LUA_ROOT=<base>`) and this tree's binary as the host, each in
  its own scratch home. Every one FAILS on the base code:
  `test-mcp-command.lua` - `the list is titled MCP servers: Services`;
  `test-cli-balloon.lua` - `25 failed of 94 checks` (`the list no longer says: services - `, `- 1.`, `on this
  node` ...); `test-hotreload.lua` - `3 of 217 checks failed` (`the NEXT /mcp shows the changed page`);
  `test-mcp-list.lua` - `lua_root_unreadable: .../lua/core/mcp_list.lua`, the module the base does not have.
  The base worktree was removed afterwards.
- **What I ran** on this node (avell), never on a peer. The narrowed fast path, under the suite lock
  (`flock -o ~/Work/missions/.suite.lock`), with `WA_FAST_ROWS` naming the nine rows that touch this change:
  `38 of 375 Lua rows`, `37/38 passed` - the one Lua failure is `scripts/test-release-channel-e2e.lua`, a musl
  channel build (see below) - and `fast result FAILED (145 checks, 5 failed)`. The five, each outside the
  paths this change touches: `release-channel` and `test-release-channel-e2e.lua` (the same musl build),
  `deploy-wait` ("the held wakes run once the deploy ends: still 0"), `esc-stops-pty` (a load-timed pty row: a
  second mission was building on this same node during the run) and `wa-term --test icons`. `icons` is
  reproduced below against the PRE-change binary, so it is not this change's.
- **Per row, by hand** (each in its own scratch `WASM_AGENT_HOME`): `lua5.4 scripts/test-cli-balloon.lua` (95 
  checks),
  `scripts/test-mcp-command.lua` (135), `scripts/test-mcp-list.lua` (67), `scripts/test-local-views.lua` (46),
  `scripts/test-mcp-retired-connector.lua` (17), `scripts/test-whatsapp-one.lua` (207),
  `scripts/test-hotreload.lua` (217), `scripts/test-mcp-vault-approval.lua` (154) - each under its own scratch
  `WASM_AGENT_HOME` - and `cargo test -p wa-term -p wa-cli-views` (222 + 22 + 12 + the small suites, all ok).

## Pre-existing failures, and what I could not check

- `cargo test -p wa-capabilities` fails 6 rows here, none of them touched by this change:
  `capabilities::tests::documented_inventory_matches_the_live_registry` fails because `run_state` is
  registered and missing from `docs/HOST.md` - measured on `origin/main` as well
  (`git show origin/main:docs/HOST.md | grep -c run_state` = 0); `disk::tests` expects a worktree merged into
  `origin/main` (this branch is not); and three `operations::` rows refuse to run under the operator's HOME
  ("this test starts real operations, so HOME must be a scratch or temp directory") - with `HOME=/tmp/cap-home`
  those 51 pass.
- **`wa-term --test icons` is not this change's, measured**: it fails the same way against the binary this
  node already had before the branch (`WA_BIN=/home/victor/.local/bin/wa cargo test -p wa-term --test icons`:
  "the unknown-font line is said ONCE at start: 0", expected 1), so the pty's font measurement on this machine
  no longer produces the notice that row asserts. `release-channel` fails building
  `scripts/release-linux.sh --target x86_64-unknown-linux-musl` in a scratch dir; `deploy-wait` and
  `esc-stops-pty` are timing rows that ran while another mission was building on this same node.
- I did not run the full `scripts/test.sh` gate (it needs the landing lane); I did not build or run anything
  on another node; I did not touch `ui/components.js`, the web panel, whose header line still says `<n>
  services - ... tools callable now`. That panel is a different surface from `/mcp` and is not in this brief.
- I could not check a real peer's catalogue over the wire in this mission (see decision 2), and I could not
  measure the live panel on the laptop: the Rust half is proven by `wa-term`'s own tests, not by a screenshot.

## Texts to approve (Fable)

Every string that is new or changed for a person to read, verbatim, in the order they appear:

1. `MCP servers` (the list's title)
2. `%d servers` -> `1 server`, `3 servers` (under the title)
3. `wasm-agent built-in MCPs` (first heading)
4. `User MCPs` (second heading)
5. `✔` and `!` - the two marks a row can carry (connected, not healthy)
6. `%d tools` -> `1 tool`, `no tool` (the right column of a healthy row)
7. `needs token` (a credential the far end refused)
8. `server changed` (the connector's tool list moved since the approved one)
9. `not reachable` (the last probe or call failed, or the account node is not in the fleet)
10. `disabled` (turned off; nothing failed)
11. `unknown` (the built-in surface's own word when no node says it holds the account)
12. `On other nodes - %d hidden` (the folded row for connectors on other nodes)
13. `%d retired` (the folded row for retired registry entries)
14. `%d not classified` (the folded row for a connector that says neither that this agent ships it nor that
    it was added here - unreachable in practice, kept so nothing is silently hidden)
15. `On other nodes` / `Retired` / `Not classified` (the titles of the pages those rows open)
16. `%d connector%s on another node, folded here rather than repeated above.`
17. `A retired row is one whose program went: its tools are not offered any more.`
18. `These say neither that this agent ships them nor that they were added here.`
19. `<connector> on <node>` (a row inside the folded page, e.g. `whatsapp_native on openclaw`)
20. `no built-in connector: this agent ships none here`
21. `no user connector: nothing has been added on this node`
22. `read-only: a master turns a connector on or off` (replaces the guest's long note, which was cut at 80
    columns)
23. `Enter opens a connector · Esc or ← closes` (the list's hint row)
24. `none: no connector is registered on this node, and no peer exports one.` (was `no service is registered`)
25. `usage: wa mcp list [--all] [--width <columns>]   the MCP connectors this node can use`
26. `  --all     also print the rows the list folds away (other nodes, retired) and each connector`
27. `  --width   the column count to lay the rows out for (80 by default)`
28. `--width takes the column count, 20 or more`
29. `wa mcp list does not take <word>`
30. `    mcp list [--all] [--width <columns>]  the MCP connectors this node can use, in two groups` (in
    `wa help`)

