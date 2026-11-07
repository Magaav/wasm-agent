//! The two text primitives the export edge needs and nothing else: a JSON string escaper and an
//! ISO-8601 UTC stamp.
//!
//! Written by hand for the same reason the rest of the crate has no dependencies: the file a human
//! opens in the morning must not depend on a serializer's version. Escaping is conservative (control
//! bytes, quote, backslash, and the two characters that break a line), so a JSONL row can never
//! contain a raw newline and a corrupted line can never look like two lines.

pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

/// Milliseconds since the Unix epoch as `2023-11-14T22:13:20.123Z` (UTC, milliseconds kept).
///
/// Days-from-civil inverted (Howard Hinnant's `civil_from_days`): no chrono, no locale, no
/// timezone — telemetry timestamps are UTC by definition, and the local time of a node is not a
/// property of the fact being recorded.
pub fn iso8601(ms: u64) -> String {
    let seconds = (ms / 1000) as i64;
    let millis = (ms % 1000) as u32;
    let days = seconds.div_euclid(86_400);
    let of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = of_day / 3600;
    let minute = (of_day % 3600) / 60;
    let second = of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_never_emits_a_raw_line_break() {
        assert_eq!(escape("a\"b\\c\nd\te"), "a\\\"b\\\\c\\nd\\te");
        assert_eq!(escape("caf\u{e9}"), "caf\u{e9}");
        let control = escape("\u{1}");
        assert_eq!(control, "\\u0001");
        assert!(!escape("line\nbreak").contains('\n'));
    }

    #[test]
    fn iso8601_known_instants() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601(1_700_000_000_123), "2023-11-14T22:13:20.123Z");
        assert_eq!(iso8601(1_700_000_000_000), "2023-11-14T22:13:20.000Z");
        assert_eq!(iso8601(951_782_400_000), "2000-02-29T00:00:00.000Z", "a leap day");
        assert_eq!(iso8601(1_798_761_600_000), "2027-01-01T00:00:00.000Z");
    }
}
