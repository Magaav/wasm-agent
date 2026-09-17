@echo off
rem Launch the wasm-agent CLI with its Lua core read from THIS checkout, so edits
rem to lua/ take effect immediately with the installed binary - no rebuild, and
rem therefore no Rust toolchain needed. This is what makes self-evolution work on
rem a Windows node.
rem
rem Recovery: if the on-disk Lua breaks, run plain `wa chat` (embedded Lua) or
rem `git checkout -- lua/`.
setlocal
set "WASM_AGENT_LUA_ROOT=%~dp0.."
wa chat %*
