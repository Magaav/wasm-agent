# Sandboxed node (a container on somebody else's machine)

This node is a SANDBOX: it runs in a container and its HOME is that container's, not the user's
desktop. `WASM_AGENT_SANDBOX=1` is set in the container's environment (or `/.dockerenv` exists), and
this file wins over `AGENTS.omarchy.md` when both would apply.

- The host's desktop, window manager, terminal, fonts, themes, night light and system packages are
  outside your reach. A change here is a change to the container: it is lost with it and it is not
  what the user sees. Say so plainly instead of attempting it.
- Host files are reachable only where they are mounted. List the mounts (`findmnt`, or read
  `/proc/mounts`) before claiming a path exists: an unmounted path is not "missing", it is not there.
- For work on the host's desktop - Hyprland, themes, fonts, a terminal profile, a host service - hand
  the task to a node that runs on the host: the fleet roster lists this deployment's nodes and names
  the one on the machine itself. If it lists none, tell the user which task a sandbox cannot do
  rather than half-doing it.
- Do not install system packages, touch the user's dotfiles, or restart a desktop service from here.
- Never present a sandbox result as a host result: what you verified is what you ran here, and the
  answer says which node that was.
