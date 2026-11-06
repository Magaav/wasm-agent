# Mods: the reader's own surfaces, from the same config files as hooks

A mod is a hook that answers the *reader* instead of the run. It is configured beside the hooks
(`mods`, in `~/.wasm-agent/hooks.json` or `<project>/.wasm-agent/hooks.json`, see
[HOOKS.md](HOOKS.md)) and it runs through the same engine, the same per-command timeout and the same
output cap - so a mod cannot hold the REPL or flood the screen.

```json
{
  "mods": {
    "statusline": [
      { "name": "branch", "command": "git rev-parse --abbrev-ref HEAD", "timeout_ms": 5000 }
    ],
    "commands": [
      { "name": "/hello", "description": "say hello", "command": "~/.wasm-agent/hooks/hello.sh" }
    ],
    "keybindings": [
      { "key": "ctrl+g", "command": "git status", "description": "show the working tree" }
    ]
  }
}
```

## Footer segments (`statusline`)

Each `statusline` command receives one JSON object on stdin - `hook_event_name: "StatusLine"`,
`session_id`, `cwd`, `model`, `runs`, `tokens`, `context`, `context_percent` - and its **stdout** is a
segment of the CLI footer, next to the self-wake count:

```
↻3 ⚒️12 ↑18.2k ↓940 · ctx 41.2%/200.0k · main
```

Rules, all deliberate:

* One line. Newlines become spaces; a segment is clipped to 160 bytes plus an ellipsis and a mod
  cannot take the whole row.
* Cached for 10 seconds per session and model (`hooks.STATUSLINE_TTL_MS`). The footer is redrawn far
  more often than a shell command can answer, and a segment that is three seconds stale is honest
  where a blocked REPL is not.
* A segment that fails or exits non-zero appears as `!<name>`; the footer names the broken mod rather
  than quietly showing one fact fewer. A timeout yields the same marker plus one line on the node log.
* Empty stdout adds nothing to the row.
* The window reads one segment too, through `POST /jobs {action:"hooks_status"}`, cached for 30
  seconds. It is a request, not a push: a segment does not update while a run streams.

## Slash commands (`commands`)

A custom command is a word typed into the composer or the REPL: `/<name>` and optional arguments. The
command receives the payload JSON on stdin (`hook_event_name: "Command"`, `name`, `args`, `session_id`,
`cwd`) and its stdout is what the reader sees.

* The REPL prints the output verbatim. The window prints it in the transcript for `/hooks`; custom
  commands are available in the REPL today and their output is what `/hooks` lists.
* An unknown `/word` is still a refusal, not a model turn: a typo must not start a run with tools.
* A Lua module can register a command instead of a config entry:
  `hooks.register_command('/name', function(args) return 'text' end, { description = '…' })`.
* Built-in commands are unaffected: `/hooks` is the only new row, and it is in `lua/core/commands.lua`
  with the others (the parity check `scripts/test-command-parity.cjs` holds the REPL, the window and
  the arms together).

## Key declarations (`keybindings`)

`keybindings` are parsed, validated and listed by `/hooks` - and **nothing dispatches them yet**: this
CLI has no configurable key surface (the native editor owns input, and the terminal hands over keys,
not commands). Recording the declaration is the honest state; a `keybindings` block that pretended to
bind a key would be a promise the process cannot keep.

## Toasts (`systemMessage`)

A hook's `systemMessage` is the third mod surface and it needs no config of its own: any hook that
prints `{"systemMessage": "..."}` produces one line the reader sees, through the same `status` event
every other notice uses - so the CLI, the window and a replay show the same sentence. A hook that
denies a call can therefore say why in one line even when the refusal already carries a reason.

## Tests

`scripts/test-hooks-mods.lua`: a footer segment (with the model in its payload, one line, clipped,
cached, and a broken segment named), a custom command (with its arguments, and a refusal for an
unknown one), a Lua command, and the `/hooks` report that lists all of it. Hermetic and model-free.
