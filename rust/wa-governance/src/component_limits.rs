//! The node's cap on what one component may spend: CPU time per epoch window and memory.
//!
//! A component's manifest *declares* its own limits (`limits: {memory_mb, cpu_ms}`); the node
//! *caps* them (`docs/KERNEL.md`, "Per-component limits"). The effective value is
//! `min(declared, node cap)`, and the answer always says which of the two won, because a component
//! that is quietly given less than it declared is a support ticket and one that is quietly given
//! more is a bug.
//!
//! Where the node cap lives, in order of precedence:
//!
//! 1. `WA_COMPONENT_LIMITS` — a JSON object (a test or an operator override);
//! 2. the `limits` object of the node's grant policy file (`WA_GRANT_POLICY`, else
//!    `<state>/policy.json`) — the file the operator already owns, read here *without* the policy
//!    engine so an unrelated policy section can never make limits unreadable;
//! 3. `<state>/limits.json` — a node that wants limits without a policy file;
//! 4. the built-in defaults ([`DEFAULT_MEMORY_MB`], [`DEFAULT_CPU_MS`]).
//!
//! Shape (any of them):
//!
//! ```json
//! {"memory_mb": 512, "cpu_ms": 5000,
//!  "components": {"wa-whatsapp": {"memory_mb": 768, "cpu_ms": 100}}}
//! ```
//!
//! A malformed `limits` section is *reported* (in the answer and on the log) and the defaults are
//! used: limits are a resource boundary, not a security boundary — the security boundary is the
//! grant/policy layer — so a broken knob must not stop a node, and it must not silently widen one
//! either, which is why the fallback is the default rather than "no limit".
//!
//! Nothing here reads a clock or a component: this module resolves numbers.

use serde_json::{json, Value};
use std::path::PathBuf;

/// Memory a component gets when neither it nor the node says anything.
pub const DEFAULT_MEMORY_MB: u64 = 512;
/// The floor: a store below this cannot load a component that does anything.
pub const MIN_MEMORY_MB: u64 = 16;
/// The ceiling a manifest or a node cap is clamped to (`u32` wasm memories in practice).
pub const MAX_MEMORY_MB: u64 = 4096;
/// CPU a guest may keep the processor for, inside one window, before it is trapped - when nobody says
/// otherwise.
///
/// 5 s, and the number is a finding rather than a guess. The first default tried here was 50 ms, and it
/// trapped `svc-echo-v1` mid-`wa_http` poll: a `wa:kernel@0.1` guest is *supposed* to poll (the 0.1
/// contract is sync calls plus non-blocking polls), so a tight poll loop is normal behaviour there, not
/// a runaway. A budget shorter than a legitimate poll wait turns a contract into a bug. 5 s keeps what
/// the guard is for - a guest that never yields to the host cannot hold the processor indefinitely -
/// while leaving every polling and every slow host call alone; a node that wants tighter numbers writes
/// [`Caps::cpu_ms`] or a per-component row. This is still a starvation guard, not an accounting
/// instrument: the measure is wall-clock time between epoch firings, so a guest that is *preempted* by
/// the OS looks parked and the budget errs towards running longer.
pub const DEFAULT_CPU_MS: u64 = 5_000;
/// Below this a window is shorter than the epoch tick and every guest is trapped: the floor.
pub const MIN_CPU_MS: u64 = 10;

/// A guest that must wait longer than this per window is a stuck guest, not a slow one.
pub const MAX_CPU_MS: u64 = 60_000;

/// What the node allows, per component with a default row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caps {
    pub memory_mb: u64,
    pub cpu_ms: u64,
    pub components: std::collections::BTreeMap<String, (Option<u64>, Option<u64>)>,
    /// Where the caps came from (`env`, `policy`, `limits.json`, `default`), and the parse error when
    /// the source was there but unusable. Read by `host.service status` and the tests.
    pub source: String,
    pub error: Option<String>,
}

impl Default for Caps {
    fn default() -> Caps {
        Caps { memory_mb: DEFAULT_MEMORY_MB, cpu_ms: DEFAULT_CPU_MS, components: Default::default(), source: "default".into(), error: None }
    }
}

impl Caps {
    /// Parse one `limits` object. Unknown keys are ignored (the section is shared with future
    /// knobs); a value that is present and not a positive integer is an error, never a silent
    /// default, so a typo is visible.
    ///
    /// `Ok(None)` means "this document says nothing about limits" - a policy file with rules and no
    /// `limits` section is not an error and must not shadow the next source.
    pub fn parse_document(text: &str, source: &str) -> Result<Option<Caps>, String> {
        let value: Value = serde_json::from_str(text).map_err(|e| format!("limits_json_invalid:{e}"))?;
        // `{"limits": {...}}` (a policy file) and `{...}` (a limits file or the env override) both work;
        // a document that names neither `limits` nor a limit key is silent, not empty-by-accident. A
        // policy file's own `components` carry `capabilities`; a limits document's carry
        // `memory_mb`/`cpu_ms`, which is how the two are told apart without a schema field.
        let looks_like_limits = value.get("memory_mb").is_some()
            || value.get("cpu_ms").is_some()
            || value
                .get("components")
                .and_then(Value::as_object)
                .is_some_and(|rows| {
                    rows.values().any(|row| {
                        row.get("memory_mb").is_some() || row.get("cpu_ms").is_some() || row.get("capabilities").is_none() && row.is_object()
                    })
                });
        let section = match value.get("limits") {
            Some(section) => section,
            None if looks_like_limits => &value,
            None => return Ok(None),
        };
        let Some(object) = section.as_object() else { return Err("limits_not_an_object".into()) };
        let mut caps = Caps { source: source.into(), ..Caps::default() };
        let number = |field: &str, value: &Value| -> Result<u64, String> {
            let n = value.as_u64().ok_or_else(|| format!("limits_not_a_positive_integer:{field}"))?;
            if n == 0 {
                return Err(format!("limits_not_a_positive_integer:{field}"));
            }
            Ok(n)
        };
        if let Some(value) = object.get("memory_mb") {
            caps.memory_mb = number("memory_mb", value)?.clamp(MIN_MEMORY_MB, MAX_MEMORY_MB);
        }
        if let Some(value) = object.get("cpu_ms") {
            caps.cpu_ms = number("cpu_ms", value)?.clamp(MIN_CPU_MS, MAX_CPU_MS);
        }
        if let Some(components) = object.get("components") {
            let components = components.as_object().ok_or_else(|| "limits_components_not_an_object".to_string())?;
            for (name, row) in components {
                let row = row.as_object().ok_or_else(|| format!("limits_components_not_an_object:{name}"))?;
                let memory = row.get("memory_mb").map(|v| number("memory_mb", v)).transpose()?;
                let cpu = row.get("cpu_ms").map(|v| number("cpu_ms", v)).transpose()?;
                caps.components.insert(
                    name.clone(),
                    (memory.map(|m| m.clamp(MIN_MEMORY_MB, MAX_MEMORY_MB)), cpu.map(|c| c.clamp(MIN_CPU_MS, MAX_CPU_MS))),
                );
            }
        }
        Ok(Some(caps))
    }

    /// `parse_document` for a document that is known to carry limits: used by the tests and by a
    /// caller that asked for this one source.
    pub fn parse(text: &str, source: &str) -> Result<Caps, String> {
        Ok(Self::parse_document(text, source)?.unwrap_or_else(|| Caps { source: source.into(), ..Caps::default() }))
    }

    /// The node's caps: the first source that exists, parses, and says something wins; a source that
    /// exists and does not parse is reported and the next one is tried, finally the defaults.
    pub fn resolve() -> Caps {
        let mut last_error = None;
        for (text, source) in sources() {
            match Caps::parse_document(&text, &source) {
                Ok(Some(caps)) => return caps,
                Ok(None) => continue,
                Err(error) => {
                    eprintln!("[limits] {source}: {error} (falling back)");
                    last_error = Some(format!("{source}:{error}"));
                }
            }
        }
        Caps { error: last_error, ..Caps::default() }
    }

    pub fn memory_cap(&self, component: &str) -> u64 {
        self.components.get(component).and_then(|row| row.0).unwrap_or(self.memory_mb)
    }

    pub fn cpu_cap(&self, component: &str) -> u64 {
        self.components.get(component).and_then(|row| row.1).unwrap_or(self.cpu_ms)
    }

    pub fn to_json(&self) -> Value {
        json!({
            "source": self.source,
            "error": self.error,
            "memory_mb": self.memory_mb,
            "cpu_ms": self.cpu_ms,
            "components": self.components.iter().map(|(name, (memory, cpu))| json!({
                "name": name,
                "memory_mb": memory,
                "cpu_ms": cpu,
            })).collect::<Vec<_>>(),
        })
    }
}

/// The candidate limits sources, most specific first: what the environment says, the policy file,
/// the node's limits file. Only sources that exist are returned, so the first hit is the winner.
fn sources() -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Ok(text) = std::env::var("WA_COMPONENT_LIMITS") {
        if !text.trim().is_empty() {
            out.push((text, "env".to_string()));
        }
    }
    let policy = std::env::var("WA_GRANT_POLICY")
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::store::state_root().join("policy.json"));
    if let Ok(text) = std::fs::read_to_string(&policy) {
        out.push((text, "policy".to_string()));
    }
    let limits = crate::store::state_root().join("limits.json");
    if let Ok(text) = std::fs::read_to_string(&limits) {
        out.push((text, "limits.json".to_string()));
    }
    out
}

/// The limits one component runs under: what its manifest declared, capped by the node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Effective {
    pub memory_mb: u64,
    pub cpu_ms: u64,
    /// `memory_mb` / `cpu_ms` / `both` / `manifest` / `node` / `default`: which side decided. The
    /// answer is deliberately explicit - a component given less than it declared must be able to
    /// find out why from the supervisor, not by comparing numbers.
    pub by: &'static str,
}

/// `min(declared, node cap)` for one component, from its manifest.
///
/// A manifest that declares nothing gets the node cap (which is the default when the node says
/// nothing); a declared value above the cap is clamped, and [`Effective::by`] says so.
pub fn effective(manifest: &Value, name: &str, caps: &Caps) -> Effective {
    let declared = manifest.get("limits");
    let declared_memory = declared.and_then(|l| l.get("memory_mb")).and_then(Value::as_u64);
    let declared_cpu = declared.and_then(|l| l.get("cpu_ms")).and_then(Value::as_u64);
    let memory_cap = caps.memory_cap(name);
    let cpu_cap = caps.cpu_cap(name);
    let memory_mb = declared_memory.map(|m| m.clamp(MIN_MEMORY_MB, MAX_MEMORY_MB)).unwrap_or(memory_cap).min(memory_cap);
    let cpu_ms = declared_cpu.map(|c| c.clamp(MIN_CPU_MS, MAX_CPU_MS)).unwrap_or(cpu_cap).min(cpu_cap);
    let memory_clamped = declared_memory.is_some_and(|m| m.clamp(MIN_MEMORY_MB, MAX_MEMORY_MB) > memory_cap);
    let cpu_clamped = declared_cpu.is_some_and(|c| c.clamp(MIN_CPU_MS, MAX_CPU_MS) > cpu_cap);
    let by = match (declared_memory.is_some() || declared_cpu.is_some(), memory_clamped || cpu_clamped) {
        (false, _) => "node",
        (true, true) => "both",
        (true, false) => "manifest",
    };
    Effective { memory_mb, cpu_ms, by }
}

/// A guest's CPU budget across epoch windows: how the runners turn `cpu_ms` into a trap.
///
/// The epoch ticker fires every `tick`; each firing is one sample. A sample that arrives within
/// [`CpuBudget::PARKED`] of the previous one means the guest was *executing* for that gap, and the
/// gaps are summed; a longer gap means the guest was parked in a host call or a timer, so the
/// window restarts (otherwise a component that waits 30 s for a message would be killed for it).
/// When the sum passes `cpu_ms` the budget is spent and the caller traps with `cpu_limit`.
///
/// This is a measurement of "the guest kept the CPU", not of CPU instructions: an async guest that
/// yields often is never trapped, and one that loops inside a single call is. The risk is named in
/// `docs/KERNEL.md`: a guest that is *preempted by the OS* mid-loop looks parked for that gap, so
/// the budget errs on the side of running longer - the trap is a starvation guard, not an accounting
/// instrument.
pub struct CpuBudget {
    budget: std::time::Duration,
    window: std::time::Instant,
    last: std::time::Instant,
}

impl CpuBudget {
    /// Two ticks: an executing guest is sampled every tick, a parked one is not.
    pub const PARKED: std::time::Duration = std::time::Duration::from_millis(60);

    pub fn new(cpu_ms: u64, now: std::time::Instant) -> CpuBudget {
        CpuBudget {
            budget: std::time::Duration::from_millis(cpu_ms.clamp(MIN_CPU_MS, MAX_CPU_MS)),
            window: now,
            last: now,
        }
    }

    /// One epoch firing. `true` means the budget is spent and the caller must trap.
    pub fn sample(&mut self, now: std::time::Instant) -> bool {
        let gap = now.saturating_duration_since(self.last);
        self.last = now;
        if gap > Self::PARKED {
            // Parked (or preempted): the window the guest is charged for starts now.
            self.window = now;
            return false;
        }
        now.saturating_duration_since(self.window) > self.budget
    }

    pub fn budget(&self) -> std::time::Duration {
        self.budget
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn a_manifest_above_the_node_cap_is_clamped_and_says_so() {
        let caps = Caps::parse(r#"{"memory_mb": 512, "cpu_ms": 50, "components": {"big": {"memory_mb": 1024}}}"#, "test").unwrap();
        let manifest = json!({"limits": {"memory_mb": 4096, "cpu_ms": 1000}});
        let clamped = effective(&manifest, "big", &caps);
        assert_eq!(clamped.memory_mb, 1024, "the node's per-component cap wins");
        assert_eq!(clamped.cpu_ms, 50, "the node default caps the declared cpu");
        assert_eq!(clamped.by, "both");
        let small = effective(&json!({"limits": {"memory_mb": 128, "cpu_ms": 20}}), "big", &caps);
        assert_eq!((small.memory_mb, small.cpu_ms, small.by), (128, 20, "manifest"));
    }

    #[test]
    fn a_manifest_that_declares_nothing_gets_the_node_cap() {
        let caps = Caps::parse(r#"{"memory_mb": 256, "cpu_ms": 40}"#, "test").unwrap();
        let inherited = effective(&json!({}), "x", &caps);
        assert_eq!((inherited.memory_mb, inherited.cpu_ms, inherited.by), (256, 40, "node"));
        // And the built-in defaults when the node says nothing either.
        let defaults = Caps::default();
        let fallback = effective(&json!({}), "x", &defaults);
        assert_eq!((fallback.memory_mb, fallback.cpu_ms), (DEFAULT_MEMORY_MB, DEFAULT_CPU_MS));
        // The floor and the ceiling still apply to a declared value.
        assert_eq!(effective(&json!({"limits": {"memory_mb": 1}}), "x", &defaults).memory_mb, MIN_MEMORY_MB);
    }

    #[test]
    fn a_broken_limits_section_is_an_error_not_a_default() {
        assert!(Caps::parse(r#"{"limits": {"memory_mb": "lots"}}"#, "test").unwrap_err().contains("memory_mb"));
        assert!(Caps::parse(r#"{"limits": {"cpu_ms": 0}}"#, "test").unwrap_err().contains("cpu_ms"));
        assert!(Caps::parse("not json", "test").is_err());
        // A policy file is a full document: the `limits` section is what is read, and everything
        // around it is ignored.
        let caps = Caps::parse(r#"{"version": 1, "components": {"wa": {"capabilities": {}}}, "limits": {"cpu_ms": 30}}"#, "policy").unwrap();
        assert_eq!(caps.cpu_ms, 30);
        assert!(caps.components.is_empty(), "the policy's own `components` is not the limits' one");
        // A policy file with rules and no `limits` section says nothing about limits: it must not be
        // read as an empty limits object that shadows the node's own file.
        let silent = r#"{"version": 1, "components": {"wa-whatsapp": {"capabilities": {"net.dial": {}}}}}"#;
        assert!(Caps::parse_document(silent, "policy").unwrap().is_none());
        assert!(Caps::parse_document(r#"{"version": 1}"#, "policy").unwrap().is_none());
    }

    #[test]
    fn the_budget_counts_execution_and_restarts_when_the_guest_parks() {
        let base = Instant::now();
        let mut budget = CpuBudget::new(30, base);
        // Every 10 ms for 40 ms: spent.
        assert!(!budget.sample(base + Duration::from_millis(10)));
        assert!(!budget.sample(base + Duration::from_millis(20)));
        assert!(!budget.sample(base + Duration::from_millis(30)));
        assert!(budget.sample(base + Duration::from_millis(41)), "30 ms of execution in one window is the budget");
        // A parked guest: a 500 ms gap restarts the window, so the next samples are free again.
        let mut budget = CpuBudget::new(30, base);
        assert!(!budget.sample(base + Duration::from_millis(400)));
        assert!(!budget.sample(base + Duration::from_millis(410)));
        assert!(!budget.sample(base + Duration::from_millis(430)), "20 ms into the new window");
        assert!(budget.sample(base + Duration::from_millis(441)));
    }
}
