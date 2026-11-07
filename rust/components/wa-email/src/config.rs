//! The connector's non-secret configuration, and the rules it is held to.
//!
//! The definition the operator stores (`services put ... definition.config`) is the source: hosts,
//! ports, the mailbox, the account name, the *name* of the credential, the sender address and the
//! poll interval. A credential value is never part of it - [`Config::parse`] refuses a config that
//! carries one - and the value is read from the vault by name at start (`wa:kernel/credentials`).
//!
//! TLS is required. The only exception is a loopback host (`localhost`, `127.0.0.0/8`, `::1`), which
//! exists so the connector can be tested against an in-process server with no certificate at all; a
//! plaintext session to anything else is refused before a socket is opened.
use serde_json::Value;
use wa_email_outbox::{Mailbox, RateLimiter, RatePolicy, DEFAULT_MIN_INTERVAL_MS, DEFAULT_PER_DAY, DEFAULT_PER_MINUTE};

/// One server: where it is and whether the stream is TLS.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub tls: bool,
}

impl Endpoint {
    /// `host:port`, for a log line: a host and a port are not secrets.
    pub fn authority(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }

    fn loopback(&self) -> bool {
        let host = self.host.to_ascii_lowercase();
        host == "localhost" || host == "::1" || host == "[::1]" || host.starts_with("127.")
    }
}

/// Why a config was refused. `code` is the stable tool/answer word (`email_bad_config`,
/// `email_tls_required`, `email_credential_in_config`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigError {
    pub code: &'static str,
    pub detail: String,
}

impl ConfigError {
    pub fn new(code: &'static str, detail: impl Into<String>) -> ConfigError {
        ConfigError { code, detail: detail.into() }
    }
}

/// The configuration a running connector uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub imap: Endpoint,
    pub smtp: Endpoint,
    /// The mailbox polled (`INBOX` unless the account files everything into a folder).
    pub mailbox: String,
    /// The IMAP/SMTP account name (usually the address).
    pub user: String,
    /// The **name** of the credential in the vault. Never the value.
    pub credential: String,
    /// The `From:` address.
    pub from: Mailbox,
    /// Seconds between two poll rounds.
    pub poll_seconds: u64,
    /// The connector's own send budget.
    pub rate: RatePolicy,
    /// Most messages fetched in one round (a first sync of a big mailbox is bounded).
    pub max_per_round: u32,
    /// How long a fetched body may be before it is truncated (characters).
    pub max_text: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            imap: Endpoint { host: String::new(), port: 993, tls: true },
            smtp: Endpoint { host: String::new(), port: 465, tls: true },
            mailbox: "INBOX".into(),
            user: String::new(),
            credential: String::new(),
            from: Mailbox { local: "unset".into(), domain: "unset".into() },
            poll_seconds: 60,
            rate: RatePolicy { per_minute: DEFAULT_PER_MINUTE, per_day: DEFAULT_PER_DAY, min_interval_ms: DEFAULT_MIN_INTERVAL_MS },
            max_per_round: 50,
            max_text: wa_email_index::MAX_TEXT,
        }
    }
}

impl Config {
    /// Read the JSON the service definition carries.
    ///
    /// Every refusal names the field: a connector that will not start must say which key is wrong
    /// without echoing a value that might be a password.
    pub fn parse(json: &str) -> Result<Config, ConfigError> {
        let value: Value = serde_json::from_str(json).map_err(|error| ConfigError::new("email_bad_config", format!("config is not JSON: {error}")))?;
        if !value.is_object() {
            return Err(ConfigError::new("email_bad_config", "config must be a JSON object"));
        }
        // A password in the config is the one mistake worth refusing loudly: the vault is the only
        // place a credential may live (docs/EMAIL-CONNECTOR.md).
        for key in ["password", "passwd", "secret", "credentials", "imap_password", "smtp_password"] {
            if value.get(key).is_some() {
                return Err(ConfigError::new(
                    "email_credential_in_config",
                    format!("`{key}` must not be in the config: store the password in the vault and name it with `credential`"),
                ));
            }
        }
        let mut config = Config::default();
        config.imap = endpoint(&value, "imap", 993, &config)?;
        config.smtp = endpoint(&value, "smtp", 465, &config)?;
        if let Some(mailbox) = text(&value, "mailbox")? {
            let mailbox = mailbox.trim().to_string();
            if mailbox.is_empty() || mailbox.chars().count() > 64 || mailbox.chars().any(|c| c.is_control()) {
                return Err(ConfigError::new("email_bad_config", "`mailbox` is empty, too long or has a control character"));
            }
            config.mailbox = mailbox;
        }
        let Some(user) = text(&value, "user")? else {
            return Err(ConfigError::new("email_bad_config", "`user` is required (the IMAP/SMTP account name)"));
        };
        if user.trim().is_empty() || user.chars().count() > 254 || user.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err(ConfigError::new("email_bad_config", "`user` is empty, too long or has whitespace/a control character"));
        }
        config.user = user;
        let Some(credential) = text(&value, "credential")? else {
            return Err(ConfigError::new("email_bad_config", "`credential` is required: the vault name of this account's password"));
        };
        let name_ok = !credential.is_empty()
            && credential.chars().count() <= 64
            && credential.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'));
        if !name_ok {
            return Err(ConfigError::new("email_bad_config", "`credential` must be a vault name ([A-Za-z0-9._-/], at most 64)"));
        }
        config.credential = credential;
        let Some(from) = text(&value, "from")? else {
            return Err(ConfigError::new("email_bad_config", "`from` is required: the address this connector sends as"));
        };
        config.from = Mailbox::parse(&from).map_err(|refusal| ConfigError::new("email_bad_from", format!("`from`: {}", refusal.detail)))?;
        if let Some(seconds) = number(&value, "poll_seconds")? {
            if !(5..=3600).contains(&seconds) {
                return Err(ConfigError::new("email_bad_config", "`poll_seconds` must be 5..=3600"));
            }
            config.poll_seconds = seconds;
        }
        if let Some(round) = number(&value, "max_per_round")? {
            if !(1..=500).contains(&round) {
                return Err(ConfigError::new("email_bad_config", "`max_per_round` must be 1..=500"));
            }
            config.max_per_round = round as u32;
        }
        if let Some(rate) = value.get("rate") {
            let per_minute = rate.get("per_minute").and_then(Value::as_u64).unwrap_or(DEFAULT_PER_MINUTE as u64);
            let per_day = rate.get("per_day").and_then(Value::as_u64).unwrap_or(DEFAULT_PER_DAY as u64);
            let gap = rate.get("min_interval_ms").and_then(Value::as_u64).unwrap_or(DEFAULT_MIN_INTERVAL_MS);
            if per_minute == 0 || per_minute > 600 || per_day == 0 || per_day > 100_000 || gap > 600_000 {
                return Err(ConfigError::new("email_bad_config", "`rate` is out of bounds (per_minute 1..=600, per_day 1..=100000, min_interval_ms <= 600000)"));
            }
            config.rate = RatePolicy { per_minute: per_minute as u32, per_day: per_day as u32, min_interval_ms: gap };
        }
        Ok(config)
    }

    /// A limiter for this config's budget.
    pub fn limiter(&self) -> RateLimiter {
        RateLimiter::new(self.rate)
    }
}

fn endpoint(value: &Value, key: &str, default_port: u16, config: &Config) -> Result<Endpoint, ConfigError> {
    let _ = config;
    let Some(object) = value.get(key) else {
        return Err(ConfigError::new("email_bad_config", format!("`{key}` is required ({{host, port, tls}})")));
    };
    let Some(host) = object.get("host").and_then(Value::as_str).map(str::trim).filter(|host| !host.is_empty()) else {
        return Err(ConfigError::new("email_bad_config", format!("`{key}.host` is required")));
    };
    if host.chars().count() > 253 || host.chars().any(|c| c.is_control() || c.is_whitespace() || "/\\@".contains(c)) {
        return Err(ConfigError::new("email_bad_config", format!("`{key}.host` is not a host name")));
    }
    let port = match object.get("port") {
        None => default_port,
        Some(value) => match value.as_u64() {
            Some(port) if (1..=65_535).contains(&port) => port as u16,
            _ => return Err(ConfigError::new("email_bad_config", format!("`{key}.port` must be 1..=65535"))),
        },
    };
    let tls = match object.get("tls") {
        None => true,
        Some(value) => value.as_bool().ok_or_else(|| ConfigError::new("email_bad_config", format!("`{key}.tls` must be true or false")))?,
    };
    let endpoint = Endpoint { host: host.to_ascii_lowercase(), port, tls };
    // TLS required: the only plaintext stream allowed is to this machine, where a test server lives.
    if !tls && !endpoint.loopback() {
        return Err(ConfigError::new(
            "email_tls_required",
            format!("`{key}` names {} with tls=false: a plaintext session is only allowed to a loopback host", endpoint.authority()),
        ));
    }
    Ok(endpoint)
}

fn text(value: &Value, key: &str) -> Result<Option<String>, ConfigError> {
    match value.get(key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(ConfigError::new("email_bad_config", format!("`{key}` must be a string"))),
    }
}

fn number(value: &Value, key: &str) -> Result<Option<u64>, ConfigError> {
    match value.get(key) {
        None => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| ConfigError::new("email_bad_config", format!("`{key}` must be a non-negative integer"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn good() -> String {
        serde_json::json!({
            "imap": {"host": "127.0.0.1", "port": 1993, "tls": false},
            "smtp": {"host": "127.0.0.1", "port": 1587, "tls": false},
            "user": "me@example.com",
            "credential": "email-password",
            "from": "me@example.com",
            "poll_seconds": 30,
            "max_per_round": 20,
            "rate": {"per_minute": 4, "per_day": 40, "min_interval_ms": 1500}
        })
        .to_string()
    }

    #[test]
    fn a_loopback_config_parses_and_its_defaults_are_the_documented_ones() {
        let config = Config::parse(&good()).unwrap();
        assert_eq!(config.imap.authority(), "127.0.0.1:1993");
        assert_eq!(config.smtp.authority(), "127.0.0.1:1587");
        assert_eq!(config.mailbox, "INBOX");
        assert_eq!(config.from.addr(), "me@example.com");
        assert_eq!(config.poll_seconds, 30);
        assert_eq!(config.max_per_round, 20);
        assert_eq!(config.rate.per_minute, 4);
        // The defaults for everything the definition may omit.
        let minimal = serde_json::json!({
            "imap": {"host": "127.0.0.1", "tls": false},
            "smtp": {"host": "localhost", "tls": false},
            "user": "me", "credential": "cred", "from": "me@example.com"
        })
        .to_string();
        let config = Config::parse(&minimal).unwrap();
        assert_eq!((config.imap.port, config.smtp.port), (993, 465));
        assert_eq!(config.poll_seconds, 60);
        assert_eq!(config.max_per_round, 50);
        assert_eq!(config.rate.per_minute, DEFAULT_PER_MINUTE);
        assert_eq!(config.limit_smoke(), (DEFAULT_PER_MINUTE, DEFAULT_PER_DAY));
    }

    impl Config {
        /// The budget a test can read without naming the struct fields twice.
        fn limit_smoke(&self) -> (u32, u32) {
            (self.rate.per_minute, self.rate.per_day)
        }
    }

    #[test]
    fn a_plaintext_session_to_a_remote_host_is_refused_before_a_socket_is_opened() {
        // TLS is required; loopback exists only so a test server with no certificate can be used.
        let mut value: Value = serde_json::from_str(&good()).unwrap();
        value["imap"]["host"] = Value::String("imap.example.com".into());
        let error = Config::parse(&value.to_string()).unwrap_err();
        assert_eq!(error.code, "email_tls_required");
        assert!(error.detail.contains("imap.example.com:1993"));
        // The same host with tls=true is fine.
        value["imap"]["tls"] = Value::Bool(true);
        assert!(Config::parse(&value.to_string()).unwrap().imap.tls);
        // TLS defaults to true, so a definition that omits it is safe rather than plaintext.
        let mut value: Value = serde_json::from_str(&good()).unwrap();
        value["imap"] = serde_json::json!({"host": "127.0.0.1", "port": 1993});
        assert!(Config::parse(&value.to_string()).unwrap().imap.tls);
    }

    #[test]
    fn a_password_in_the_config_is_refused_by_name() {
        let mut value: Value = serde_json::from_str(&good()).unwrap();
        value["password"] = Value::String("hunter2".into());
        let error = Config::parse(&value.to_string()).unwrap_err();
        assert_eq!(error.code, "email_credential_in_config");
        assert!(!error.detail.contains("hunter2"), "the refusal must not echo the value");
        assert!(error.detail.contains("vault"));
        for key in ["passwd", "secret", "imap_password", "smtp_password"] {
            let mut value: Value = serde_json::from_str(&good()).unwrap();
            value[key] = Value::String("x".into());
            assert_eq!(Config::parse(&value.to_string()).unwrap_err().code, "email_credential_in_config", "{key}");
        }
    }

    #[test]
    fn every_config_refusal_names_its_field() {
        for (patch, code) in [
            (serde_json::json!({"imap": null}), "email_bad_config"),
            (serde_json::json!({"imap": {"host": ""}}), "email_bad_config"),
            (serde_json::json!({"imap": {"host": "a b"}}), "email_bad_config"),
            (serde_json::json!({"imap": {"host": "127.0.0.1", "port": 0, "tls": false}}), "email_bad_config"),
            (serde_json::json!({"imap": {"host": "127.0.0.1", "port": 70000, "tls": false}}), "email_bad_config"),
            (serde_json::json!({"user": ""}), "email_bad_config"),
            (serde_json::json!({"user": "a b"}), "email_bad_config"),
            (serde_json::json!({"credential": "has space"}), "email_bad_config"),
            (serde_json::json!({"from": "not-an-address"}), "email_bad_from"),
            (serde_json::json!({"poll_seconds": 1}), "email_bad_config"),
            (serde_json::json!({"poll_seconds": 99_999}), "email_bad_config"),
            (serde_json::json!({"max_per_round": 0}), "email_bad_config"),
            (serde_json::json!({"rate": {"per_minute": 0}}), "email_bad_config"),
            (serde_json::json!({"mailbox": "IN\rBOX"}), "email_bad_config"),
        ] {
            let mut value: Value = serde_json::from_str(&good()).unwrap();
            for (key, patch_value) in patch.as_object().unwrap() {
                if patch_value.is_null() {
                    value.as_object_mut().unwrap().remove(key);
                } else {
                    value[key] = patch_value.clone();
                }
            }
            let error = Config::parse(&value.to_string()).unwrap_err();
            assert_eq!(error.code, code, "{patch}");
            assert!(!error.detail.is_empty(), "{patch}");
        }
        assert_eq!(Config::parse("not json").unwrap_err().code, "email_bad_config");
        assert_eq!(Config::parse("[]").unwrap_err().code, "email_bad_config");
    }
}
