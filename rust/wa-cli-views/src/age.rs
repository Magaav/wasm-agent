//! How old a snapshot is, in the words the CLI already uses.
//!
//! A view drawn while a run is in flight is *not* a live read - the interpreter that would read is
//! blocked inside the model call - so the panel says when its data was taken instead of pretending
//! to be current. The wording is the twin of `ago` in `lua/core/nodes_cli.lua` ("seen 2m ago"), so a
//! reader sees one spelling of elapsed time in both surfaces; the case that differs is the zero case,
//! which only this side can produce (a snapshot taken in the same second it is drawn).

/// Seconds as `12s ago` / `2m ago` / `3h ago` / `2d ago`, and `just now` below one second.
pub fn human_age(seconds: i64) -> String {
    if seconds < 1 {
        return "just now".to_string();
    }
    if seconds < 60 {
        return format!("{seconds}s ago");
    }
    if seconds < 3_600 {
        return format!("{}m ago", seconds / 60);
    }
    if seconds < 86_400 {
        return format!("{}h ago", seconds / 3_600);
    }
    format!("{}d ago", seconds / 86_400)
}

/// The line a panel carries so the reader can see it is a snapshot: `snapshot 2m ago`.
///
/// `None` when the snapshot did not say when it was taken (`captured_at <= 0`) or when the caller
/// supplied no clock (`now <= 0`): a line that guessed would be the one wrong sentence on the screen.
/// A capture time in the future - two clocks, one event - is clamped rather than reported as the
/// past, which would read as a much older snapshot than it is.
pub fn age_line(now: i64, captured_at: i64) -> Option<String> {
    if now <= 0 || captured_at <= 0 {
        return None;
    }
    Some(format!(
        "snapshot {}",
        human_age(now.saturating_sub(captured_at).max(0))
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_words_are_the_ones_the_cli_uses() {
        assert_eq!(human_age(0), "just now");
        assert_eq!(human_age(1), "1s ago");
        assert_eq!(human_age(59), "59s ago");
        assert_eq!(human_age(60), "1m ago");
        assert_eq!(human_age(120), "2m ago");
        assert_eq!(human_age(3_600), "1h ago");
        assert_eq!(human_age(86_399), "23h ago");
        assert_eq!(human_age(86_400), "1d ago");
        assert_eq!(human_age(200_000), "2d ago");
    }

    #[test]
    fn a_line_says_a_snapshot_and_nothing_more() {
        assert_eq!(age_line(1_120, 1_000).as_deref(), Some("snapshot 2m ago"));
        assert_eq!(age_line(1_001, 1_000).as_deref(), Some("snapshot 1s ago"));
        assert_eq!(age_line(1_000, 1_000).as_deref(), Some("snapshot just now"));
        // Two clocks, one event: never "snapshot -1s ago", never a claim about the past.
        assert_eq!(age_line(1_000, 1_120).as_deref(), Some("snapshot just now"));
    }

    #[test]
    fn an_unknown_capture_time_says_nothing_rather_than_lying() {
        assert_eq!(age_line(1_000, 0), None);
        assert_eq!(age_line(1_000, -5), None);
        assert_eq!(age_line(0, 1_000), None);
    }
}
