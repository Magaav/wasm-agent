//! Per-component limits, applied where the store is built (`docs/KERNEL.md`, "Per-component limits").
//!
//! Three runners build three stores (`services::run_once` for wasip1, `service_components::run_once`
//! for `wa:kernel@0.1`, `service_components_v2::run_once` for `wa:kernel@0.2`). If each resolved its
//! own limits from the manifest, a component would get a different memory cap depending on which
//! contract it was built for — the kind of drift the two contract runners exist to avoid everywhere
//! else. So the resolution lives here and every store is built from [`for_service`]:
//!
//! * **memory**: `limits.memory_mb` from the manifest, clamped to `[16, 4096]` and capped by the
//!   node's cap for that component (`wa_governance::component_limits`), applied through
//!   `StoreLimits` - the same mechanism for all three;
//! * **cpu**: `limits.cpu_ms`, capped the same way, turned into a trap by the epoch callback
//!   (`CpuBudget`) so a guest that keeps the CPU inside one window is stopped instead of starving the
//!   node. It is a starvation guard, not an accounting instrument; the heuristic and its risk are in
//!   `wa_governance::component_limits::CpuBudget`.
//!
//! The resolved values are also what the start answer reports, so `services status` can say what a
//! component actually got and which side decided it (`manifest`, `node` or `both`).

use crate::components::Installed;
use std::sync::OnceLock;
use wa_governance::component_limits::{self, Caps, Effective};

/// The node's caps, resolved once per process (a policy file or `WA_COMPONENT_LIMITS` read at the
/// first start). A node that changes its cap restarts; a *component's* limits are re-read on every
/// start, which is the part that changes often.
pub fn caps() -> &'static Caps {
    static CAPS: OnceLock<Caps> = OnceLock::new();
    CAPS.get_or_init(component_limits::Caps::resolve)
}

/// The limits an installed service runs under.
pub fn for_service(installed: &Installed) -> Effective {
    component_limits::effective(&installed.manifest, &installed.name, caps())
}

/// `for_service` against caps a caller supplies (a test, or a caller that just re-read the file).
pub fn for_service_with(installed: &Installed, caps: &Caps) -> Effective {
    component_limits::effective(&installed.manifest, &installed.name, caps)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_runner_resolves_the_same_numbers_from_the_same_manifest() {
        // The three runners call `for_service`; this pins the numbers it yields, and that the node's
        // cap wins over a manifest that asks for more.
        let node_caps = Caps::parse(r#"{"memory_mb": 256, "cpu_ms": 40, "components": {"svc": {"memory_mb": 640}}}"#, "test").unwrap();
        let installed = Installed {
            name: "svc".into(),
            sha256: "0".repeat(64),
            bytes: Vec::new(),
            manifest: json!({"limits": {"memory_mb": 4096, "cpu_ms": 5000}}),
        };
        let effective = for_service_with(&installed, &node_caps);
        assert_eq!((effective.memory_mb, effective.cpu_ms), (640, 40));
        assert_eq!(effective.by, "both", "a clamped value says so");
        // And the process-wide caps never exceed the hard ceiling, whoever wrote them.
        let node = caps();
        assert!((component_limits::MIN_MEMORY_MB..=component_limits::MAX_MEMORY_MB).contains(&node.memory_mb));
        assert!(node.cpu_ms >= component_limits::MIN_CPU_MS);
    }
}
