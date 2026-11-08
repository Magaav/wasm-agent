//! The `models` section of `policy.json`: providers, per-class routes, budgets, timeouts and rates.
//!
//! This is the operator's file, so it is JSON here and opaque to the seam's own records. Parsing is
//! strict and every complaint names the path it came from (`models.routes.plan[1]: …`), because a
//! policy file that silently falls back to a default is a policy that cannot be audited.
//!
//! ```json
//! "models": {
//!   "version": 1,
//!   "generation": 7,
//!   "providers": [
//!     {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
//!      "hosts": ["api.deepseek.com:443"],
//!      "credential": {"secret": "DEEPSEEK_API_KEY", "header": "authorization", "scheme": "bearer"},
//!      "allowed_labels": ["public", "internal"],
//!      "models": ["deepseek-v4.1-flash"],
//!      "timeout_ms": 45000,
//!      "breaker": {"failures": 5, "cooldown_ms": 30000},
//!      "rates": {"input_per_mtok": 300, "output_per_mtok": 1200, "cache_read_per_mtok": 30}},
//!     {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
//!      "credential": {"secret": "ANTHROPIC_API_KEY", "header": "x-api-key", "scheme": "raw"},
//!      "allowed_labels": ["public", "internal", "client"]}
//!   ],
//!   "routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"]},
//!   "embeddings": {"default": ["deepseek/deepseek-embed"]},
//!   "budgets": {"node_tokens_per_day": 50000000, "session_tokens": 2000000},
//!   "defaults": {"timeout_ms": 60000, "max_attempts": 3, "backoff_ms": 400, "backoff_max_ms": 8000}
//! }
//! ```
//!
//! Two defaults, and the difference between them is the 08/11 decision ("every feature on by default,
//! each with a live per-feature off switch"):
//!
//! * **a provider that names no `allowed_labels` allows `public` and `internal`.** That is today's
//!   configured provider inherited unchanged: before the gateway existed a turn went to DeepSeek or
//!   opencode-go with the operator's own text and no label at all, and `public`/`internal` do not
//!   distinguish anything about a *person*. It still allows **no `client` data** — another person's
//!   message never reaches a provider the operator did not name for it, whatever the default is.
//! * **a provider with no `credential` is anonymous**, which is what a local endpoint wants.
//!
//! Allowing a provider to carry client data is therefore one explicit line, never a default and never a
//! side effect of upgrading: `"allowed_labels": ["public", "internal", "client"]`
//! (`docs/MODEL-GATEWAY.md`, "Allowed labels").

use std::collections::BTreeMap;

use serde_json::Value;

use crate::types::{Label, ModelRef, TaskClass, Usage};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderKind {
    Anthropic,
    OpenAi,
    Gemini,
}

impl ProviderKind {
    pub fn parse(text: &str) -> Option<ProviderKind> {
        match text.trim().to_ascii_lowercase().as_str() {
            "anthropic" | "messages" => Some(ProviderKind::Anthropic),
            // The OpenAI-compatible edge covers DeepSeek, opencode-go and every local server.
            "openai" | "openai-compatible" | "openai_compatible" | "deepseek" => Some(ProviderKind::OpenAi),
            "gemini" | "google" => Some(ProviderKind::Gemini),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            ProviderKind::Anthropic => "anthropic",
            ProviderKind::OpenAi => "openai",
            ProviderKind::Gemini => "gemini",
        }
    }
}

/// How the kernel puts a secret into a header: `authorization: Bearer <value>`, a raw header value
/// (`x-api-key: <value>`), or `?key=<value>` in the query string (Gemini's own spelling).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scheme {
    Bearer,
    Raw,
    Query,
}

impl Scheme {
    pub fn parse(text: &str) -> Option<Scheme> {
        match text.trim().to_ascii_lowercase().as_str() {
            "bearer" => Some(Scheme::Bearer),
            "raw" | "header" => Some(Scheme::Raw),
            "query" => Some(Scheme::Query),
            _ => None,
        }
    }
}

/// A credential reference, never a value: the kernel's http adds it by name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Credential {
    pub secret: String,
    pub header: String,
    pub scheme: Scheme,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rates {
    /// Micro-units of the operator's currency per million tokens.
    pub input_per_mtok: u64,
    pub output_per_mtok: u64,
    pub cache_read_per_mtok: u64,
    pub cache_write_per_mtok: u64,
}

impl Rates {
    pub fn free() -> Rates {
        Rates {
            input_per_mtok: 0,
            output_per_mtok: 0,
            cache_read_per_mtok: 0,
            cache_write_per_mtok: 0,
        }
    }

    /// What one call cost, in micro-units. Integer arithmetic on purpose: money that arrives as a
    /// float is money that disagrees with the invoice.
    pub fn cost_micros(&self, usage: Usage) -> u64 {
        let per = |tokens: u64, rate: u64| -> u64 {
            // tokens * rate / 1e6, kept in u128 so a million-token call cannot overflow.
            ((tokens as u128 * rate as u128) / 1_000_000) as u64
        };
        per(usage.input_tokens, self.input_per_mtok)
            + per(usage.output_tokens, self.output_per_mtok)
            + per(usage.cache_read_tokens, self.cache_read_per_mtok)
            + per(usage.cache_write_tokens, self.cache_write_per_mtok)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BreakerSpec {
    /// Consecutive provider failures that open the breaker.
    pub failures: u32,
    /// How long it stays open before one trial call is allowed.
    pub cooldown_ms: u64,
}

impl Default for BreakerSpec {
    fn default() -> Self {
        BreakerSpec { failures: 5, cooldown_ms: 30_000 }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderSpec {
    pub id: String,
    pub kind: ProviderKind,
    pub base_url: String,
    /// The host:port the kernel's `net` grant is written against (`api.deepseek.com:443`).
    pub hosts: Vec<String>,
    pub credential: Option<Credential>,
    /// Which data labels may reach this provider. Absent means `["public"]`.
    pub allowed_labels: Vec<Label>,
    /// The model ids this provider may serve; absent means "whatever the .routes name".
    pub models: Option<Vec<String>>,
    pub timeout_ms: u64,
    pub breaker: BreakerSpec,
    pub rates: Rates,
}

impl ProviderSpec {
    pub fn allows_label(&self, label: Label) -> bool {
        self.allowed_labels.contains(&label)
    }

    pub fn allows_model(&self, model: &str) -> bool {
        match &self.models {
            None => true,
            Some(list) => list.iter().any(|allowed| allowed == model),
        }
    }

    pub fn labels_text(&self) -> String {
        self.allowed_labels
            .iter()
            .map(|label| label.as_str())
            .collect::<Vec<_>>()
            .join(",")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Budgets {
    /// Tokens per node per UTC day; absent means no node budget.
    pub node_tokens_per_day: Option<u64>,
    /// Tokens per session; absent means no session budget.
    pub session_tokens: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Defaults {
    pub timeout_ms: u64,
    /// How many candidates one call may try (1 = no fallback).
    pub max_attempts: u32,
    pub backoff_ms: u64,
    pub backoff_max_ms: u64,
}

impl Default for Defaults {
    fn default() -> Self {
        Defaults { timeout_ms: 60_000, max_attempts: 3, backoff_ms: 400, backoff_max_ms: 8_000 }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Policy {
    pub version: u32,
    /// Bumped by the core on every reload; one log line per generation, and a call in flight keeps the
    /// policy it started with.
    pub generation: u32,
    pub providers: BTreeMap<String, ProviderSpec>,
    /// class → ordered model refs. `default` is the fallback route for a class nobody named.
    pub routes: BTreeMap<TaskClass, Vec<ModelRef>>,
    pub embeddings: BTreeMap<TaskClass, Vec<ModelRef>>,
    pub budgets: Budgets,
    pub defaults: Defaults,
}

impl Policy {
    /// The empty policy: no provider, no route, so every call is `no_route`. What a node with no
    /// `models` section has, and it must refuse rather than reach for an environment variable.
    pub fn empty() -> Policy {
        Policy {
            version: 1,
            generation: 0,
            providers: BTreeMap::new(),
            routes: BTreeMap::new(),
            embeddings: BTreeMap::new(),
            budgets: Budgets { node_tokens_per_day: None, session_tokens: None },
            defaults: Defaults::default(),
        }
    }

    /// Parse the `models` section, or a whole `policy.json` that contains one.
    pub fn parse(text: &str) -> Result<Policy, String> {
        let root: Value = serde_json::from_str(text).map_err(|error| format!("policy is not JSON: {error}"))?;
        let section = match root.get("models") {
            Some(models) => models.clone(),
            None => root,
        };
        Policy::from_section(&section)
    }

    fn from_section(section: &Value) -> Result<Policy, String> {
        let object = section
            .as_object()
            .ok_or_else(|| "models: not a JSON object".to_string())?;
        let mut policy = Policy::empty();
        policy.version = object.get("version").map(number).transpose()?.unwrap_or(1) as u32;
        policy.generation = object.get("generation").map(number).transpose()?.unwrap_or(0) as u32;

        let providers = object
            .get("providers")
            .ok_or_else(|| "models.providers: missing".to_string())?
            .as_array()
            .ok_or_else(|| "models.providers: not a list".to_string())?;
        for (index, entry) in providers.iter().enumerate() {
            let spec = ProviderSpec::parse(entry).map_err(|error| format!("models.providers[{index}]: {error}"))?;
            if policy.providers.contains_key(&spec.id) {
                return Err(format!("models.providers[{index}]: duplicate provider id {:?}", spec.id));
            }
            policy.providers.insert(spec.id.clone(), spec);
        }

        let routes = object
            .get("routes")
            .ok_or_else(|| "models.routes: missing".to_string())?
            .as_object()
            .ok_or_else(|| "models.routes: not an object".to_string())?;
        for (class_text, refs) in routes {
            let class = TaskClass::parse(class_text)
                .ok_or_else(|| format!("models.routes.{class_text}: not a task class"))?;
            let list = refs
                .as_array()
                .ok_or_else(|| format!("models.routes.{class_text}: not a list"))?
                .iter()
                .enumerate()
                .map(|(index, value)| {
                    let text = value
                        .as_str()
                        .ok_or_else(|| format!("models.routes.{class_text}[{index}]: not a provider/model string"))?;
                    let model = ModelRef::parse(text).map_err(|error| format!("models.routes.{class_text}[{index}]: {error}"))?;
                    if !policy.providers.contains_key(&model.provider) {
                        return Err(format!(
                            "models.routes.{class_text}[{index}]: {} names no provider in models.providers",
                            model.as_string()
                        ));
                    }
                    Ok(model)
                })
                .collect::<Result<Vec<_>, String>>()?;
            if list.is_empty() {
                return Err(format!("models.routes.{class_text}: empty route"));
            }
            policy.routes.insert(class, list);
        }

        if let Some(embeddings) = object.get("embeddings") {
            let map = embeddings
                .as_object()
                .ok_or_else(|| "models.embeddings: not an object".to_string())?;
            for (class_text, refs) in map {
                let class = TaskClass::parse(class_text)
                    .ok_or_else(|| format!("models.embeddings.{class_text}: not a task class"))?;
                let list = refs
                    .as_array()
                    .ok_or_else(|| format!("models.embeddings.{class_text}: not a list"))?
                    .iter()
                    .enumerate()
                    .map(|(index, value)| {
                        let text = value.as_str().ok_or_else(|| {
                            format!("models.embeddings.{class_text}[{index}]: not a provider/model string")
                        })?;
                        let model = ModelRef::parse(text)
                            .map_err(|error| format!("models.embeddings.{class_text}[{index}]: {error}"))?;
                        if !policy.providers.contains_key(&model.provider) {
                            return Err(format!(
                                "models.embeddings.{class_text}[{index}]: {} names no provider",
                                model.as_string()
                            ));
                        }
                        Ok(model)
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                policy.embeddings.insert(class, list);
            }
        }

        if let Some(budgets) = object.get("budgets") {
            let map = budgets
                .as_object()
                .ok_or_else(|| "models.budgets: not an object".to_string())?;
            policy.budgets = Budgets {
                node_tokens_per_day: optional_number(map, "node_tokens_per_day", "models.budgets")?,
                session_tokens: optional_number(map, "session_tokens", "models.budgets")?,
            };
        }

        if let Some(defaults) = object.get("defaults") {
            let map = defaults
                .as_object()
                .ok_or_else(|| "models.defaults: not an object".to_string())?;
            let mut merged = Defaults::default();
            if let Some(timeout) = optional_number(map, "timeout_ms", "models.defaults")? {
                merged.timeout_ms = timeout;
            }
            if let Some(attempts) = optional_number(map, "max_attempts", "models.defaults")? {
                merged.max_attempts = attempts.max(1) as u32;
            }
            if let Some(backoff) = optional_number(map, "backoff_ms", "models.defaults")? {
                merged.backoff_ms = backoff;
            }
            if let Some(max) = optional_number(map, "backoff_max_ms", "models.defaults")? {
                merged.backoff_max_ms = max.max(merged.backoff_ms);
            }
            policy.defaults = merged;
        }

        Ok(policy)
    }

    pub fn provider(&self, id: &str) -> Option<&ProviderSpec> {
        self.providers.get(id)
    }

    /// The ordered candidates for a class: its own route, else `default`, else nothing.
    pub fn route_for(&self, class: TaskClass) -> (&'static str, Option<&Vec<ModelRef>>) {
        if let Some(list) = self.routes.get(&class) {
            return ("route", Some(list));
        }
        if class != TaskClass::Default {
            if let Some(list) = self.routes.get(&TaskClass::Default) {
                return ("route:default", Some(list));
            }
        }
        ("none", None)
    }

    pub fn embed_route_for(&self, class: TaskClass) -> (&'static str, Option<&Vec<ModelRef>>) {
        if let Some(list) = self.embeddings.get(&class) {
            return ("embed", Some(list));
        }
        if class != TaskClass::Default {
            if let Some(list) = self.embeddings.get(&TaskClass::Default) {
                return ("embed:default", Some(list));
            }
        }
        ("none", None)
    }

    /// The provider's timeout, or the policy default.
    pub fn timeout_ms(&self, provider: &str) -> u64 {
        self.provider(provider)
            .map(|spec| spec.timeout_ms)
            .unwrap_or(self.defaults.timeout_ms)
    }
}

impl ProviderSpec {
    fn parse(value: &Value) -> Result<ProviderSpec, String> {
        let object = value.as_object().ok_or_else(|| "not a JSON object".to_string())?;
        let id = string_field(object, "id", "")?;
        if id.is_empty() {
            return Err("id is empty".into());
        }
        let kind_text = string_field(object, "kind", "")?;
        let kind = ProviderKind::parse(&kind_text)
            .ok_or_else(|| format!("kind {kind_text:?} is not anthropic|openai|gemini"))?;
        let base_url = string_field(object, "base_url", "")?;
        if base_url.is_empty() || !base_url.starts_with("http") {
            return Err(format!("base_url {base_url:?} is not an http(s) URL"));
        }
        let hosts = match object.get("hosts") {
            Some(hosts) => hosts
                .as_array()
                .ok_or_else(|| "hosts: not a list".to_string())?
                .iter()
                .map(|host| {
                    host.as_str()
                        .map(|text| text.to_string())
                        .ok_or_else(|| "hosts: not a list of host:port strings".to_string())
                })
                .collect::<Result<Vec<_>, String>>()?,
            None => vec![host_of(&base_url).ok_or_else(|| format!("hosts: cannot derive a host from {base_url:?}"))?],
        };
        let credential = match object.get("credential") {
            None | Some(Value::Null) => None,
            Some(credential) => {
                let map = credential
                    .as_object()
                    .ok_or_else(|| "credential: not an object".to_string())?;
                let scheme_text = string_field(map, "scheme", "raw")?;
                Some(Credential {
                    secret: required_string(map, "secret", "credential")?,
                    header: string_field(map, "header", "authorization")?,
                    scheme: Scheme::parse(&scheme_text)
                        .ok_or_else(|| format!("credential.scheme {scheme_text:?} is not bearer|raw|query"))?,
                })
            }
        };
        let allowed_labels = match object.get("allowed_labels") {
            Some(labels) => {
                let texts = labels
                    .as_array()
                    .ok_or_else(|| "allowed_labels: not a list".to_string())?
                    .iter()
                    .map(|label| {
                        label
                            .as_str()
                            .map(|text| text.to_string())
                            .ok_or_else(|| "allowed_labels: not a list of label strings".to_string())
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                Label::parse_list(&texts).map_err(|error| format!("allowed_labels: {error}"))?
            }
            // Today's provider, inherited: the operator's own text (public) and the operator's own
            // material (internal) may go where a turn went before the gateway existed. Client data is
            // never in the default - naming a provider for it is an explicit line in the policy file.
            None => vec![Label::Public, Label::Internal],
        };
        if allowed_labels.is_empty() {
            return Err("allowed_labels: empty — a provider that may carry nothing is a broken route".into());
        }
        let models = match object.get("models") {
            Some(models) => Some(
                models
                    .as_array()
                    .ok_or_else(|| "models: not a list".to_string())?
                    .iter()
                    .map(|model| {
                        model
                            .as_str()
                            .map(|text| text.to_string())
                            .ok_or_else(|| "models: not a list of model ids".to_string())
                    })
                    .collect::<Result<Vec<_>, String>>()?,
            ),
            None => None,
        };
        let timeout_ms = optional_number(object, "timeout_ms", "")?.unwrap_or(60_000);
        let breaker = match object.get("breaker") {
            Some(breaker) => {
                let map = breaker
                    .as_object()
                    .ok_or_else(|| "breaker: not an object".to_string())?;
                BreakerSpec {
                    failures: optional_number(map, "failures", "breaker")?.unwrap_or(5).max(1) as u32,
                    cooldown_ms: optional_number(map, "cooldown_ms", "breaker")?.unwrap_or(30_000),
                }
            }
            None => BreakerSpec::default(),
        };
        let rates = match object.get("rates") {
            Some(rates) => {
                let map = rates
                    .as_object()
                    .ok_or_else(|| "rates: not an object".to_string())?;
                Rates {
                    input_per_mtok: optional_number(map, "input_per_mtok", "rates")?.unwrap_or(0),
                    output_per_mtok: optional_number(map, "output_per_mtok", "rates")?.unwrap_or(0),
                    cache_read_per_mtok: optional_number(map, "cache_read_per_mtok", "rates")?.unwrap_or(0),
                    cache_write_per_mtok: optional_number(map, "cache_write_per_mtok", "rates")?.unwrap_or(0),
                }
            }
            None => Rates::free(),
        };
        Ok(ProviderSpec {
            id,
            kind,
            base_url,
            hosts,
            credential,
            allowed_labels,
            models,
            timeout_ms,
            breaker,
            rates,
        })
    }
}

/// `https://api.deepseek.com/v1` → `api.deepseek.com:443`.
pub fn host_of(base_url: &str) -> Option<String> {
    let (scheme, rest) = base_url.split_once("://")?;
    let authority = rest.split('/').next()?;
    let port = match scheme {
        "https" => 443,
        "http" => 80,
        _ => return None,
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, text)) if text.chars().all(|c| c.is_ascii_digit()) && !text.is_empty() => {
            (host, text.parse::<u16>().ok()?)
        }
        _ => (authority, port),
    };
    if host.is_empty() {
        return None;
    }
    Some(format!("{host}:{port}"))
}

fn number(value: &Value) -> Result<u64, String> {
    value
        .as_u64()
        .ok_or_else(|| format!("expected a non-negative integer, got {value}"))
}

fn optional_number(
    object: &serde_json::Map<String, Value>,
    key: &str,
    prefix: &str,
) -> Result<Option<u64>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => number(value)
            .map(Some)
            .map_err(|error| if prefix.is_empty() { format!("{key}: {error}") } else { format!("{prefix}.{key}: {error}") }),
    }
}

fn string_field(object: &serde_json::Map<String, Value>, key: &str, default: &str) -> Result<String, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(default.to_string()),
        Some(value) => value
            .as_str()
            .map(|text| text.to_string())
            .ok_or_else(|| format!("{key}: not a string")),
    }
}

fn required_string(object: &serde_json::Map<String, Value>, key: &str, prefix: &str) -> Result<String, String> {
    let value = string_field(object, key, "")?;
    if value.is_empty() {
        return Err(format!("{prefix}.{key}: missing"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    const POLICY: &str = r#"{
      "version": 1,
      "components": {"wa-whatsapp": {}},
      "models": {
        "version": 1,
        "generation": 7,
        "providers": [
          {"id": "deepseek", "kind": "openai", "base_url": "https://api.deepseek.com/v1",
           "credential": {"secret": "DEEPSEEK_API_KEY", "header": "authorization", "scheme": "bearer"},
           "allowed_labels": ["public", "internal"],
           "models": ["deepseek-v4.1-flash"],
           "rates": {"input_per_mtok": 300, "output_per_mtok": 1200, "cache_read_per_mtok": 30}},
          {"id": "anthropic", "kind": "anthropic", "base_url": "https://api.anthropic.com",
           "credential": {"secret": "ANTHROPIC_API_KEY", "header": "x-api-key", "scheme": "raw"},
           "allowed_labels": ["public", "internal", "client"],
           "breaker": {"failures": 2, "cooldown_ms": 1000}}
        ],
        "routes": {"plan": ["anthropic/claude-sonnet-4-5", "deepseek/deepseek-v4.1-flash"],
                   "default": ["deepseek/deepseek-v4.1-flash"]},
        "embeddings": {"default": ["deepseek/deepseek-embed"]},
        "budgets": {"node_tokens_per_day": 50000000, "session_tokens": 2000000},
        "defaults": {"timeout_ms": 120000, "max_attempts": 2, "backoff_ms": 250, "backoff_max_ms": 4000}
      }
    }"#;

    #[test]
    fn a_whole_policy_file_is_read_through_its_models_section() {
        let policy = Policy::parse(POLICY).expect("parses");
        assert_eq!(policy.version, 1);
        assert_eq!(policy.generation, 7);
        assert_eq!(policy.providers.len(), 2);
        let deepseek = policy.provider("deepseek").expect("deepseek");
        assert_eq!(deepseek.kind, ProviderKind::OpenAi);
        assert_eq!(deepseek.hosts, vec!["api.deepseek.com:443"]);
        assert!(deepseek.allows_label(Label::Internal));
        assert!(!deepseek.allows_label(Label::Client));
        assert_eq!(deepseek.credential.as_ref().expect("credential").scheme, Scheme::Bearer);
        assert_eq!(deepseek.breaker, BreakerSpec::default());
        assert_eq!(policy.defaults.timeout_ms, 120_000);
        assert_eq!(policy.defaults.max_attempts, 2);
        let plan = policy.route_for(TaskClass::Plan);
        assert_eq!(plan.0, "route");
        assert_eq!(plan.1.expect("plan route").len(), 2);
        // A class with no route of its own falls back to `default`, and says so.
        let vision = policy.route_for(TaskClass::Vision);
        assert_eq!(vision.0, "route:default");
        assert_eq!(policy.route_for(TaskClass::Default).0, "route");
        assert_eq!(policy.budgets.session_tokens, Some(2_000_000));
    }

    /// The default provider policy (08/11): a provider nobody labelled carries the operator's own data
    /// (public and internal - what a turn was sent with before the gateway existed) and never a client's.
    #[test]
    fn an_absent_allowed_labels_inherits_todays_provider_and_never_client() {
        let policy = Policy::parse(
            r#"{"providers":[{"id":"p","kind":"openai","base_url":"http://127.0.0.1:8080/v1"}],
                "routes":{"default":["p/m"]}}"#,
        )
        .expect("parses");
        let provider = policy.provider("p").expect("p");
        assert_eq!(provider.allowed_labels, vec![Label::Public, Label::Internal]);
        assert!(provider.allows_label(Label::Public));
        assert!(provider.allows_label(Label::Internal), "public/internal are unchanged by the default");
        assert!(!provider.allows_label(Label::Client), "client data needs a provider that says so");
        assert_eq!(provider.labels_text(), "public,internal");
        assert_eq!(provider.hosts, vec!["127.0.0.1:8080"]);
        // ...and naming client is the documented one-line change, nothing else.
        let allowed = Policy::parse(
            r#"{"providers":[{"id":"p","kind":"openai","base_url":"http://127.0.0.1:8080/v1",
                 "allowed_labels":["public","internal","client"]}],
                "routes":{"default":["p/m"]}}"#,
        )
        .expect("parses");
        assert!(allowed.provider("p").expect("p").allows_label(Label::Client));
    }

    #[test]
    fn a_policy_error_names_where_it_came_from() {
        let stray = r#"{"providers":[{"id":"p","kind":"openai","base_url":"http://h:1/v1"}],
                        "routes":{"plan":["q/m"]}}"#;
        let error = Policy::parse(stray).unwrap_err();
        assert!(error.contains("models.routes.plan[0]"), "{error}");
        assert!(error.contains("names no provider"), "{error}");

        let bad_label = r#"{"providers":[{"id":"p","kind":"openai","base_url":"http://h:1/v1",
            "allowed_labels":["secret"]}],"routes":{"default":["p/m"]}}"#;
        assert!(Policy::parse(bad_label).unwrap_err().contains("allowed_labels"));

        let bad_kind = r#"{"providers":[{"id":"p","kind":"hal9000","base_url":"http://h:1/v1"}],
            "routes":{"default":["p/m"]}}"#;
        assert!(Policy::parse(bad_kind).unwrap_err().contains("anthropic|openai|gemini"));

        let no_routes = r#"{"providers":[]}"#;
        assert!(Policy::parse(no_routes).unwrap_err().contains("models.routes: missing"));

        // A route that names a class nobody knows is a typo, not a new class.
        let bad_class = r#"{"providers":[{"id":"p","kind":"openai","base_url":"http://h:1/v1"}],
            "routes":{"plans":["p/m"]}}"#;
        assert!(Policy::parse(bad_class).unwrap_err().contains("not a task class"));
    }

    #[test]
    fn the_empty_policy_routes_nothing() {
        let policy = Policy::empty();
        assert_eq!(policy.route_for(TaskClass::Default).0, "none");
        assert!(policy.route_for(TaskClass::Plan).1.is_none());
    }

    #[test]
    fn cost_is_integer_arithmetic_in_micro_units() {
        let rates = Rates {
            input_per_mtok: 300,
            output_per_mtok: 1200,
            cache_read_per_mtok: 30,
            cache_write_per_mtok: 375,
        };
        let usage = Usage {
            input_tokens: 1_000_000,
            output_tokens: 500_000,
            cache_read_tokens: 2_000_000,
            cache_write_tokens: 0,
            reasoning_tokens: 0,
        };
        // 300 + 600 + 60 = 960 micro-units for this call.
        assert_eq!(rates.cost_micros(usage), 960);
        assert_eq!(Rates::free().cost_micros(usage), 0);
    }

    #[test]
    fn a_base_url_becomes_the_granted_host_port() {
        assert_eq!(host_of("https://api.anthropic.com").as_deref(), Some("api.anthropic.com:443"));
        assert_eq!(host_of("https://api.deepseek.com/v1").as_deref(), Some("api.deepseek.com:443"));
        assert_eq!(host_of("http://127.0.0.1:8080/v1").as_deref(), Some("127.0.0.1:8080"));
        assert_eq!(host_of("http://[::1]:9000/v1").as_deref(), Some("[::1]:9000"));
        assert!(host_of("ftp://example.com").is_none());
    }
}
