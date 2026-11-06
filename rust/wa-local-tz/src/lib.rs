//! Which time zone this node's OS is in, and where that answer was read from
//! (docs/KERNEL.md, "the node's own zone").
//!
//! The node already knows the *offset* it is in: the C runtime the native interpreter links answers
//! `os.date("%z")` for any instant, DST included. Inside a wasm component that C runtime is
//! wasi-libc, which knows no zone at all, so the guest used to report `+00:00` for a node that was
//! in `-03:00`. The kernel therefore answers the guest's `host.local_tz(epoch)` itself, and this
//! crate is the half the C runtime cannot give: the **identifier** of the zone the OS is configured
//! with - `America/Sao_Paulo` on Unix, `E. South America Standard Time` on Windows - plus the word
//! saying which of the four places it was read from, so nothing has to guess what it is looking at.
//!
//! The offset and the abbreviation deliberately do *not* live here. They are read from the host's
//! own C runtime, through the same `lua/core/platform.lua` function the native core calls, which is
//! what makes a native run and a guest run report the same local timestamp for the same instant
//! instead of two implementations that mostly agree (`rust/wa-capabilities/src/core_component.rs`,
//! `State::local_tz`).
//!
//! Precedence is one rule on every platform, because it is the order the C runtime itself applies:
//!
//! 1. `TZ`, when it names a zone. `TZ` is what `tzset` reads, so an operator who set it is in that
//!    zone whatever the machine's own setting says. A leading `:` (POSIX) is not part of the name. A
//!    POSIX *rule* (`EST5EDT`, `UTC0`, `<+0530>-5:30`) is not a name: it reports [`SOURCE_TZ_RULE`]
//!    and no id, because inventing one would be a lie the offset would then contradict. A name this
//!    platform has no database for is [`SOURCE_TZ_UNKNOWN`] - measured on Windows, whose CRT parses a
//!    POSIX rule and ignores `TZ=Europe/Berlin`, so reporting that name would claim a zone the
//!    process is not in.
//! 2. Unix: the `/etc/localtime` symlink into the zoneinfo database (the usual glibc/musl setup),
//!    then `/etc/timezone` (Debian's, used when `localtime` is a copy rather than a link).
//! 3. Windows: the dynamic time zone (`GetDynamicTimeZoneInformation().TimeZoneKeyName`).
//! 4. Nothing: a container that ships neither `TZ` nor a zone file is honestly in UTC with no name
//!    - [`SOURCE_NONE`] - and the offset the C runtime reports for it is `+00:00`.
//!
//! No dependency: two structs and one function are the whole Windows surface, and a POSIX-rule check
//! is a shape test. Nothing here reads a clock; it reads configuration.

/// `TZ` named a zone (`America/Sao_Paulo`, `UTC`, or an absolute path to a zone file).
pub const SOURCE_TZ_ENV: &str = "tz_env";
/// `TZ` held a POSIX rule (`EST5EDT`, `<+0530>-5:30`) instead of a zone name.
pub const SOURCE_TZ_RULE: &str = "tz_env_rule";
/// `TZ` named a zone this platform has no database for: no name to report, and no claim that the C
/// runtime applied it (the Windows CRT does not, measured: `TZ=Europe/Berlin` leaves the machine's
/// own offset in place while `TZ=UTC` does take effect).
pub const SOURCE_TZ_UNKNOWN: &str = "tz_env_unknown";
/// `/etc/localtime` is a symlink into the zoneinfo database.
pub const SOURCE_LOCALTIME: &str = "localtime";
/// `/etc/timezone` names the zone (Debian-style, with `/etc/localtime` a copy).
pub const SOURCE_ETC_TIMEZONE: &str = "etc_timezone";
/// The Windows dynamic time zone's key name.
pub const SOURCE_WINDOWS: &str = "windows_api";
/// No zone configured where we can see it: the node is in UTC and has no name to report.
pub const SOURCE_NONE: &str = "none";

/// The zone the node is in, and where that answer came from.
///
/// `id` is the OS's own identifier, not a normalised one: an IANA name on Unix, a Windows zone key on
/// Windows. A caller that needs IANA on Windows needs a mapping table (CLDR `windowsZones`), which
/// this crate does not ship - reporting the key the OS uses is honest, inventing an IANA name from a
/// partial table would not be.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZoneId {
    /// The identifier, or `None` when the node's zone has no name we can read.
    pub id: Option<String>,
    /// One of the `SOURCE_*` words above.
    pub source: &'static str,
}

impl ZoneId {
    /// A zone whose name we read.
    pub fn named(id: impl Into<String>, source: &'static str) -> Self {
        ZoneId { id: Some(id.into()), source }
    }

    /// No name, with the reason it is missing.
    pub fn unnamed(source: &'static str) -> Self {
        ZoneId { id: None, source }
    }

    /// The identifier, when there is one.
    pub fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }
}

/// What the OS shows us before the rule is applied. Every field is `None` when that place held
/// nothing; a caller that hands all-`None` inputs is asking what a bare container reports.
#[derive(Clone, Debug, Default)]
pub struct Inputs {
    /// The value of `TZ` (empty is treated as absent, the way `tzset` treats it).
    pub tz: Option<String>,
    /// Where `/etc/localtime` points, when it is a symlink (Unix only).
    pub localtime_target: Option<String>,
    /// The contents of `/etc/timezone` (Unix only).
    pub etc_timezone: Option<String>,
    /// `TimeZoneKeyName` from the Windows dynamic time zone (Windows only).
    pub windows_zone_key: Option<String>,
}

/// The rule: the inputs, and the answer to "does the zoneinfo database ship this name?".
pub fn resolve_with<F>(inputs: &Inputs, zoneinfo_has: F) -> ZoneId
where
    F: Fn(&str) -> bool,
{
    if let Some(raw) = inputs.tz.as_deref() {
        let text = raw.trim();
        // POSIX: a leading `:` is "look this up in the database" and is not part of the name.
        let text = text.strip_prefix(':').unwrap_or(text).trim();
        if !text.is_empty() {
            return from_tz(text, &zoneinfo_has);
        }
    }
    if let Some(target) = inputs.localtime_target.as_deref() {
        if let Some(name) = zoneinfo_suffix(target) {
            return ZoneId::named(name, SOURCE_LOCALTIME);
        }
    }
    if let Some(text) = inputs.etc_timezone.as_deref() {
        if let Some(name) = first_zone_name(text) {
            return ZoneId::named(name, SOURCE_ETC_TIMEZONE);
        }
    }
    if let Some(key) = inputs.windows_zone_key.as_deref() {
        let key = key.trim();
        if !key.is_empty() {
            return ZoneId::named(key, SOURCE_WINDOWS);
        }
    }
    ZoneId::unnamed(SOURCE_NONE)
}

/// The rule with this machine's real filesystem and zoneinfo database.
pub fn resolve(inputs: &Inputs) -> ZoneId {
    resolve_with(inputs, |name| zoneinfo_dirs().iter().any(|dir| dir.join(name).is_file()))
}

/// This machine's zone, with `TZ` resolved by the caller.
///
/// `TZ` is a parameter rather than a `std::env` read on purpose: the kernel resolves the
/// environment through its own override map (`host.getenv`), and a node whose `TZ` came from
/// `~/.wasm-agent/env` must report the same zone through both.
pub fn zone_id(tz: Option<&str>) -> ZoneId {
    resolve(&Inputs { tz: tz.map(str::to_string), ..read_os_inputs() })
}

/// Everything the OS itself holds, without `TZ`.
pub fn read_os_inputs() -> Inputs {
    Inputs {
        tz: None,
        localtime_target: localtime_target(),
        etc_timezone: etc_timezone(),
        windows_zone_key: windows_zone_key(),
    }
}

/// `TZ`'s value, as a zone name, a zone file path, or neither.
fn from_tz<F>(text: &str, zoneinfo_has: &F) -> ZoneId
where
    F: Fn(&str) -> bool,
{
    // `TZ=/usr/share/zoneinfo/Europe/Berlin`, and the same path with Windows separators, both name
    // the zone everybody means: the part below the database root.
    if let Some(name) = zoneinfo_suffix(text) {
        return ZoneId::named(name, SOURCE_TZ_ENV);
    }
    // `TZ=/etc/localtime.d/berlin`: a zone file the operator names, not a name in the database. The
    // offset is still the C runtime's; the path is the truest identifier available.
    if text.starts_with('/') || (text.len() > 2 && text.as_bytes()[1] == b':' && text.as_bytes()[2] == b'\\') {
        return ZoneId::named(text, SOURCE_TZ_ENV);
    }
    // A name the zoneinfo database ships: `America/Sao_Paulo`, `UTC`, `Etc/GMT+3`. The database is
    // what `tzset` would read, so its presence is what makes it a name rather than a rule.
    if zoneinfo_has(text) || is_windows_zone_key(text) {
        return ZoneId::named(text, SOURCE_TZ_ENV);
    }
    // Everything else is one of two things, and they are told apart by what a rule always carries: a
    // number. `EST5EDT`, `UTC0`, `<+0530>-5:30` and `CET-1CEST,M3.5.0,M10.5.0/3` are rules the C
    // runtime parses itself; `Europe/Berlin` on a platform whose database does not have it is a name
    // we cannot resolve, and calling *that* a rule would be a guess.
    if text.bytes().any(|byte| byte.is_ascii_digit()) {
        ZoneId::unnamed(SOURCE_TZ_RULE)
    } else {
        ZoneId::unnamed(SOURCE_TZ_UNKNOWN)
    }
}

/// The part of a path below a `zoneinfo` directory, or `None` when the path is not in the database.
/// Handles both separators, because a Windows `TZ` may use either.
fn zoneinfo_suffix(path: &str) -> Option<String> {
    let normalized = path.replace('\\', "/");
    let needle = "/zoneinfo/";
    let at = normalized.find(needle)?;
    let name = normalized[at + needle.len()..].trim_matches('/');
    if name.is_empty() {
        return None;
    }
    // A database path is two or three components; a trailing junk component (a second `zoneinfo`,
    // a `.` from a relative link) is not. Refusing rather than trimming keeps this a reader.
    if name.split('/').any(|part| part.is_empty() || part == "." || part == "..") {
        return None;
    }
    Some(name.to_string())
}

/// Debian's `/etc/timezone`: the first non-empty line, when it looks like a zone name rather than
/// the prose a hand-edited file may hold.
fn first_zone_name(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|line| !line.is_empty() && !line.starts_with('#'))?;
    let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '/' | '_' | '-' | '+' | '.');
    if line.len() > 128 || !line.chars().all(allowed) || line.starts_with('/') || line.starts_with('.') {
        return None;
    }
    // `UTC` and `Etc/UTC` are names; `MST7MDT` and `CET-1CEST` are rules that Debian would not put
    // here. Both shapes are accepted: the file says "this is the zone", and the C runtime applies it.
    Some(line.to_string())
}

/// Windows keys all carry " Time" (`E. South America Standard Time`, `Pacific Standard Time`), and
/// the OS's key for UTC is exactly `UTC`.
fn is_windows_zone_key(text: &str) -> bool {
    text.ends_with(" Time") || text.eq_ignore_ascii_case("utc")
}

/// The zoneinfo database's roots, in the order `tzset` searches them.
fn zoneinfo_dirs() -> Vec<std::path::PathBuf> {
    ["/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo"]
        .iter()
        .map(std::path::PathBuf::from)
        .collect()
}

#[cfg(unix)]
fn localtime_target() -> Option<String> {
    std::fs::read_link("/etc/localtime").ok().map(|path| path.to_string_lossy().into_owned())
}

#[cfg(not(unix))]
fn localtime_target() -> Option<String> {
    None
}

#[cfg(unix)]
fn etc_timezone() -> Option<String> {
    std::fs::read_to_string("/etc/timezone").ok()
}

#[cfg(not(unix))]
fn etc_timezone() -> Option<String> {
    None
}

/// `GetDynamicTimeZoneInformation().TimeZoneKeyName`: the zone the Control Panel is set to, by the
/// key the OS itself uses. Declared here rather than taken from a binding crate: two structs and one
/// function, in the layout `timezoneapi.h` documents.
#[cfg(windows)]
fn windows_zone_key() -> Option<String> {
    #[repr(C)]
    struct SystemTime {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        milliseconds: u16,
    }

    /// `DYNAMIC_TIME_ZONE_INFORMATION` (Windows 8+). `TIME_ZONE_INFORMATION` is the same struct
    /// without the last two fields, so this layout reads both.
    #[repr(C)]
    struct DynamicTimeZoneInformation {
        bias: i32,
        standard_name: [u16; 32],
        standard_date: SystemTime,
        standard_bias: i32,
        daylight_name: [u16; 32],
        daylight_date: SystemTime,
        daylight_bias: i32,
        time_zone_key_name: [u16; 128],
        dynamic_daylight_time_disabled: u8,
    }

    #[link(name = "kernel32")]
    extern "system" {
        /// `TIME_ZONE_ID_INVALID` (0xFFFFFFFF) on failure.
        fn GetDynamicTimeZoneInformation(info: *mut DynamicTimeZoneInformation) -> u32;
    }

    let mut info: DynamicTimeZoneInformation = unsafe { std::mem::zeroed() };
    let state = unsafe { GetDynamicTimeZoneInformation(&mut info) };
    if state == u32::MAX {
        return None;
    }
    // The key name is NUL-terminated inside a 128-wchar field.
    let end = info.time_zone_key_name.iter().position(|unit| *unit == 0).unwrap_or(info.time_zone_key_name.len());
    let key = String::from_utf16_lossy(&info.time_zone_key_name[..end]);
    if key.is_empty() {
        None
    } else {
        Some(key)
    }
}

#[cfg(not(windows))]
fn windows_zone_key() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A zoneinfo database that ships exactly these names.
    fn database(names: &'static [&'static str]) -> impl Fn(&str) -> bool {
        move |name: &str| names.contains(&name)
    }

    const IANA: &[&str] = &["America/Sao_Paulo", "Europe/Berlin", "UTC", "Etc/UTC", "Asia/Tokyo"];

    fn inputs(tz: Option<&str>, localtime: Option<&str>, etc: Option<&str>, windows: Option<&str>) -> Inputs {
        Inputs {
            tz: tz.map(str::to_string),
            localtime_target: localtime.map(str::to_string),
            etc_timezone: etc.map(str::to_string),
            windows_zone_key: windows.map(str::to_string),
        }
    }

    /// `TZ` naming a zone the database ships is the zone, in all three spellings POSIX allows.
    #[test]
    fn tz_names_a_zone_in_every_spelling() {
        for text in ["America/Sao_Paulo", ":America/Sao_Paulo", "  America/Sao_Paulo  "] {
            let zone = resolve_with(&inputs(Some(text), None, None, None), database(IANA));
            assert_eq!(zone.id(), Some("America/Sao_Paulo"), "{text:?}");
            assert_eq!(zone.source, SOURCE_TZ_ENV, "{text:?}");
        }
        // Windows separators and an absolute path into the database both name the same zone.
        for text in ["/usr/share/zoneinfo/Europe/Berlin", "C:\\zoneinfo\\Europe\\Berlin"] {
            let zone = resolve_with(&inputs(Some(text), None, None, None), database(IANA));
            assert_eq!(zone.id(), Some("Europe/Berlin"), "{text:?}");
            assert_eq!(zone.source, SOURCE_TZ_ENV, "{text:?}");
        }
        // A zone file the operator names by path, outside any database root, keeps the path.
        let zone = resolve_with(&inputs(Some("/etc/zonefiles/berlin"), None, None, None), database(IANA));
        assert_eq!(zone.id(), Some("/etc/zonefiles/berlin"));
        assert_eq!(zone.source, SOURCE_TZ_ENV);
    }

    /// A POSIX *rule* is not a zone name, and the answer says so rather than naming the rule.
    #[test]
    fn a_posix_rule_reports_a_rule_and_no_name() {
        for text in ["EST5EDT", "UTC0", "<+0530>-5:30", "CET-1CEST,M3.5.0,M10.5.0/3"] {
            let zone = resolve_with(&inputs(Some(text), None, None, None), database(IANA));
            assert_eq!(zone.id(), None, "{text:?} must not be reported as a zone name");
            assert_eq!(zone.source, SOURCE_TZ_RULE, "{text:?}");
        }
    }

    /// A name with no database behind it is neither a name nor a rule: measured on Windows, whose CRT
    /// ignores `TZ=Europe/Berlin`, so reporting it as the node's zone would contradict the offset.
    #[test]
    fn a_name_this_platform_cannot_resolve_is_reported_as_unknown() {
        let zone = resolve_with(&inputs(Some("Europe/Berlin"), None, None, Some("E. South America Standard Time")), database(&["America/Sao_Paulo"]));
        assert_eq!(zone.id(), None);
        assert_eq!(zone.source, SOURCE_TZ_UNKNOWN);
    }

    /// `TZ` wins over the machine's own setting, because it is what `tzset` reads.
    #[test]
    fn tz_wins_over_the_machines_own_setting() {
        let zone = resolve_with(
            &inputs(Some("Asia/Tokyo"), Some("/usr/share/zoneinfo/Europe/Berlin"), Some("UTC\n"), None),
            database(IANA),
        );
        assert_eq!(zone.id(), Some("Asia/Tokyo"));
        assert_eq!(zone.source, SOURCE_TZ_ENV);
        // An empty `TZ` is what `tzset` treats as unset.
        for empty in ["", "   ", ":"] {
            let zone = resolve_with(&inputs(Some(empty), Some("/usr/share/zoneinfo/Europe/Berlin"), None, None), database(IANA));
            assert_eq!(zone.id(), Some("Europe/Berlin"), "{empty:?} must fall through to localtime");
        }
    }

    /// With no `TZ`, glibc's symlinked `/etc/localtime` names the zone; Alpine ships the same link.
    #[test]
    fn the_localtime_link_names_the_zone() {
        for target in ["/usr/share/zoneinfo/Europe/Berlin", "/etc/../usr/share/zoneinfo/Europe/Berlin", "/usr/lib/zoneinfo/Asia/Tokyo"] {
            let zone = resolve_with(&inputs(None, Some(target), None, None), database(IANA));
            assert_eq!(zone.id(), Some(if target.contains("Tokyo") { "Asia/Tokyo" } else { "Europe/Berlin" }), "{target:?}");
            assert_eq!(zone.source, SOURCE_LOCALTIME, "{target:?}");
        }
        // Not in the database: a link somewhere else is not a zone name.
        assert_eq!(resolve_with(&inputs(None, Some("/opt/zoneinfo.backup/x"), None, None), database(IANA)).id(), None);
    }

    /// Debian keeps a *copy* of the zone file and the name in `/etc/timezone`.
    #[test]
    fn etc_timezone_names_the_zone_when_localtime_is_a_copy() {
        let zone = resolve_with(&inputs(None, None, Some("# written by dpkg\nAsia/Tokyo\n"), None), database(IANA));
        assert_eq!(zone.id(), Some("Asia/Tokyo"));
        assert_eq!(zone.source, SOURCE_ETC_TIMEZONE);
        // Prose is not a name; a path is not a name either.
        for junk in ["This machine is in Tokyo\n", "/usr/share/zoneinfo/Asia/Tokyo\n", "  \n"] {
            assert_eq!(resolve_with(&inputs(None, None, Some(junk), None), database(IANA)).source, SOURCE_NONE, "{junk:?}");
        }
    }

    /// A container with no `TZ`, no `/etc/localtime` and no `/etc/timezone` is in UTC with no name:
    /// honest about both, never a guess.
    #[test]
    fn a_bare_container_reports_no_name_and_says_so() {
        let zone = resolve_with(&inputs(None, None, None, None), database(IANA));
        assert_eq!(zone.id(), None);
        assert_eq!(zone.source, SOURCE_NONE);
    }

    /// On Windows the OS's own key is the identifier, and `TZ` still wins over it.
    #[test]
    fn windows_reports_its_own_key_and_still_honours_tz() {
        let zone = resolve_with(&inputs(None, None, None, Some("E. South America Standard Time")), database(IANA));
        assert_eq!(zone.id(), Some("E. South America Standard Time"));
        assert_eq!(zone.source, SOURCE_WINDOWS);
        let zone = resolve_with(&inputs(Some("America/Sao_Paulo"), None, None, Some("E. South America Standard Time")), database(IANA));
        assert_eq!(zone.id(), Some("America/Sao_Paulo"));
        assert_eq!(zone.source, SOURCE_TZ_ENV);
    }

    /// The same rule, asked of whatever machine is running the test: the answer is always shaped the
    /// same way - a name or none, and a word naming the place it came from - and it is never a POSIX
    /// rule dressed up as a name.
    #[test]
    fn this_machine_answers_one_of_the_known_sources() {
        let zone = zone_id(std::env::var("TZ").ok().as_deref());
        assert!(
            [SOURCE_TZ_ENV, SOURCE_TZ_RULE, SOURCE_TZ_UNKNOWN, SOURCE_LOCALTIME, SOURCE_ETC_TIMEZONE, SOURCE_WINDOWS, SOURCE_NONE]
                .contains(&zone.source),
            "unknown source {}",
            zone.source
        );
        if zone.source == SOURCE_TZ_RULE || zone.source == SOURCE_TZ_UNKNOWN {
            assert_eq!(zone.id(), None);
        }
    }
}
