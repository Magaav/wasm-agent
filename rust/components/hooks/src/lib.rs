//! The hooks/mods engine as a component (`docs/CORE-SPLIT.md`, `docs/HOOK-EVENTS.md`): an export per
//! seam operation and no state between calls.
//!
//! What is here: the pure half of `lua/core/hooks.lua` — the config sources and both config shapes,
//! matchers, ordering, per-hook timeouts, the Claude Code compatible protocol's interpretation, the
//! bounds, the mods surface (`statusline`, custom commands, keybindings) and the catalogue.
//!
//! What is deliberately **not** here, because it needs the node rather than a decision:
//!
//! * reading the operator's config files — a component has neither a path to `~/.wasm-agent` nor a
//!   grant to it, so the node reads and hands the text over;
//! * running a hook — a command hook is a process with the node's grants and a Lua plugin hook is a
//!   function in the node's interpreter, so the node runs it and hands the row over;
//! * the payload's envelope (`session_id`, `run_id`, `cwd`, `node_id`, `role`) — the host owns
//!   identity and time;
//! * the process-wide outcome log, `/hooks`' rendering and the redactor — the node's log boundary.
//!
//! The component has **no capability grant at all**: its manifest declares no `capabilities`, and its
//! world imports nothing, so a mod cannot reach a capability through the engine (docs/HOOKS.md,
//! "Grants"; `scripts/test-hooks-component.lua` asserts the manifest and the artifact's imports).
use crate::exports::wa::hooks::hooks::Guest;
use crate::wa::hooks::types::{
    Bounds, ConfigFacts, ConfigRequest, DecideRequest, EntriesRequest, Entry, Error, EventFacts,
    SegmentRequest, Step,
};

wit_bindgen::generate!({ path: "../../../wit/hooks", world: "hooks-component", generate_all });

mod logic;

struct HooksComponent;

impl Guest for HooksComponent {
    fn catalogue() -> Vec<EventFacts> {
        logic::catalogue()
    }

    fn engine_bounds() -> Bounds {
        logic::bounds()
    }

    fn configure(request: ConfigRequest) -> Result<ConfigFacts, Error> {
        Ok(logic::configure(&request))
    }

    fn entries(request: EntriesRequest) -> Result<Vec<Entry>, Error> {
        if request.event.is_empty() {
            return Err(Error::Refused("hook_event_required".to_string()));
        }
        Ok(logic::entries(&request))
    }

    /// One hook's answer, one step: the verdict so far plus this row, and whether the event ends.
    /// Called once per hook, in run order, because only a verdict can say whether the next hook
    /// still runs (the native loop breaks on a refusal).
    fn decide(request: DecideRequest) -> Result<Step, Error> {
        if request.entry.name.is_empty() || request.entry.event.is_empty() {
            return Err(Error::Refused("hook_entry_unnamed".to_string()));
        }
        let step: Step = logic::decide(&request.payload, request.prior, &request.event, &request.entry, &request.row);
        Ok(step)
    }

    fn segment(request: SegmentRequest) -> String {
        logic::segment(&request)
    }
}

export!(HooksComponent);
