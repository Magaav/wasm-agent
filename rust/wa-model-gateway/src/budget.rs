//! Token budgets: per node per day, and per session (`docs/MODEL-GATEWAY.md`, "Budgets").
//!
//! Two scopes, both charged with `Usage::spent()` (prompt + output + reasoning). The check happens
//! before an attempt and the charge after it, so a drained budget refuses *before* a byte leaves the
//! node when the caller supplies an estimate, and always refuses the next call when it does not.
//! The day rolls over on the UTC day key the caller supplies (`now_ms / 86_400_000`): a ledger with a
//! clock of its own would disagree with the node's, and the node's is the one in the audit.

use std::collections::BTreeMap;

use crate::policy::Budgets;
use crate::types::BudgetRefusal;

#[derive(Clone, Debug)]
pub struct Ledger {
    budgets: Budgets,
    day_key: u64,
    node_tokens: u64,
    sessions: BTreeMap<String, u64>,
    /// Calls refused for budget, per scope: a refusal the operator can see is a policy that works.
    refused_node: u64,
    refused_session: u64,
}

impl Ledger {
    pub fn new(budgets: Budgets) -> Ledger {
        Ledger {
            budgets,
            day_key: 0,
            node_tokens: 0,
            sessions: BTreeMap::new(),
            refused_node: 0,
            refused_session: 0,
        }
    }

    pub fn configure(&mut self, budgets: Budgets) {
        self.budgets = budgets;
    }

    /// Roll the daily counter over when the UTC day changed. Idempotent.
    pub fn rollover(&mut self, now_ms: u64) {
        let today = now_ms / 86_400_000;
        if today != self.day_key {
            self.day_key = today;
            self.node_tokens = 0;
        }
    }

    pub fn node_spent(&self) -> u64 {
        self.node_tokens
    }

    pub fn session_spent(&self, session: &str) -> u64 {
        self.sessions.get(session).copied().unwrap_or(0)
    }

    pub fn refused(&self) -> (u64, u64) {
        (self.refused_node, self.refused_session)
    }

    /// Would `estimate` more tokens fit? `None` means "the caller gave no estimate": only the charge
    /// after the call can refuse then, and that refusal is the next call's.
    pub fn check(&mut self, session: &str, estimate: Option<u64>) -> Result<(), BudgetRefusal> {
        let Some(estimate) = estimate else { return Ok(()) };
        if let Some(limit) = self.budgets.node_tokens_per_day {
            if self.node_tokens + estimate > limit {
                self.refused_node += 1;
                return Err(BudgetRefusal {
                    scope: "node".into(),
                    spent: self.node_tokens,
                    limit,
                    reason: format!(
                        "budget_exceeded: the node has spent {} of {} tokens today and this call needs about {}",
                        self.node_tokens, limit, estimate
                    ),
                });
            }
        }
        if let Some(limit) = self.budgets.session_tokens {
            let spent = self.session_spent(session);
            if spent + estimate > limit {
                self.refused_session += 1;
                return Err(BudgetRefusal {
                    scope: format!("session:{session}"),
                    spent,
                    limit,
                    reason: format!(
                        "budget_exceeded: session {} has spent {} of {} tokens and this call needs about {}",
                        session, spent, limit, estimate
                    ),
                });
            }
        }
        Ok(())
    }

    /// Charge what a call actually used, whatever the estimate said.
    pub fn charge(&mut self, session: &str, tokens: u64) {
        self.node_tokens = self.node_tokens.saturating_add(tokens);
        let entry = self.sessions.entry(session.to_string()).or_insert(0);
        *entry = entry.saturating_add(tokens);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ledger(node: Option<u64>, session: Option<u64>) -> Ledger {
        Ledger::new(Budgets { node_tokens_per_day: node, session_tokens: session })
    }

    #[test]
    fn a_drained_session_budget_refuses_before_bytes_leave() {
        let mut ledger = ledger(None, Some(1_000));
        ledger.charge("s1", 900);
        let refusal = ledger.check("s1", Some(200)).unwrap_err();
        assert_eq!(refusal.scope, "session:s1");
        assert_eq!(refusal.spent, 900);
        assert_eq!(refusal.limit, 1_000);
        assert!(refusal.reason.starts_with("budget_exceeded:"), "{}", refusal.reason);
        assert!(ledger.check("s1", Some(99)).is_ok());
        // Another session has its own budget.
        assert!(ledger.check("s2", Some(200)).is_ok());
        assert_eq!(ledger.refused(), (0, 1));
    }

    #[test]
    fn the_node_budget_is_shared_by_every_session() {
        let mut ledger = ledger(Some(1_000), None);
        ledger.charge("a", 600);
        ledger.charge("b", 400);
        let refusal = ledger.check("c", Some(1)).unwrap_err();
        assert_eq!(refusal.scope, "node");
        assert_eq!(refusal.spent, 1_000);
        assert_eq!(ledger.refused(), (1, 0));
    }

    #[test]
    fn a_charge_is_what_counted_not_the_estimate() {
        let mut ledger = ledger(None, Some(100));
        assert!(ledger.check("s", Some(10)).is_ok());
        ledger.charge("s", 80); // the model used more than the estimate
        assert!(ledger.check("s", Some(10)).is_ok());
        ledger.charge("s", 30);
        assert!(ledger.check("s", Some(1)).is_err());
        assert_eq!(ledger.session_spent("s"), 110);
    }

    #[test]
    fn the_daily_counter_rolls_over_on_the_utc_day() {
        let mut ledger = ledger(Some(10), None);
        ledger.rollover(0);
        ledger.charge("s", 10);
        assert!(ledger.check("s", Some(1)).is_err());
        // A millisecond before the next day: still refused. One millisecond after: fresh.
        ledger.rollover(86_399_999);
        assert!(ledger.check("s", Some(1)).is_err());
        ledger.rollover(86_400_000);
        assert_eq!(ledger.node_spent(), 0);
        assert!(ledger.check("s", Some(1)).is_ok());
    }

    #[test]
    fn no_budget_configured_never_refuses() {
        let mut ledger = ledger(None, None);
        ledger.charge("s", u64::MAX / 2);
        assert!(ledger.check("s", Some(u64::MAX / 2)).is_ok());
        assert!(ledger.check("s", None).is_ok());
    }
}
