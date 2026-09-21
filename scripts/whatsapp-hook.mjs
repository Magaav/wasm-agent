// The document-start hook, in one place: the adapter installs it to *learn*, and the sentinel's cdp
// trigger installs the same source as its setup_expression so the page keeps it across reloads.
//
// It must be idempotent (the setup can run more than once) and fail open: it runs before the app's
// code, so a mistake here breaks the page rather than the call.
export const HOOK = [
  "(() => {",
  "  const state = window.__wa_adapter = window.__wa_adapter || { names: [], factories: {}, rewraps: 0, errors: [], polls: 0 };",
  "  const note = (name, factory) => {",
  "    if (typeof name !== 'string' || !name) return;",
  "    if (!(name in state.factories)) state.names.push(name);",
  "    state.factories[name] = factory;",
  "  };",
  "  const wrap = (original) => {",
  "    if (typeof original !== 'function') return original;",
  "    const wrapped = function (name, deps, factory) {",
  "      try { note(name, factory); } catch (e) { state.errors.push('note: ' + String(e).slice(0, 50)); }",
  "      return original.apply(this, arguments);",
  "    };",
  "    wrapped.__wa_wrapped = true;",
  "    return wrapped;",
  "  };",
  "  const install = () => {",
  "    const current = window.__d;",
  "    if (typeof current !== 'function') return false;",
  "    if (current.__wa_wrapped) return true;",
  "    const wrapped = wrap(current);",
  "    try { window.__d = wrapped; } catch (e) { state.errors.push('assign: ' + String(e).slice(0, 50)); return false; }",
  "    return window.__d === wrapped;",
  "  };",
  "  const tick = () => {",
  "    state.polls += 1;",
  "    try { if (install()) state.rewraps += 0; } catch (e) { state.errors.push('tick: ' + String(e).slice(0, 50)); }",
  "    if (state.polls < 1200) setTimeout(tick, 250);",
  "  };",
  "  tick();",
  "})();",
].join("\n");
