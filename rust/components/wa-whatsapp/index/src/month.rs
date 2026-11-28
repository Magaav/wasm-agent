//! The calendar the archive speaks: `YYYY-MM`, UTC, half-open ranges.
//!
//! The archive cuts "a month" and an answer says "this came from the restored month 2026-04", so both
//! ends need to name a month from a timestamp and turn a name back into a range. It is here for the
//! same reason the keys are: two implementations of a month boundary disagree at exactly the edges
//! (a leap February, a message sent at 00:10 on the first) and there is nothing to notice the drift.
//!
//! UTC is deliberate. A month is a storage decision, not a display one: a fixed zone makes the
//! boundary of `whatsapp-archive-2026-04` the same on every node and in every archive, and an answer
//! carries `at_local` for the operator's own zone.

/// Day count since 1970-01-01 for a civil date (proleptic Gregorian; Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of a day count since 1970-01-01.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `YYYY-MM` for an instant, UTC.
pub fn of(ts_ms: i64) -> String {
    let (y, m, _) = civil_from_days(ts_ms.div_euclid(86_400_000));
    format!("{y:04}-{m:02}")
}

/// Is this a `YYYY-MM` this code will accept (and not, say, a path)?
pub fn is_month(month: &str) -> bool {
    let bytes = month.as_bytes();
    if bytes.len() != 7 || bytes[4] != b'-' {
        return false;
    }
    if !bytes[..4].iter().all(u8::is_ascii_digit) || !bytes[5..].iter().all(u8::is_ascii_digit) {
        return false;
    }
    let number: u32 = month[5..].parse().unwrap_or(0);
    (1..=12).contains(&number)
}

/// The half-open range `[start, end)` of a month, in ms, UTC.
pub fn bounds(month: &str) -> Result<(i64, i64), String> {
    if !is_month(month) {
        return Err("month_invalid".to_string());
    }
    let year: i64 = month[..4].parse().map_err(|_| "month_invalid".to_string())?;
    let number: u32 = month[5..].parse().map_err(|_| "month_invalid".to_string())?;
    let start_day = days_from_civil(year, number, 1);
    let (next_year, next_month) = if number == 12 { (year + 1, 1) } else { (year, number + 1) };
    let end_day = days_from_civil(next_year, next_month, 1);
    Ok((start_day * 86_400_000, end_day * 86_400_000))
}

/// The last instant inside a month (its end minus one millisecond).
pub fn last_ms(month: &str) -> Option<i64> {
    bounds(month).ok().map(|(_, end)| end - 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_month_is_a_utc_calendar_month_with_half_open_bounds() {
        assert_eq!(of(0), "1970-01");
        assert_eq!(of(-1), "1969-12", "the instant before the epoch is the previous month");
        assert_eq!(of(1_777_000_000_000), "2026-04");
        let (start, end) = bounds("2026-03").expect("a month");
        assert_eq!(of(start), "2026-03");
        assert_eq!(of(end - 1), "2026-03");
        assert_eq!(of(end), "2026-04");
        assert_eq!(end - start, 31 * 86_400_000, "March has 31 days");
        assert_eq!(bounds("2024-02").map(|(a, b)| b - a).unwrap(), 29 * 86_400_000, "a leap February");
        assert_eq!(bounds("2023-02").map(|(a, b)| b - a).unwrap(), 28 * 86_400_000);
        assert_eq!(bounds("2026-12").map(|(_, end)| of(end)).unwrap(), "2027-01", "December ends in January");
        assert_eq!(last_ms("2026-03"), Some(end - 1));
    }

    #[test]
    fn a_month_that_is_not_one_is_refused_rather_than_guessed() {
        // The name becomes a file name and a key, so anything else is a refusal and not a default.
        for bad in ["2026-13", "2026-00", "26-03", "../../etc", "2026-3", "", "2026/03", "2026-0a"] {
            assert!(!is_month(bad), "{bad:?} is not a month");
            assert!(bounds(bad).is_err(), "{bad:?} has no range");
            assert_eq!(last_ms(bad), None);
        }
    }

    #[test]
    fn every_month_of_a_year_abuts_the_next() {
        for year in [1970, 2000, 2023, 2024, 2026] {
            for month in 1..=12u32 {
                let name = format!("{year:04}-{month:02}");
                let (start, end) = bounds(&name).expect("a month");
                let next = if month == 12 { format!("{:04}-01", year + 1) } else { format!("{year:04}-{:02}", month + 1) };
                assert_eq!(end, bounds(&next).expect("the next month").0, "{name} ends where {next} starts");
                assert_eq!(of(start), name);
            }
        }
    }
}
