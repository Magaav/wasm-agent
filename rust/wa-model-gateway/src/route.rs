//! Route planning: class (or explicit model) → the ordered candidates, with the reason for each.
//!
//! Planning is where the data label is enforced, and it is the only place: a candidate whose provider
//! does not allow the request's label is *never* a candidate, whatever the route says, so no later
//! stage can decide differently. The same function answers `explain` (a dry run) and `chat`, which is
//! what makes `wa models explain` trustworthy: the operator reads the decision the call would make,
//! not a second implementation of it.

use crate::breaker::{Breakers, Phase};
use crate::policy::{Policy, ProviderKind};
use crate::types::{Label, LabelRefusal, ModelRef, NoRoute, Refusal, Skip, TaskClass};

/// One candidate of a route, usable or not, with why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Planned {
    pub model: ModelRef,
    pub kind: ProviderKind,
    pub usable: bool,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub class: TaskClass,
    pub label: Label,
    pub choices: Vec<Planned>,
    /// Set when the plan cannot serve the call at all; `choices` still says why, candidate by
    /// candidate, because "no route" without its reasons is an unfalsifiable answer.
    pub refusal: Option<Refusal>,
}

impl Plan {
    /// The candidates the call may try, in order.
    pub fn usable(&self) -> Vec<ModelRef> {
        self.choices
            .iter()
            .filter(|choice| choice.usable)
            .map(|choice| choice.model.clone())
            .collect()
    }

    pub fn skipped(&self) -> Vec<Skip> {
        self.choices
            .iter()
            .filter(|choice| !choice.usable)
            .map(|choice| Skip {
                provider: choice.model.provider.clone(),
                model: choice.model.model.clone(),
                reason: choice.reason.clone(),
            })
            .collect()
    }
}

/// Plan one chat call.
pub fn plan_chat(
    policy: &Policy,
    class: TaskClass,
    label: Label,
    explicit: Option<&ModelRef>,
    breakers: &Breakers,
    now_ms: u64,
) -> Plan {
    match explicit {
        Some(model) => plan_explicit(policy, class, label, model, breakers, now_ms),
        None => plan_route(policy, class, label, breakers, now_ms),
    }
}

fn plan_explicit(
    policy: &Policy,
    class: TaskClass,
    label: Label,
    model: &ModelRef,
    breakers: &Breakers,
    now_ms: u64,
) -> Plan {
    let choice = judge(policy, label, model, "explicit", breakers, now_ms);
    let refusal = if choice.usable {
        None
    } else if let Some(provider) = policy.provider(&model.provider) {
        if !provider.allows_label(label) {
            Some(Refusal::LabelNotAllowed(label_refusal(provider, model, label)))
        } else {
            Some(Refusal::NoRoute(NoRoute {
                class,
                label,
                skipped: vec![Skip {
                    provider: model.provider.clone(),
                    model: model.model.clone(),
                    reason: choice.reason.clone(),
                }],
            }))
        }
    } else {
        Some(Refusal::NoRoute(NoRoute {
            class,
            label,
            skipped: vec![Skip {
                provider: model.provider.clone(),
                model: model.model.clone(),
                reason: choice.reason.clone(),
            }],
        }))
    };
    Plan { class, label, choices: vec![choice], refusal }
}

fn plan_route(policy: &Policy, class: TaskClass, label: Label, breakers: &Breakers, now_ms: u64) -> Plan {
    let (source, route) = policy.route_for(class);
    let Some(route) = route else {
        return Plan {
            class,
            label,
            choices: Vec::new(),
            refusal: Some(Refusal::NoRoute(NoRoute { class, label, skipped: Vec::new() })),
        };
    };
    let mut choices = Vec::new();
    let mut labelled_out: Vec<(&String, LabelRefusal)> = Vec::new();
    for (index, model) in route.iter().enumerate() {
        let reason = format!("{source}#{}", index + 1);
        let choice = judge(policy, label, model, &reason, breakers, now_ms);
        if !choice.usable {
            if let Some(provider) = policy.provider(&model.provider) {
                if !provider.allows_label(label) {
                    labelled_out.push((&model.provider, label_refusal(provider, model, label)));
                }
            }
        }
        choices.push(choice);
    }
    let any_usable = choices.iter().any(|choice| choice.usable);
    let refusal = if any_usable {
        None
    } else if choices.is_empty() {
        Some(Refusal::NoRoute(NoRoute { class, label, skipped: Vec::new() }))
    } else {
        // If every candidate was dropped for the label, the answer is the label refusal: it names the
        // provider that was denied and the labels it allows, which is what the operator needs to change
        // the policy (and what the model is told, so it does not retry blindly).
        match labelled_out.first() {
            Some((_, refusal)) => Some(Refusal::LabelNotAllowed(refusal.clone())),
            None => Some(Refusal::NoRoute(NoRoute {
                class,
                label,
                skipped: choices
                    .iter()
                    .filter(|choice| !choice.usable)
                    .map(|choice| Skip {
                        provider: choice.model.provider.clone(),
                        model: choice.model.model.clone(),
                        reason: choice.reason.clone(),
                    })
                    .collect(),
            })),
        }
    };
    Plan { class, label, choices, refusal }
}

fn label_refusal(provider: &crate::policy::ProviderSpec, model: &ModelRef, label: Label) -> LabelRefusal {
    LabelRefusal {
        provider: provider.id.clone(),
        model: model.model.clone(),
        label,
        allowed: provider.allowed_labels.clone(),
        // The `client` sentence is the actionable one (docs/MODEL-GATEWAY.md, "Allowed labels"): the
        // default providers carry the operator's own data and never a client's, so the operator has to
        // name a provider that may. A refusal that does not say what to write is a dead end at 03:00.
        reason: if label == Label::Client {
            format!(
                "label_not_allowed: {} is labelled client and {} allows {} - configure a provider allowed for client data",
                model.as_string(),
                provider.id,
                provider.labels_text()
            )
        } else {
            format!(
                "label_not_allowed: {} is labelled {} and {} allows {}",
                model.as_string(),
                label.as_str(),
                provider.id,
                provider.labels_text()
            )
        },
    }
}

fn judge(
    policy: &Policy,
    label: Label,
    model: &ModelRef,
    reason: &str,
    breakers: &Breakers,
    now_ms: u64,
) -> Planned {
    let Some(provider) = policy.provider(&model.provider) else {
        return Planned {
            model: model.clone(),
            kind: ProviderKind::OpenAi,
            usable: false,
            reason: format!("{reason}: no provider {:?} in models.providers", model.provider),
        };
    };
    let kind = provider.kind;
    if !provider.allows_label(label) {
        return Planned {
            model: model.clone(),
            kind,
            usable: false,
            reason: format!(
                "{reason}: label_not_allowed: {} is {} and {} allows {}",
                model.as_string(),
                label.as_str(),
                provider.id,
                provider.labels_text()
            ),
        };
    }
    if !provider.allows_model(&model.model) {
        return Planned {
            model: model.clone(),
            kind,
            usable: false,
            reason: format!("{reason}: model_not_served: {} does not list {}", provider.id, model.model),
        };
    }
    match breakers.phase(&provider.id, now_ms) {
        Phase::Closed => Planned {
            model: model.clone(),
            kind,
            usable: true,
            reason: reason.to_string(),
        },
        Phase::Open { until_ms } => Planned {
            model: model.clone(),
            kind,
            usable: false,
            reason: format!("{reason}: circuit_open: {} until +{} ms", provider.id, until_ms.saturating_sub(now_ms)),
        },
        Phase::HalfOpen { trial_in_flight } => Planned {
            model: model.clone(),
            kind,
            // A half-open breaker still admits the call: the gateway takes the trial. When a trial is
            // already in flight the candidate is skipped, which is what bounds the probe to one.
            usable: !trial_in_flight,
            reason: if trial_in_flight {
                format!("{reason}: circuit_open: {} half-open with a trial in flight", provider.id)
            } else {
                format!("{reason}: half-open trial")
            },
        },
    }
}

/// Plan an embedding call: same label rule, the `embeddings` routes.
pub fn plan_embed(
    policy: &Policy,
    class: TaskClass,
    label: Label,
    explicit: Option<&ModelRef>,
    breakers: &Breakers,
    now_ms: u64,
) -> Result<Vec<ModelRef>, Refusal> {
    if let Some(model) = explicit {
        let plan = plan_explicit(policy, class, label, model, breakers, now_ms);
        return match plan.refusal {
            Some(refusal) => Err(refusal),
            None => Ok(vec![model.clone()]),
        };
    }
    let (source, route) = policy.embed_route_for(class);
    let Some(route) = route else {
        return Err(Refusal::NoRoute(NoRoute { class, label, skipped: Vec::new() }));
    };
    let mut usable = Vec::new();
    let mut skipped = Vec::new();
    let mut labelled_out = None;
    for (index, model) in route.iter().enumerate() {
        let choice = judge(policy, label, model, &format!("{source}#{}", index + 1), breakers, now_ms);
        if choice.usable {
            usable.push(model.clone());
        } else {
            if labelled_out.is_none() {
                if let Some(provider) = policy.provider(&model.provider) {
                    if !provider.allows_label(label) {
                        labelled_out = Some(label_refusal(provider, model, label));
                    }
                }
            }
            skipped.push(Skip {
                provider: model.provider.clone(),
                model: model.model.clone(),
                reason: choice.reason,
            });
        }
    }
    if usable.is_empty() {
        return Err(match labelled_out {
            Some(refusal) => Refusal::LabelNotAllowed(refusal),
            None => Refusal::NoRoute(NoRoute { class, label, skipped }),
        });
    }
    Ok(usable)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Label;

    const POLICY: &str = r#"{
      "providers": [
        {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
         "allowed_labels": ["public", "internal"]},
        {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
         "allowed_labels": ["public", "internal", "client"]}
      ],
      "routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"],
                 "default": ["deepseek/deepseek-v4.1-flash"]},
      "embeddings": {"default": ["deepseek/deepseek-embed"]}
    }"#;

    fn policy() -> Policy {
        Policy::parse(POLICY).expect("policy parses")
    }

    #[test]
    fn a_client_label_drops_every_provider_that_does_not_allow_it() {
        let breakers = Breakers::default();
        let plan = plan_chat(&policy(), TaskClass::Default, Label::Client, None, &breakers, 0);
        // `default` is deepseek only, and deepseek allows public|internal.
        assert!(plan.usable().is_empty());
        let refusal = plan.refusal.clone().expect("refused");
        match refusal {
            Refusal::LabelNotAllowed(refusal) => {
                assert_eq!(refusal.provider, "deepseek");
                assert_eq!(refusal.label, Label::Client);
                assert_eq!(refusal.allowed, vec![Label::Public, Label::Internal]);
                assert!(refusal.reason.starts_with("label_not_allowed:"));
                assert!(refusal.reason.contains("deepseek allows public,internal"));
            }
            other => panic!("expected label_not_allowed, got {other:?}"),
        }
    }

    #[test]
    fn a_plan_falls_through_to_the_next_allowed_provider() {
        let breakers = Breakers::default();
        // plan#1 (anthropic) is not allowed either? It is: `client` is allowed by anthropic. Make it
        // unusable for another reason: the model allow-list.
        let text = POLICY.replace(
            r#""id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com","#,
            r#""id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com", "models": ["other"],"#,
        );
        let policy = Policy::parse(&text).expect("policy parses");
        let plan = plan_chat(&policy, TaskClass::Plan, Label::Internal, None, &breakers, 0);
        assert_eq!(plan.choices.len(), 2);
        assert!(!plan.choices[0].usable);
        assert!(plan.choices[0].reason.contains("model_not_served"));
        assert!(plan.choices[1].usable);
        assert_eq!(plan.usable(), vec![ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()]);
    }

    #[test]
    fn an_explicit_model_is_still_subject_to_the_label_rule() {
        let breakers = Breakers::default();
        let deepseek = ModelRef::parse("deepseek/deepseek-v4.1-flash").expect("ref");
        let plan = plan_chat(&policy(), TaskClass::Default, Label::Client, Some(&deepseek), &breakers, 0);
        assert!(plan.usable().is_empty());
        assert!(matches!(plan.refusal, Some(Refusal::LabelNotAllowed(_))));

        let anthropic = ModelRef::parse("anthropic/claude-sonnet-4-5").expect("ref");
        let plan = plan_chat(&policy(), TaskClass::Default, Label::Client, Some(&anthropic), &breakers, 0);
        assert_eq!(plan.usable(), vec![anthropic]);
        assert!(plan.refusal.is_none());
    }

    #[test]
    fn an_open_breaker_removes_the_candidate_but_leaves_the_reason() {
        let mut breakers = Breakers::default();
        breakers.configure("anthropic", crate::policy::BreakerSpec { failures: 1, cooldown_ms: 1_000 });
        breakers.record("anthropic", crate::breaker::Verdict::ProviderFailure("503"), 0);
        let plan = plan_chat(&policy(), TaskClass::Plan, Label::Public, None, &breakers, 10);
        assert_eq!(plan.choices[0].model.provider, "anthropic");
        assert!(!plan.choices[0].usable);
        assert!(plan.choices[0].reason.contains("circuit_open"));
        assert_eq!(plan.usable().len(), 1, "the second candidate still serves");
        // After the cooldown, one trial is planned.
        let plan = plan_chat(&policy(), TaskClass::Plan, Label::Public, None, &breakers, 1_000);
        assert!(plan.choices[0].usable);
        assert!(plan.choices[0].reason.contains("half-open trial"));
    }

    #[test]
    fn an_unknown_explicit_model_names_what_is_missing() {
        let breakers = Breakers::default();
        let stray = ModelRef::parse("nobody/model").expect("ref");
        let plan = plan_chat(&policy(), TaskClass::Default, Label::Public, Some(&stray), &breakers, 0);
        match plan.refusal {
            Some(Refusal::NoRoute(no_route)) => {
                assert_eq!(no_route.skipped.len(), 1);
                assert!(no_route.skipped[0].reason.contains("no provider"));
            }
            other => panic!("expected no_route, got {other:?}"),
        }
    }

    #[test]
    fn an_embedding_route_uses_the_same_label_gate() {
        let breakers = Breakers::default();
        let usable = plan_embed(&policy(), TaskClass::Default, Label::Internal, None, &breakers, 0)
            .expect("internal is allowed");
        assert_eq!(usable, vec![ModelRef::parse("deepseek/deepseek-embed").unwrap()]);
        let refused = plan_embed(&policy(), TaskClass::Default, Label::Client, None, &breakers, 0);
        assert!(matches!(refused, Err(Refusal::LabelNotAllowed(_))));
    }
}
