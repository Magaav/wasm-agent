//! The own-chat log: every live voice note that ends without a posted transcript queues one alert;
//! alerts go out as one plain-text message at most once a minute (12 listed, the rest counted) to
//! the account's own chat. Same wording as the Go connector (connectors/whatsapp/freshness.go):
//! chat label, send time (America/Sao_Paulo), what happened, the reason - never audio or text.
//! Pure logic: the caller sends the text `due` returns.

pub const MIN_GAP_MS: i64 = 60_000;
pub const BATCH_MAX: usize = 12;
pub const MAX_AGE_MS: i64 = 6 * 3600 * 1000;

#[derive(Clone, Debug, PartialEq)]
pub struct Alert {
    pub chat: String,
    pub title: String,
    pub kind: String,
    pub reason: String,
    pub sent_ms: i64,
    pub at_ms: i64,
}

#[derive(Default)]
pub struct AlertBook {
    pending: Vec<Alert>,
    last_sent_ms: Option<i64>,
}

impl AlertBook {
    pub fn push(&mut self, alert: Alert) {
        // One alert per (chat, source kind) is enough; the queue never reports an item twice anyway.
        self.pending.push(alert);
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// The message to send now, if one is due: something pending and a minute since the last one.
    /// Alerts older than 6 h are dropped unsent. Call `sent` after a successful send.
    pub fn due(&mut self, now: i64) -> Option<String> {
        self.pending.retain(|a| now - a.at_ms <= MAX_AGE_MS);
        if self.pending.is_empty() {
            return None;
        }
        if let Some(last) = self.last_sent_ms {
            if now - last < MIN_GAP_MS {
                return None;
            }
        }
        Some(format(&self.pending))
    }

    /// The message from `due` went out: clear what it listed (all pending; the overflow was counted).
    pub fn sent(&mut self, now: i64) {
        self.pending.clear();
        self.last_sent_ms = Some(now);
    }
}

fn label(kind: &str) -> &str {
    match kind {
        "audio_expired" => "não transcrito em 5 min",
        "post_expired" => "transcrito, mas não enviado em 5 min",
        "post_held" => "transcrito, envio bloqueado (chat em espera)",
        "failed" => "transcrição falhou",
        "unsupported" => "áudio não suportado",
        "blocked" => "bloqueado (revoke/espera)",
        other => other,
    }
}

pub fn chat_label(chat: &str, title: &str) -> String {
    let title: String = title.replace('\n', " ").trim().to_string();
    let title = if title.chars().count() > 40 { title.chars().take(40).collect::<String>() + "…" } else { title };
    let kind = if chat.ends_with("@g.us") { "grupo" } else { "contato" };
    if title.is_empty() {
        format!("{kind} {}", chat.split('@').next().unwrap_or(chat))
    } else {
        format!("{kind} {title}")
    }
}

/// "02/01 15:04" in America/Sao_Paulo (UTC-3; Brazil has had no daylight saving time since 2019).
pub fn sao_paulo(ms: i64) -> String {
    let secs = ms.div_euclid(1000) - 3 * 3600;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil(days);
    let _ = y;
    format!("{d:02}/{m:02} {:02}:{:02}", rem / 3600, (rem % 3600) / 60)
}

/// Days since 1970-01-01 -> (year, month, day) (Howard Hinnant's civil_from_days).
fn civil(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

pub fn format(items: &[Alert]) -> String {
    let mut out = String::from("🛠️ _Copiloto · log_");
    for (i, it) in items.iter().enumerate() {
        if i == BATCH_MAX {
            out.push_str(&format!("\n… +{}", items.len() - BATCH_MAX));
            break;
        }
        out.push_str(&format!("\n• {} · {} · {}\n  motivo: {}", chat_label(&it.chat, &it.title), sao_paulo(it.sent_ms), label(&it.kind), it.reason));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alert(chat: &str, at: i64) -> Alert {
        Alert { chat: chat.into(), title: String::new(), kind: "audio_expired".into(), reason: "stale_over_5m".into(), sent_ms: at, at_ms: at }
    }

    #[test]
    fn at_most_one_message_a_minute_batched() {
        let mut book = AlertBook::default();
        assert!(book.due(0).is_none());
        book.push(alert("1@g.us", 0));
        book.push(alert("2@g.us", 0));
        let text = book.due(0).unwrap();
        assert!(text.starts_with("🛠️ _Copiloto · log_") && text.matches('•').count() == 2);
        book.sent(0);
        book.push(alert("3@g.us", 10_000));
        assert!(book.due(59_999).is_none(), "a minute between messages");
        assert!(book.due(60_000).is_some());
    }

    #[test]
    fn twelve_listed_rest_counted() {
        let items: Vec<Alert> = (0..15).map(|i| alert(&format!("{i}@g.us"), 0)).collect();
        let text = format(&items);
        assert_eq!(text.matches('•').count(), 12);
        assert!(text.ends_with("… +3"));
    }

    #[test]
    fn old_alerts_drop_after_six_hours() {
        let mut book = AlertBook::default();
        book.push(alert("1@g.us", 0));
        assert!(book.due(MAX_AGE_MS + 1).is_none());
        assert_eq!(book.len(), 0);
    }

    #[test]
    fn labels_and_time() {
        assert_eq!(chat_label("5511999@s.whatsapp.net", ""), "contato 5511999");
        assert_eq!(chat_label("1203@g.us", "Família"), "grupo Família");
        // 2026-11-05 21:30 UTC = 18:30 in São Paulo.
        assert_eq!(sao_paulo(1_793_914_200_000), "05/11 18:30");
    }
}
