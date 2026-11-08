//! Routing policies as modules: which model a class of work prefers, replaceable while the node runs.
//!
//! The gateway (`wa-model-gateway`) owns the call - adapters, the data-label gate, fallback, breaker,
//! budget, accounting. It does not own the opinion of *which* model a class of work should use. That
//! opinion belongs to a **policy module** (`wit/model/router.wit`):
//!
//! * `DefaultRouter` reproduces today's routing exactly: an explicit model wins; otherwise the class's
//!   `models.routes` entry, else the `default` route, else nothing. A test asserts it against
//!   `wa_model_gateway::plan_chat`, so "the default module is the current behaviour" is measured, not
//!   claimed.
//! * `TableRouter` is a policy declared as a table (a component ships one): ordered rules of
//!   `classes` + `labels` -> `models` + `skills`. The `fleet-ops` example routes a fleet-ops turn to the
//!   strong model and names the `fleetops` skill.
//! * `RouterRegistry` holds the installed modules and which one is current. `install` adds or upgrades
//!   (a new generation), `switch_to` changes the current one, and `decide` reads the current module at
//!   call time - so a swap changes the next call without a restart, and a call already in flight keeps
//!   the module it started with because it cloned the `Arc` when it asked.
//!
//! Two boundaries stay outside every module: a module may narrow the data labels its rules apply to,
//! never widen them (the gateway's own label gate runs on the candidate list this module returns), and
//! a decision never carries message text, tools or a cache breakpoint.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::Value;
use wa_model_gateway::{Label, ModelRef, Policy, TaskClass};

/// One routing question.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RouteRequest {
    /// The class name as the caller spelled it. REST has no effect: it comes from the loop's `kind`,
    /// and a policy name the gateway does not know arrives as `default`.
    pub class: TaskClass,
    /// The same class as text, so a policy module can name classes the gateway has no enum for
    /// (`fleet-ops`). Equal to `class.as_str()` unless a caller named one.
    pub class_name: String,
    pub label: Label,
    /// An explicit `provider/model` the caller named. A module must not silently replace it.
    pub explicit: Option<ModelRef>,
    /// The host's session id, for a module that routes by conversation. Never a message.
    pub session: String,
}

impl RouteRequest {
    pub fn new(class: TaskClass, label: Label) -> RouteRequest {
        RouteRequest {
            class,
            class_name: class.as_str().to_string(),
            label,
            explicit: None,
            session: String::new(),
        }
    }

    pub fn with_class_name(mut self, name: &str) -> RouteRequest {
        self.class_name = name.to_string();
        self
    }

    pub fn with_explicit(mut self, model: ModelRef) -> RouteRequest {
        self.explicit = Some(model);
        self
    }

    pub fn with_session(mut self, session: &str) -> RouteRequest {
        self.session = session.to_string();
        self
    }
}

/// What a module decided. `candidates` is ordered and empty means "no route"; the gateway turns the
/// empty case into its own `no-route` refusal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decision {
    pub module: String,
    /// Why this list (`route:plan`, `explicit`, `rule:fleet-ops`), for `wa models explain`.
    pub source: String,
    pub candidates: Vec<ModelRef>,
    /// Skills the caller should load for this request. A hint: the gateway loads nothing, and the
    /// skill is still the model's to load.
    pub skills: Vec<String>,
    /// Set when the module declined to decide and the gateway should fall back to the default module.
    pub fallback: Option<String>,
}

impl Decision {
    pub fn route(module: &str, source: impl Into<String>, candidates: Vec<ModelRef>) -> Decision {
        Decision {
            module: module.to_string(),
            source: source.into(),
            candidates,
            skills: Vec::new(),
            fallback: None,
        }
    }

    pub fn with_skills(mut self, skills: Vec<String>) -> Decision {
        self.skills = skills;
        self
    }

    pub fn is_empty(&self) -> bool {
        self.candidates.is_empty()
    }
}

/// What a module says about itself, for `wa models` and the component list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleInfo {
    pub name: String,
    pub version: u32,
    pub description: String,
    /// The classes the module has an opinion about; `*` means every class.
    pub classes: Vec<String>,
    /// The labels its rules apply to, when it narrows them.
    pub labels: Option<Vec<Label>>,
}

/// A routing policy. Implemented by the default module and by every installed policy module.
pub trait RouterModule: Send + Sync {
    fn info(&self) -> ModuleInfo;

    /// Decide one request. A function of the request and the module's own table only: no clock, no
    /// network, no session state beyond the id - so `explain` and `chat` cannot disagree.
    fn decide(&self, policy: &Policy, request: &RouteRequest) -> Decision;

    fn name(&self) -> String {
        self.info().name
    }
}

/// The default module: exactly today's routing.
///
/// * an explicit `provider/model` wins (the gateway still applies the label rule to it);
/// * otherwise the class's own route, else `default`, from `models.routes`;
/// * no route at all is an empty candidate list.
pub struct DefaultRouter;

impl DefaultRouter {
    pub fn new() -> DefaultRouter {
        DefaultRouter
    }
}

impl Default for DefaultRouter {
    fn default() -> Self {
        DefaultRouter
    }
}

impl RouterModule for DefaultRouter {
    fn info(&self) -> ModuleInfo {
        ModuleInfo {
            name: "default".to_string(),
            version: 1,
            description: "The models.routes section of policy.json: class -> ordered provider/model, \
                          default as the fallback class. Reproduces the gateway's built-in routing."
                .to_string(),
            classes: TaskClass::ALL.iter().map(|class| class.as_str().to_string()).collect(),
            labels: None,
        }
    }

    fn decide(&self, policy: &Policy, request: &RouteRequest) -> Decision {
        if let Some(model) = &request.explicit {
            return Decision::route("default", "explicit", vec![model.clone()]);
        }
        let (source, route) = policy.route_for(request.class);
        match route {
            Some(models) => Decision::route("default", source, models.clone()),
            None => Decision::route("default", "none", Vec::new()),
        }
    }
}

/// One rule of a table module: the classes and labels it applies to, then the route and skills.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PolicyRule {
    pub name: String,
    /// Class names this rule answers; `*` is every class.
    pub classes: Vec<String>,
    /// The labels this rule applies to. Absent means every label the gateway sends (the gateway still
    /// filters each candidate by its provider's own `allowed_labels`, so a rule can never widen).
    pub labels: Option<Vec<Label>>,
    pub models: Vec<ModelRef>,
    pub skills: Vec<String>,
}

impl PolicyRule {
    fn applies(&self, request: &RouteRequest) -> bool {
        let class_ok = self.classes.iter().any(|class| {
            class == "*" || class.eq_ignore_ascii_case(&request.class_name) || class == request.class.as_str()
        });
        if !class_ok {
            return false;
        }
        match &self.labels {
            None => true,
            Some(labels) => labels.contains(&request.label),
        }
    }
}

/// A routing policy declared as a table: what a policy component ships.
///
/// ```json
/// {"name":"fleet-ops","version":1,"description":"...",
///  "rules":[
///    {"name":"fleet-ops","classes":["fleet-ops"],"models":["anthropic/claude-sonnet-4-5",
///     "deepseek/deepseek-v4.1-flash"],"skills":["fleetops"]}]}
/// ```
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TableRouter {
    info: ModuleInfo,
    rules: Vec<PolicyRule>,
}

impl TableRouter {
    /// Parse a module's declaration. Every error names the path it came from, like the `models`
    /// section does: a policy typo must be visible, not silently weaker routing.
    pub fn parse(text: &str) -> Result<TableRouter, String> {
        let root: Value = serde_json::from_str(text).map_err(|error| format!("module is not JSON: {error}"))?;
        let object = root.as_object().ok_or_else(|| "module: not a JSON object".to_string())?;
        let name = match object.get("name") {
            Some(Value::String(text)) if !text.is_empty() => text.clone(),
            _ => return Err("module.name: missing".to_string()),
        };
        if name.eq_ignore_ascii_case("default") {
            return Err("module.name: \"default\" is reserved for the built-in routing".to_string());
        }
        let version = match object.get("version") {
            None | Some(Value::Null) => 1,
            Some(value) => value
                .as_u64()
                .ok_or_else(|| "module.version: not a non-negative integer".to_string())? as u32,
        };
        let description = match object.get("description") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(text)) => text.clone(),
            Some(_) => return Err("module.description: not a string".to_string()),
        };
        let raw_rules = object
            .get("rules")
            .ok_or_else(|| "module.rules: missing".to_string())?
            .as_array()
            .ok_or_else(|| "module.rules: not a list".to_string())?;
        if raw_rules.is_empty() {
            return Err("module.rules: empty — a module with no rule routes nothing".to_string());
        }
        let mut rules = Vec::new();
        for (index, raw) in raw_rules.iter().enumerate() {
            rules.push(parse_rule(raw).map_err(|error| format!("module.rules[{index}]: {error}"))?);
        }
        let mut classes: Vec<String> = Vec::new();
        for rule in &rules {
            for class in &rule.classes {
                if !classes.iter().any(|known| known.eq_ignore_ascii_case(class)) {
                    classes.push(class.clone());
                }
            }
        }
        let labels = rules.iter().find_map(|rule| rule.labels.clone());
        Ok(TableRouter {
            info: ModuleInfo { name, version, description, classes, labels },
            rules,
        })
    }

    /// The rules, for a test or `wa models explain`.
    pub fn rules(&self) -> &[PolicyRule] {
        &self.rules
    }
}

fn parse_rule(raw: &Value) -> Result<PolicyRule, String> {
    let object = raw.as_object().ok_or_else(|| "not a JSON object".to_string())?;
    let name = match object.get("name") {
        Some(Value::String(text)) if !text.is_empty() => text.clone(),
        _ => return Err("name: missing".to_string()),
    };
    let classes = match object.get("classes") {
        Some(Value::Array(values)) if !values.is_empty() => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(|text| text.to_string())
                    .ok_or_else(|| "classes: not a list of class names".to_string())
            })
            .collect::<Result<Vec<_>, String>>()?,
        _ => return Err("classes: missing or empty".to_string()),
    };
    let labels = match object.get("labels") {
        None | Some(Value::Null) => None,
        Some(Value::Array(values)) => {
            let mut labels = Vec::new();
            for value in values {
                let text = value
                    .as_str()
                    .ok_or_else(|| "labels: not a list of label strings".to_string())?;
                let label = Label::parse(text).ok_or_else(|| format!("labels: {text:?} is not public|internal|client"))?;
                if !labels.contains(&label) {
                    labels.push(label);
                }
            }
            if labels.is_empty() {
                return Err("labels: empty — a rule that applies to no label routes nothing".to_string());
            }
            Some(labels)
        }
        Some(_) => return Err("labels: not a list".to_string()),
    };
    let models = match object.get("models") {
        Some(Value::Array(values)) if !values.is_empty() => values
            .iter()
            .enumerate()
            .map(|(index, value)| {
                let text = value
                    .as_str()
                    .ok_or_else(|| format!("models[{index}]: not a provider/model string"))?;
                ModelRef::parse(text).map_err(|error| format!("models[{index}]: {error}"))
            })
            .collect::<Result<Vec<_>, String>>()?,
        _ => return Err("models: missing or empty".to_string()),
    };
    let skills = match object.get("skills") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(|text| text.to_string())
                    .ok_or_else(|| "skills: not a list of skill names".to_string())
            })
            .collect::<Result<Vec<_>, String>>()?,
        Some(_) => return Err("skills: not a list".to_string()),
    };
    Ok(PolicyRule { name, classes, labels, models, skills })
}

impl RouterModule for TableRouter {
    fn info(&self) -> ModuleInfo {
        self.info.clone()
    }

    fn decide(&self, _policy: &Policy, request: &RouteRequest) -> Decision {
        // An explicit model is the caller's answer, not the module's to override: the module still
        // attaches the skills its rules would have asked for, but never replaces the model.
        if let Some(model) = &request.explicit {
            let mut decision = Decision::route(&self.info.name, "explicit", vec![model.clone()]);
            for rule in &self.rules {
                if rule.applies(request) {
                    decision.skills = rule.skills.clone();
                    break;
                }
            }
            return decision;
        }
        for rule in &self.rules {
            if rule.applies(request) {
                return Decision::route(&self.info.name, format!("rule:{}", rule.name), rule.models.clone())
                    .with_skills(rule.skills.clone());
            }
        }
        // No rule for this class/label: the module declines, and the gateway uses its own routing. A
        // module that silently invented a route would be a second, unauditable default.
        Decision {
            module: self.info.name.clone(),
            source: "no_rule".to_string(),
            candidates: Vec::new(),
            skills: Vec::new(),
            fallback: Some(format!(
                "no rule for class {} label {}",
                request.class_name,
                request.label.as_str()
            )),
        }
    }
}

/// The installed modules and which one is current.
///
/// A module is added, upgraded and switched exactly like a service component: `install` is an upgrade
/// when the name is already present (new version, new generation), `switch_to` changes the current
/// module, and both answer the generation they produced. `decide` clones the current `Arc` first, which
/// is what makes "a swap changes the next call, a call in flight keeps its module" true by
/// construction rather than by timing.
pub struct RouterRegistry {
    current: String,
    generation: u32,
    modules: BTreeMap<String, (ModuleInfo, Arc<dyn RouterModule>)>,
}

impl Default for RouterRegistry {
    fn default() -> Self {
        RouterRegistry::new()
    }
}

impl RouterRegistry {
    /// The default module installed and current: enabling the seam changes nothing.
    pub fn new() -> RouterRegistry {
        let mut modules: BTreeMap<String, (ModuleInfo, Arc<dyn RouterModule>)> = BTreeMap::new();
        let default: Arc<dyn RouterModule> = Arc::new(DefaultRouter::new());
        let info = default.info();
        modules.insert(info.name.clone(), (info, default));
        RouterRegistry { current: "default".to_string(), generation: 1, modules }
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }

    pub fn current(&self) -> String {
        self.current.clone()
    }

    pub fn modules(&self) -> Vec<ModuleInfo> {
        self.modules.values().map(|(info, _)| info.clone()).collect()
    }

    /// Install or upgrade a module. Answers its generation; a module with the same name and a smaller
    /// version is refused (a downgrade is an operator decision made with an explicit `switch_to`, not
    /// an accidental install).
    pub fn install(&mut self, module: Arc<dyn RouterModule>) -> Result<u32, String> {
        let info = module.info();
        if info.name.is_empty() {
            return Err("module.name: empty".to_string());
        }
        if let Some((existing, _)) = self.modules.get(&info.name) {
            if info.version < existing.version {
                return Err(format!(
                    "module.{}: version {} is older than the installed {}",
                    info.name, info.version, existing.version
                ));
            }
        }
        self.generation += 1;
        self.modules.insert(info.name.clone(), (info, module));
        Ok(self.generation)
    }

    /// Switch the current module. Atomic: the next `decide` uses it, and a caller that already asked
    /// keeps what it cloned.
    pub fn switch_to(&mut self, name: &str) -> Result<u32, String> {
        if !self.modules.contains_key(name) {
            return Err(format!("module.{name}: not installed"));
        }
        if self.current != name {
            self.current = name.to_string();
            self.generation += 1;
        }
        Ok(self.generation)
    }

    /// Decide with the current module. A module that declines falls back to the default module, and
    /// says so in `source` - a fallback must be visible in `wa models explain`.
    pub fn decide(&self, policy: &Policy, request: &RouteRequest) -> Decision {
        let module = match self.modules.get(&self.current) {
            Some((_, module)) => Arc::clone(module),
            None => Arc::new(DefaultRouter::new()),
        };
        let decision = module.decide(policy, request);
        if let Some(reason) = decision.fallback.clone() {
            let fallback = match self.modules.get("default") {
                Some((_, module)) => Arc::clone(module),
                None => Arc::new(DefaultRouter::new()),
            };
            let mut routed = fallback.decide(policy, request);
            routed.source = format!("{} (fallback: {}: {})", routed.source, decision.module, reason);
            return routed;
        }
        decision
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_model_gateway::{plan_chat, Breakers};

    const POLICY: &str = r#"{
      "providers": [
        {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
         "allowed_labels": ["public", "internal"], "models": ["deepseek-v4.1-flash"]},
        {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
         "allowed_labels": ["public", "internal", "client"], "models": ["claude-sonnet-4-5"]}
      ],
      "routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"],
                 "default": ["deepseek/deepseek-v4.1-flash"]}
    }"#;

    const FLEET_OPS: &str = r#"{
      "name": "fleet-ops", "version": 1,
      "description": "Fleet operations go to the strong model and load the fleetops skill.",
      "rules": [
        {"name": "fleet-ops", "classes": ["fleet-ops", "plan"],
         "models": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"],
         "skills": ["fleetops"]}
      ]
    }"#;

    fn policy() -> Policy {
        Policy::parse(POLICY).expect("policy parses")
    }

    #[test]
    fn the_default_module_is_the_gateways_own_routing() {
        let policy = policy();
        let router = DefaultRouter::new();
        let breakers = Breakers::default();
        for class in TaskClass::ALL {
            for label in Label::ALL {
                let request = RouteRequest::new(class, label);
                let decision = router.decide(&policy, &request);
                let planned = plan_chat(&policy, class, label, None, &breakers, 0);
                let expected: Vec<ModelRef> = planned.choices.iter().map(|choice| choice.model.clone()).collect();
                assert_eq!(
                    decision.candidates, expected,
                    "class {} label {}: the default module must answer the same candidates the gateway plans",
                    class.as_str(),
                    label.as_str()
                );
                let (source, _) = policy.route_for(class);
                assert_eq!(decision.source, source, "and the same reason for them");
            }
        }
    }

    #[test]
    fn the_default_module_leaves_an_explicit_model_exactly_as_the_gateway_does() {
        let policy = policy();
        let router = DefaultRouter::new();
        let breakers = Breakers::default();
        for text in ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"] {
            let model = ModelRef::parse(text).expect("ref");
            let request = RouteRequest::new(TaskClass::Default, Label::Internal).with_explicit(model.clone());
            let decision = router.decide(&policy, &request);
            assert_eq!(decision.candidates, vec![model.clone()]);
            assert_eq!(decision.source, "explicit");
            let planned = plan_chat(&policy, TaskClass::Default, Label::Internal, Some(&model), &breakers, 0);
            assert_eq!(planned.choices.len(), 1);
            assert_eq!(planned.choices[0].model, model);
        }
        // A class with neither its own route nor a default is no route, not a guess.
        let empty = Policy::empty();
        let decision = router.decide(&empty, &RouteRequest::new(TaskClass::Plan, Label::Public));
        assert!(decision.is_empty());
        assert_eq!(decision.source, "none");
    }

    #[test]
    fn a_fleet_ops_module_routes_the_strong_model_and_names_the_skill() {
        let policy = policy();
        let module = Arc::new(TableRouter::parse(FLEET_OPS).expect("module parses"));
        let mut registry = RouterRegistry::new();
        assert_eq!(registry.current(), "default");
        // Before the swap: a fleet-ops turn has no route of its own and falls back to `default`.
        let request = RouteRequest::new(TaskClass::Default, Label::Internal).with_class_name("fleet-ops");
        let before = registry.decide(&policy, &request);
        assert_eq!(before.module, "default");
        assert_eq!(before.candidates, vec![ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()]);
        assert!(before.skills.is_empty());

        let generation = registry.install(module).expect("install");
        assert_eq!(generation, 2);
        registry.switch_to("fleet-ops").expect("switch");
        // After the swap, in the same process: the strong model, and the skill named.
        let after = registry.decide(&policy, &request);
        assert_eq!(after.module, "fleet-ops");
        assert_eq!(after.source, "rule:fleet-ops");
        assert_eq!(
            after.candidates,
            vec![
                ModelRef::parse("anthropic/claude-sonnet-4-5").unwrap(),
                ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()
            ]
        );
        assert_eq!(after.skills, vec!["fleetops".to_string()]);
        assert_ne!(before.candidates, after.candidates, "the swap changed routing without a restart");
    }

    #[test]
    fn a_swap_sends_the_next_call_to_the_new_module_and_leaves_one_in_flight_alone() {
        let policy = policy();
        let mut registry = RouterRegistry::new();
        let second = TableRouter::parse(
            r#"{"name":"cheap-everything","version":2,"rules":[
                 {"name":"cheap","classes":["*"],"models":["deepseek/deepseek-v4.1-flash"]}]}"#,
        )
        .expect("module parses");
        registry.install(Arc::new(second)).expect("install");
        // A call that asks now gets the module that is current now.
        let request = RouteRequest::new(TaskClass::Plan, Label::Internal);
        let in_flight = registry.decide(&policy, &request);
        assert_eq!(in_flight.module, "default");
        registry.switch_to("cheap-everything").expect("switch");
        let next = registry.decide(&policy, &request);
        assert_eq!(next.module, "cheap-everything");
        assert_eq!(next.candidates, vec![ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()]);
        assert_eq!(in_flight.source, "route", "the answer already given did not change under it");
        registry.switch_to("default").expect("switch back");
        assert_eq!(registry.decide(&policy, &request).module, "default");
    }

    #[test]
    fn a_module_can_narrow_labels_but_the_gateway_still_drops_what_a_provider_may_not_see() {
        let policy = policy();
        // A rule that claims a client turn belongs to the public-only provider.
        let module = TableRouter::parse(
            r#"{"name":"leaky","version":1,"rules":[
                 {"name":"client-to-deepseek","classes":["*"],"labels":["client"],
                  "models":["deepseek/deepseek-v4.1-flash"]}]}"#,
        )
        .expect("module parses");
        let request = RouteRequest::new(TaskClass::Default, Label::Client);
        let decision = module.decide(&policy, &request);
        assert_eq!(decision.candidates, vec![ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()]);
        // The router named it; the gateway still refuses to send a client-labelled request there.
        let breakers = Breakers::default();
        let planned = plan_chat(
            &policy,
            TaskClass::Default,
            Label::Client,
            Some(&decision.candidates[0]),
            &breakers,
            0,
        );
        assert!(planned.refusal.is_some(), "the label gate is not the module's to waive");
        assert!(!planned.choices.iter().any(|choice| choice.usable));
        // And a rule that names only `client` does not apply to an internal turn: it is narrowed, not
        // universal.
        let internal = module.decide(&policy, &RouteRequest::new(TaskClass::Default, Label::Internal));
        assert!(internal.is_empty());
        assert_eq!(
            internal.fallback.as_deref(),
            Some("no rule for class default label internal")
        );
    }

    #[test]
    fn a_module_that_declines_falls_back_to_the_default_and_says_so() {
        let policy = policy();
        let module = Arc::new(TableRouter::parse(FLEET_OPS).expect("module parses"));
        let mut registry = RouterRegistry::new();
        registry.install(module).expect("install");
        registry.switch_to("fleet-ops").expect("switch");
        // `cheap` is not in the module's classes, so the default module answers - visibly.
        let decision = registry.decide(&policy, &RouteRequest::new(TaskClass::Cheap, Label::Internal));
        assert_eq!(decision.module, "default");
        assert!(decision.source.contains("fallback"), "{}", decision.source);
        assert!(decision.source.contains("no rule for class cheap"));
        assert_eq!(decision.candidates, vec![ModelRef::parse("deepseek/deepseek-v4.1-flash").unwrap()]);
    }

    #[test]
    fn a_policy_typo_is_a_named_error() {
        let cases = [
            (r#"{"rules":[]}"#, "module.name"),
            (
                r#"{"name":"x","version":1,"rules":[{"name":"r","classes":["plan"],"models":["nomodel"]}]}"#,
                "models[0]",
            ),
            (
                r#"{"name":"x","version":1,"rules":[{"name":"r","classes":[],"models":["a/b"]}]}"#,
                "classes",
            ),
            (
                r#"{"name":"x","version":1,"rules":[{"name":"r","classes":["plan"],"labels":["secret"],"models":["a/b"]}]}"#,
                "labels",
            ),
            (r#"{"name":"default","rules":[{"name":"r","classes":["*"],"models":["a/b"]}]}"#, "reserved"),
            (r#"{"name":"x","rules":[]}"#, "empty"),
        ];
        for (text, expected) in cases {
            let error = TableRouter::parse(text).expect_err("must fail");
            assert!(error.contains(expected), "{expected} not in {error}");
        }
        // A downgrade is refused: an accidental install must not roll a policy back.
        let mut registry = RouterRegistry::new();
        registry
            .install(Arc::new(
                TableRouter::parse(r#"{"name":"p","version":3,"rules":[{"name":"r","classes":["*"],"models":["a/b"]}]}"#)
                    .unwrap(),
            ))
            .expect("install v3");
        let error = registry
            .install(Arc::new(
                TableRouter::parse(r#"{"name":"p","version":2,"rules":[{"name":"r","classes":["*"],"models":["a/b"]}]}"#)
                    .unwrap(),
            ))
            .expect_err("downgrade refused");
        assert!(error.contains("older than the installed 3"), "{error}");
        assert!(registry.switch_to("nope").is_err());
    }

    #[test]
    fn the_module_list_names_every_installed_policy() {
        let mut registry = RouterRegistry::new();
        registry
            .install(Arc::new(TableRouter::parse(FLEET_OPS).expect("module parses")))
            .expect("install");
        let names: Vec<String> = registry.modules().into_iter().map(|info| info.name).collect();
        assert_eq!(names, vec!["default".to_string(), "fleet-ops".to_string()]);
        let fleet = registry
            .modules()
            .into_iter()
            .find(|info| info.name == "fleet-ops")
            .expect("fleet-ops");
        assert_eq!(fleet.version, 1);
        assert!(fleet.classes.contains(&"fleet-ops".to_string()));
        assert!(fleet.labels.is_none());
    }
}
