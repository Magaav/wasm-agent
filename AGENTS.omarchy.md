# Omarchy (this node runs on the user's own desktop)

This node runs directly on Omarchy - Arch Linux with Hyprland, foot or alacritty. None of it is true
of a container or a headless host, which is why it is here and not in `AGENTS.md`.

- Use the `omarchy` CLI (`omarchy theme set <name>`, `omarchy font list`, `omarchy screenshot`): it
  dispatches to the `omarchy-*` commands on PATH, which are equally callable.
- Before editing anything under `~/.config/` - `hypr/`, `foot/`, `alacritty/`, `kitty/`, `ghostty/`,
  `waybar/`, `omarchy/` - load the `omarchy` skill. It is found through `~/.agents/skills`, which
  Omarchy symlinks to its own tree, and it carries the per-area guide; this file is not a substitute.
- Never hand-edit `/usr/share/omarchy` or `~/.local/share/omarchy`: the package owns them and
  `omarchy update` overwrites them. Read them freely, and copy into `~/.config/` to change something.
- Hyprland 0.56+ takes dispatchers as Lua: a binding is `o.bind(..., hl.dsp.window.close())` and a
  script is `hyprctl dispatch 'hl.dsp...'`. The pre-0.56 dispatcher words (closewindow, workspace,
  exec) fail with "expected a dispatcher"; that error is the old syntax, not a missing feature.
- Apply and verify with `hyprctl reload` then `hyprctl configerrors`. `hyprsunset.conf` and
  `xdph.conf` are read by other processes, so those restart with `omarchy restart hyprsunset`; never
  restart the session or the compositor to make a config change take.
