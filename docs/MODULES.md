# Modules — a feature that is one directory

A module is `modules/<id>/`, and nothing else. Adding one is creating that directory and its
manifest; removing one is deleting it. No registry, no route table, no list in a document: a
registry is exactly the thing that leaves a reference behind when the feature goes, and the whole
point of this system is that it cannot.

The example module (`modules/<id>/` beside this file's subject — see the removal test, which finds
the module rather than naming it) is a panel that renders one string and declares a capability this
host does not grant, so a refusal is visible rather than silent.

## The manifest

`modules/<id>/module.json`:

| field | meaning |
| --- | --- |
| `id` | the module's identity. It must equal the directory name, and a manifest that claims another id is reported as an issue rather than mounted under a name nobody can find. |
| `name`, `version`, `description` | what the host page shows on the panel. |
| `tag` | the git tag the module is recovered from (`module-<id>-v<version>`). |
| `attach` | `{ "surface": ..., "slot": ... }` — where the module wants to be mounted. The host page renders the slot; attaching to the window itself is a later step. |
| `entry` | the file the host loads for the module, relative to the module directory. |
| `capabilities` | what the module declares it needs. Everything not granted is refused **in the listing**, which is what the host page renders as a badge. |
| `enabled` | optional. `true` means the module asks for itself; a module nobody asked for changes nothing on screen. |

## Discovery, by convention and with no per-module code

`lua/core/modules.lua` is the whole system: it lists `modules/` with `host.list_dir`, reads each
directory's `module.json`, and answers with the modules that are actually on disk. There is no place
to add a line when a module appears and no place to remove one when it goes.

The route is a Lua function in the shape the Rust dispatch table calls a positional handler with:

```
wa_modules(op, id, path, session) -> a JSON envelope { status, content_type, body }
```

`op` is `list` (or empty) for the listing, `file` for a file. It is registered in
`rust/wa-host/src/serve.rs` (the `/modules` arms) and loaded by `lua/core/server.lua`, which is the
whole of the node's side: the status in the envelope is kept, so 403 and 404 stay the module
system's decisions, and the content type is mapped onto the static string a reply carries — a type
the node does not know is served as bytes rather than guessed at.

**Adding or removing a module needs no Rust and no restart.** A module is a directory; the route
reads the directory per request. What the node does need is the URL space below, which is fixed by
the page's own relative URLs:

| request | answer |
| --- | --- |
| `GET /modules` | `301` to `/modules/` — the page is served at the root of that space **and the trailing slash is the contract**: a module is a sibling of the page, so a page served at `/modules` resolves every panel one level outside the tree |
| `GET /modules/` | the host page (`modules/index.html`) |
| `GET /modules/index.json` | the listing, computed on every request by reading the directory. Not a file on disk — a checked-in copy would survive a deletion and lie |
| `GET /modules/<id>/<path>` | the module's own file. `404` if the id is not a module directory, `403` if the module is not enabled, `400` if the path tries to leave the directory. `/modules/<id>` alone is the module's entry point |
| anything else under `/modules/` | `404` |

A path containing `..` is refused by the node's own static-route guard before the interpreter sees
it, for every route alike (`static_reply` in `serve.rs`); the route refuses a leading slash, a
backslash or a drive colon itself. Both answers are `400`.

Modules are **off unless asked for**: `WASM_AGENT_MODULES=<id>,<id>` for a node, or `"enabled": true`
in the module's own manifest. `WASM_AGENT_MODULE_CAPABILITIES=<name>` grants a capability — it exists
so the refusal badge can be *falsified*: grant what a module declares and the badge has to go.

The host page is `modules/index.html`. It holds no list of modules; it fetches the listing beside
itself and mounts only the ids in the listing's `mounted` list, each in a sandboxed frame with an
opaque origin, and renders every refused capability as a badge. It is also a static page: copy
`modules/` anywhere, put the route's listing beside the copy's `index.html`, and a headless browser
renders it — which is how the render half of the proof runs.

## Add a module

```bash
mkdir -p modules/<id>            # module.json, the entry file, whatever else the module needs
git add modules/<id>
git tag module-<id>-v<version>   # the tag named in its own module.json
```

That is the whole add. Nothing outside `modules/<id>/` was edited, and the removal proof asserts
that no file outside it names the id.

## A new Lua core file (for the next route, not for a module)

There is no module-and-nothing-else exemption at the node level, and two places have to learn about a
new `lua/core/*.lua`: the binary's `EMBEDDED` registry in `rust/wa-host/src/main.rs` (or the gate
stops at *"on disk but not in the binary"* and an installed node cannot load it at all), and the
`dofile` list at the top of `lua/core/server.lua` (or `wa_*` does not exist in a running node and the
route answers 500 while every Lua-level test stays green). Adding a *module* touches neither.

## Remove a module

```bash
git rm -r modules/<id>
git commit -m "remove module <id>"
```

That is the whole removal. An ask that still names the id (`WASM_AGENT_MODULES=<id>`) is an ask about
nothing, not an error: the page mounts nothing and reports no problem, and the test asserts both.

## Put it back

```bash
git checkout module-<id>-v<version> -- modules/<id>
```

The tag is in the manifest, so this works after the removal is committed and merged. Without the
tag, `git checkout <commit> -- modules/<id>` from the commit that last held it.

## The proof

```bash
bash scripts/test-modules-removal.sh            # the hermetic proof, no browser
bash scripts/test-modules-removal.sh --render   # and the headless render (WA_OBSERVER=<path>, Chrome)
```

The script runs on a **scratch copy** of the tree (every tracked file plus untracked files git does
not ignore), because a test of deletion must not be able to damage the tree it tests. It finds its
subject rather than naming it — the first directory under `modules/` that carries a manifest, so it
can be run in the state it exists for. In order:

- **(a)** with the directory present: the listing reports the module, mounts it when asked for,
  carries its tag and its surface, and the route harness passes on the same tree;
- **(d)** before the deletion: no file outside `modules/<id>/` names the id;
- **(b)** after `rm -rf modules/<id>`: the listing no longer counts it, nothing is mounted, the ask
  that still names it is not an error, the id appears nowhere in the listing, and the removal is
  timed;
- **(c)** with `--render`: the host page mounts nothing for it, renders no error banner, and the
  module's files do not answer (HTTP 404) — while the same page with the module enabled mounts it,
  shows its refusal badge, and serves its entry;
- **recovery**: the directory is restored from the copy taken before the deletion and compared
  byte-for-byte with the tree's own.

`scripts/test-modules.lua` is the route's own harness: off/on/granted/absent, byte-for-byte file
serving, the refusal of a capability this host does not grant, path escapes refused, and 404s that
are 404s. `scripts/test-modules-host.mjs` is the render helper: it stages the module tree as a node
serves it, writes the listing by *asking the route*, and asserts from a probe inside the rendered
page.

## What is not enforced, and what a module cannot do

Stated plainly, because "declares a capability it is not granted" is easy to read as enforcement:

- The refusal is **visible and asserted** (a badge in the page, `refused` in the listing), and the
  frame is sandboxed without same-origin, so a module cannot reach the host page. But nothing
  *denies* a module the capability at the point of use: that needs a route-delivered header (a
  `Content-Security-Policy` on the module's own response), which is a Rust/binding change and is not
  in this change.
- `host.read_file` is UTF-8 text, so the route serves text files only. A module with binary assets
  needs a bytes-capable host call, not a different route.
- The route takes the session and deliberately ignores it: a listing reads the disk and grants
  nothing. Whatever authority a module listing should require is a decision for the Rust line.
