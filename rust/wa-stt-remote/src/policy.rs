//! Which worker should get the next voice note: the strong node over the relay, or this one.
//!
//! The rule is measured, not assumed. A remote is preferred when it is **online** and its recent
//! decode is faster than this node's; the local worker then holds back for a short, configurable
//! grace (3 s by default) so the remote can lease the job first. When the grace expires the local
//! worker takes it itself — nothing waits on a node that is not there — and when the remote is
//! offline, or measured slower, the local worker does not wait at all.
//!
//! "First lease wins" is the queue's, not this module's: the grace is only a decision *not to take*,
//! so a remote that arrives late still loses to a local that already holds the lease. That is why
//! this policy cannot produce two decodes of one job, and why it does not need a lock anywhere.

/// Enough measurements for an estimate to mean something. One sample is a cold worker loading its
/// model; two is the second note, which is the number a person waits for.
pub const DEFAULT_MIN_SAMPLES: u32 = 2;

/// A measurement older than this is not evidence about "now": a node that was fast an hour ago, or
/// before a reboot or a thermal throttle, is not assumed fast.
pub const DEFAULT_SAMPLE_TTL_MS: i64 = 10 * 60 * 1000;

/// How long the local worker holds back for a preferred remote before doing the job itself.
pub const DEFAULT_FALLBACK_AFTER_MS: i64 = 3_000;

/// A running estimate of how long one side takes to decode, in milliseconds.
///
/// Exponentially weighted so one slow (or one lucky) note does not rewrite the preference, and
/// timestamped so a stale estimate can be ignored rather than averaged in.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Latency {
    last_ms: u64,
    ewma_ms: f64,
    samples: u32,
    updated_at_ms: i64,
}

/// The weight a new measurement gets. 0.3 keeps a single outlier from deciding the next choice while
/// still settling within a handful of notes.
const ALPHA: f64 = 0.3;

impl Latency {
    pub fn new() -> Latency {
        Latency::default()
    }

    /// Add one measurement taken at `at_ms`.
    pub fn record(&mut self, at_ms: i64, took_ms: i64) {
        let took = took_ms.max(0) as u64;
        self.ewma_ms = if self.samples == 0 { took as f64 } else { ALPHA * took as f64 + (1.0 - ALPHA) * self.ewma_ms };
        self.last_ms = took;
        self.samples = self.samples.saturating_add(1);
        self.updated_at_ms = at_ms;
    }

    /// How many measurements have been recorded (the recent ones are `recent`'s business).
    pub fn samples(&self) -> u32 {
        self.samples
    }

    /// The last measurement, without the smoothing.
    pub fn last_ms(&self) -> u64 {
        self.last_ms
    }

    /// The smoothed estimate, rounded down to whole milliseconds.
    pub fn estimate_ms(&self) -> u64 {
        self.ewma_ms.max(0.0) as u64
    }

    /// The estimate, but only when it is recent enough and backed by enough samples. `None` means
    /// "no evidence", which the policy treats differently from "measured slow".
    pub fn recent(&self, now_ms: i64, ttl_ms: i64, min_samples: u32) -> Option<u64> {
        if self.samples < min_samples.max(1) {
            return None;
        }
        if now_ms.saturating_sub(self.updated_at_ms) > ttl_ms.max(0) {
            return None;
        }
        Some(self.estimate_ms())
    }
}

/// What the producing node knows about the remote right now: whether a `stt_worker` node is attached,
/// and how fast it has been.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RemoteHealth {
    pub online: bool,
    pub latency: Latency,
}

impl RemoteHealth {
    pub fn online(latency: Latency) -> RemoteHealth {
        RemoteHealth { online: true, latency }
    }

    pub fn offline() -> RemoteHealth {
        RemoteHealth { online: false, latency: Latency::default() }
    }
}

/// Why a remote was preferred. Carried so the log line and a test can say *which* comparison decided.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteReason {
    FasterThanLocal,
    /// The remote has measurements, this node has none: nothing says local is faster.
    LocalUnmeasured,
    /// A remote that has never decoded anything gets one chance; the grace bounds the cost of being
    /// wrong about it.
    RemoteUnmeasured,
}

/// Why the local worker took (or is about to take) the job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalReason {
    /// No `stt_worker` node is configured, or none is attached: never wait for a missing node.
    RemoteOffline,
    /// The remote is online but measured no faster than this node.
    RemoteSlower,
    /// The grace ran out with the job still ready.
    GraceElapsed,
}

/// What the local worker should do with one job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Hold back until `grace_until_ms`; the remote has the first claim on this job.
    Remote { grace_until_ms: i64, because: RemoteReason },
    /// Take it now.
    Local { because: LocalReason },
}

/// The policy, as knobs with the values `docs/QUEUE.md` names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preference {
    pub fallback_after_ms: i64,
    pub sample_ttl_ms: i64,
    pub min_samples: u32,
}

impl Default for Preference {
    fn default() -> Self {
        Preference {
            fallback_after_ms: DEFAULT_FALLBACK_AFTER_MS,
            sample_ttl_ms: DEFAULT_SAMPLE_TTL_MS,
            min_samples: DEFAULT_MIN_SAMPLES,
        }
    }
}

impl Preference {
    /// Read the two settings an operator can move (`docs/QUEUE.md`): the grace in milliseconds and
    /// the sample lifetime. Absent or unreadable keeps the default — a knob nobody set must not
    /// silently become zero.
    pub fn from_settings(fallback_after_ms: Option<i64>, sample_ttl_ms: Option<i64>) -> Preference {
        let default = Preference::default();
        Preference {
            fallback_after_ms: fallback_after_ms.filter(|ms| *ms >= 0).unwrap_or(default.fallback_after_ms),
            sample_ttl_ms: sample_ttl_ms.filter(|ms| *ms > 0).unwrap_or(default.sample_ttl_ms),
            min_samples: default.min_samples,
        }
    }

    /// When a job enqueued at `enqueued_at_ms` stops holding back for the remote.
    pub fn grace_until_ms(&self, enqueued_at_ms: i64) -> i64 {
        enqueued_at_ms.saturating_add(self.fallback_after_ms)
    }

    /// Decide the local worker's behaviour for a job enqueued at `enqueued_at_ms`, now.
    pub fn decide(&self, now_ms: i64, enqueued_at_ms: i64, remote: Option<&RemoteHealth>, local: &Latency) -> Decision {
        let Some(remote) = remote else {
            return Decision::Local { because: LocalReason::RemoteOffline };
        };
        if !remote.online {
            return Decision::Local { because: LocalReason::RemoteOffline };
        }
        let remote_ms = remote.latency.recent(now_ms, self.sample_ttl_ms, self.min_samples);
        let local_ms = local.recent(now_ms, self.sample_ttl_ms, self.min_samples);
        let because = match (remote_ms, local_ms) {
            // Measured on both sides: only a strictly faster remote earns the wait.
            (Some(r), Some(l)) if r >= l => return Decision::Local { because: LocalReason::RemoteSlower },
            (Some(_), Some(_)) => RemoteReason::FasterThanLocal,
            (Some(_), None) => RemoteReason::LocalUnmeasured,
            (None, _) => RemoteReason::RemoteUnmeasured,
        };
        let grace_until_ms = self.grace_until_ms(enqueued_at_ms);
        if now_ms >= grace_until_ms {
            return Decision::Local { because: LocalReason::GraceElapsed };
        }
        Decision::Remote { grace_until_ms, because }
    }
}
