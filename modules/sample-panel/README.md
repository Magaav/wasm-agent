# sample-panel

The worked example of a module: one directory, one manifest, one panel. It exists to be deleted
and put back, which is the property the module system is for.

- **id** `sample-panel` — the directory name is the id; nothing else names it.
- **tag** `module-sample-panel-v0.1.0` — the marker to recover it from, made when it was added.
- **attaches to** `wa-window` · slot `panel` (the host page renders the slot; attaching the host
  to the window itself is a separate step, see `docs/MODULES.md`).
- **entry** `panel.html`
- **capabilities** `panel` (granted: the host mounts it), `network` (**not** granted: the host
  renders a visible refusal beside the panel, and the panel's frame is sandboxed without
  same-origin, so it cannot quietly do it anyway).
- **enabled** false. A module nobody asked for changes nothing on screen. Ask for it with
  `WASM_AGENT_MODULES=sample-panel` (or set `"enabled": true` here — still one directory).

## Remove it

```bash
git rm -r modules/sample-panel
git commit -m "remove module sample-panel"
```

That is the whole removal: no route, no registry and no document outside this directory names the
module, so deleting the directory is deleting it. `bash scripts/test-modules-removal.sh` proves
it — and asserts the "nothing outside names it" half rather than trusting it.

## Put it back

```bash
git checkout module-sample-panel-v0.1.0 -- modules/sample-panel
```

The tag is on the manifest, so this works after the removal is committed and merged. If the tag
was never pushed: `git checkout <commit> -- modules/sample-panel`, or restore the directory from
your last build of it.
