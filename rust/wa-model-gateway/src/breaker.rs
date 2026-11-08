//! A per-provider circuit breaker (`docs/MODEL-GATEWAY.md`, "Fallback, backoff, breaker").
//!
//! A provider that is refusing everything must stop being asked, or every turn pays its timeout: the
//! breaker counts consecutive provider-side failures, opens after the policy's threshold, allows one
//! trial call after the cooldown, and closes when the trial succeeds. Time is injected, so the whole
//! state machine is a deterministic function of (now, outcome).

use std::collections::BTreeMap;

use crate::policy::BreakerSpec;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Closed,
    /// Open until `until_ms`; no call may be tried before then.
    Open { until_ms: u64 },
    /// Cooldown elapsed: exactly one trial call is allowed, and its outcome decides.
    HalfOpen { trial_in_flight: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    spec: BreakerSpec,
    failures: u32,
    phase: Phase,
    /// How many times this provider has opened: one number the operator can read.
    opens: u32,
}

#[derive(Clone, Debug, Default)]
pub struct Breakers {
    entries: BTreeMap<String, Entry>,
}

/// What one attempt did, as the breaker sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict<'a> {
    /// A 2xx that produced a stream.
    Success,
    /// Provider-side: 429, 5xx, 401/403, timeout, transport. Counts toward opening.
    ProviderFailure(&'a str),
    /// The request's own fault (400, unparseable shape): never opens a breaker.
    CallerFailure,
}

impl Breakers {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn configure(&mut self, provider: &str, spec: BreakerSpec) {
        match self.entries.get_mut(provider) {
            Some(entry) => entry.spec = spec,
            None => {
                self.entries.insert(
                    provider.to_string(),
                    Entry { spec, failures: 0, phase: Phase::Closed, opens: 0 },
                );
            }
        }
    }

    /// Restore a count persisted by a previous instance (the guest's kv). The phase follows from the count
    /// and the clock: a cooldown that elapsed while the component was stopped is already over.
    pub fn restore(&mut self, provider: &str, failures: u32, now_ms: u64) {
        let Some(spec) = self.entries.get(provider).map(|entry| entry.spec.clone()) else { return };
        let Some(entry) = self.entries.get_mut(provider) else { return };
        entry.failures = failures;
        entry.phase = if failures >= spec.failures.max(1) {
            entry.opens += 1;
            Phase::Open { until_ms: now_ms + spec.cooldown_ms }
        } else {
            Phase::Closed
        };
    }

    pub fn failures(&self, provider: &str) -> u32 {
        self.entries.get(provider).map(|entry| entry.failures).unwrap_or(0)
    }

    pub fn phase(&self, provider: &str, now_ms: u64) -> Phase {
        match self.entries.get(provider) {
            None => Phase::Closed,
            Some(entry) => match entry.phase {
                Phase::Open { until_ms } if now_ms >= until_ms => Phase::HalfOpen { trial_in_flight: false },
                phase => phase,
            },
        }
    }

    /// May a call go to this provider now? A half-open breaker allows exactly one trial: the first
    /// caller is admitted, the rest are told `circuit_open` until it settles.
    pub fn admit(&mut self, provider: &str, now_ms: u64) -> Result<(), String> {
        let phase = self.phase(provider, now_ms);
        match phase {
            Phase::Closed => Ok(()),
            Phase::Open { until_ms } => Err(format!(
                "circuit_open: {provider} failed {} times, cooling down for {} ms (opened {} time(s))",
                self.entries.get(provider).map(|entry| entry.failures).unwrap_or(0),
                until_ms.saturating_sub(now_ms),
                self.entries.get(provider).map(|entry| entry.opens).unwrap_or(0)
            )),
            Phase::HalfOpen { trial_in_flight } => {
                if trial_in_flight {
                    return Err(format!("circuit_open: {provider} is half-open with a trial in flight"));
                }
                if let Some(entry) = self.entries.get_mut(provider) {
                    entry.phase = Phase::HalfOpen { trial_in_flight: true };
                }
                Ok(())
            }
        }
    }

    pub fn record(&mut self, provider: &str, outcome: Verdict<'_>, now_ms: u64) {
        let Some(entry) = self.entries.get_mut(provider) else { return };
        match outcome {
            Verdict::Success => {
                entry.failures = 0;
                entry.phase = Phase::Closed;
            }
            Verdict::CallerFailure => {
                // The provider answered; nothing about it is broken. A half-open trial still settles,
                // or the provider would be stuck admitting trials forever.
                if matches!(entry.phase, Phase::HalfOpen { .. }) {
                    entry.phase = Phase::Closed;
                    entry.failures = 0;
                }
            }
            Verdict::ProviderFailure(_) => {
                // A failed trial re-opens immediately, whatever the counter says.
                let was_trial = matches!(entry.phase, Phase::HalfOpen { .. });
                entry.failures = if was_trial { entry.spec.failures.max(1) } else { entry.failures + 1 };
                if entry.failures >= entry.spec.failures.max(1) {
                    entry.phase = Phase::Open { until_ms: now_ms + entry.spec.cooldown_ms };
                    entry.opens += 1;
                } else {
                    entry.phase = Phase::Closed;
                }
            }
        }
    }

    /// One line per provider for `wa models` and the log: name, phase, failures, opens.
    pub fn snapshot(&self, now_ms: u64) -> Vec<(String, Phase, u32, u32)> {
        self.entries
            .iter()
            .map(|(provider, entry)| (provider.clone(), self.phase(provider, now_ms), entry.failures, entry.opens))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(failures: u32, cooldown_ms: u64) -> BreakerSpec {
        BreakerSpec { failures, cooldown_ms }
    }

    #[test]
    fn the_breaker_opens_on_the_threshold_and_closes_after_a_successful_trial() {
        let mut breakers = Breakers::default();
        breakers.configure("deepseek", spec(2, 1_000));
        assert_eq!(breakers.phase("deepseek", 0), Phase::Closed);

        breakers.record("deepseek", Verdict::ProviderFailure("429"), 10);
        assert_eq!(breakers.phase("deepseek", 10), Phase::Closed, "one failure is below the threshold");
        assert!(breakers.admit("deepseek", 10).is_ok());

        breakers.record("deepseek", Verdict::ProviderFailure("503"), 20);
        assert_eq!(breakers.phase("deepseek", 20), Phase::Open { until_ms: 1_020 });
        let refused = breakers.admit("deepseek", 20).unwrap_err();
        assert!(refused.starts_with("circuit_open"), "{refused}");
        assert!(refused.contains("cooling down for 1000 ms"), "{refused}");
        // Still open one millisecond before the cooldown ends.
        assert!(breakers.admit("deepseek", 1_019).is_err());

        // Cooldown elapsed: exactly one trial, then the others wait.
        assert!(breakers.admit("deepseek", 1_020).is_ok());
        assert_eq!(breakers.phase("deepseek", 1_020), Phase::HalfOpen { trial_in_flight: true });
        assert!(breakers.admit("deepseek", 1_021).is_err());

        breakers.record("deepseek", Verdict::Success, 1_030);
        assert_eq!(breakers.phase("deepseek", 1_030), Phase::Closed);
        assert!(breakers.admit("deepseek", 1_031).is_ok());
        assert_eq!(breakers.snapshot(1_031)[0].3, 1, "one open, counted");
    }

    #[test]
    fn a_failed_trial_reopens_immediately() {
        let mut breakers = Breakers::default();
        breakers.configure("p", spec(1, 500));
        breakers.record("p", Verdict::ProviderFailure("500"), 0);
        assert!(breakers.admit("p", 500).is_ok());
        breakers.record("p", Verdict::ProviderFailure("500"), 510);
        assert_eq!(breakers.phase("p", 510), Phase::Open { until_ms: 1_010 });
    }

    #[test]
    fn a_caller_fault_never_opens_the_breaker() {
        let mut breakers = Breakers::default();
        breakers.configure("p", spec(1, 500));
        for now in 0..5 {
            breakers.record("p", Verdict::CallerFailure, now);
            assert!(breakers.admit("p", now).is_ok());
        }
        assert_eq!(breakers.phase("p", 5), Phase::Closed);
    }

    #[test]
    fn an_unconfigured_provider_is_closed_and_unknown() {
        let mut breakers = Breakers::default();
        assert!(breakers.is_empty());
        assert!(breakers.admit("never-seen", 0).is_ok());
        breakers.record("never-seen", Verdict::ProviderFailure("500"), 0);
        assert_eq!(breakers.phase("never-seen", 0), Phase::Closed);
    }

    #[test]
    fn reconfiguring_keeps_the_counters() {
        let mut breakers = Breakers::default();
        breakers.configure("p", spec(5, 100));
        breakers.record("p", Verdict::ProviderFailure("500"), 0);
        breakers.configure("p", spec(2, 100));
        breakers.record("p", Verdict::ProviderFailure("500"), 1);
        assert_eq!(breakers.phase("p", 1), Phase::Open { until_ms: 101 });
    }
}
