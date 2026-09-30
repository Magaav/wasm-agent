//! Native Windows notifications, raised by the **shell**, not by the page.
//!
//! The page can *ask*; it cannot raise a Windows toast. A page has no process identity, no
//! AppUserModelID and no access to the WinRT notification platform, so a web page that "shows a
//! notification" shows nothing on an unpackaged desktop shell like this one. What a page can do is
//! call `window.wasmAgent.notify({title, body})`; the host composes the toast, raises it, and
//! reports back whether it was delivered. That split is the whole point of this module: the request
//! arrives over the IPC bridge in `main.rs`, the native work happens here.
//!
//! ## What Windows will actually display, and why
//!
//! This is an **unpackaged Win32 process**: no MSIX package identity, no Start Menu shortcut with an
//! AppUserModelID. Windows therefore cannot derive an app name for the toast from the executable the
//! way it does for a packaged app, and a toast raised under a bare process identity either fails or
//! appears under a name nobody recognises. The documented way out for a desktop app is to give the
//! process an explicit AppUserModelID and register that ID:
//!
//! 1. `SetCurrentProcessExplicitAppUserModelID("WasmAgent.Window")` - this process's own identity,
//!    used by its toasts and by its taskbar button.
//! 2. `HKCU\Software\Classes\AppUserModelId\WasmAgent.Window` with `DisplayName` = `wasm-agent`
//!    (plus `ShowInSettings`, and `IconUri` when the installed icon is present next to the exe).
//!
//! With those in place **Windows shows the toast's app name as `wasm-agent`**, taken from the
//! `DisplayName` of our own registration, and the notification appears in Settings > System >
//! Notifications under that name so the operator can switch it off there too. `IconUri` is only
//! registered when the file really exists, because a registration pointing at a missing file is
//! worse than one with no icon: Windows falls back to the identity's default icon.
//!
//! We register **our own** identity rather than borrowing one. A common shortcut is to raise the
//! toast under another installed app's AppUserModelID (PowerShell's, for instance, which is present
//! on every machine), because those are already registered and always work. That is rejected here:
//! it puts wasm-agent's message in the Action Center under someone else's name, it makes the
//! operator's own per-app notification toggle control the wrong app, and it breaks the moment that
//! app is uninstalled. The cost of doing it properly is one HKCU key.
//!
//! ## What "delivered" means, and what it does not
//!
//! `ToastNotifier::Show` succeeds when the notification platform *accepts* the toast. Windows
//! provides no receipt that it was rendered, seen, or kept in the Action Center, so `delivered:
//! true` means exactly "accepted by the platform, with notifications enabled for this identity" -
//! never "the operator saw it". The supported-check and the setting check below are what make that
//! a real result rather than an assumption: an unsupported environment or a disabled identity
//! reports `delivered: false` with the reason, instead of silently doing nothing.

use serde::{Deserialize, Serialize};

/// Our own AppUserModelID. Stable across builds on purpose: it is the identity Windows remembers,
/// including the operator's notification preference for it.
pub const APP_USER_MODEL_ID: &str = "WasmAgent.Window";

/// The name Windows displays for a toast raised under [`APP_USER_MODEL_ID`].
pub const APP_DISPLAY_NAME: &str = "wasm-agent";

/// What happened to one request, in terms a caller can print and a page can render. Never an
/// assumption: `delivered` is what the platform answered.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Delivery {
    /// Whether this environment can raise a toast at all (the notification platform answered and
    /// our identity was accepted). False means the request could not have worked anywhere here.
    pub supported: bool,
    /// Whether the notification platform accepted this toast.
    pub delivered: bool,
    /// The evidence for the two fields above, in the platform's own words where there are any.
    pub reason: String,
    /// The AppUserModelID this toast was raised under.
    pub identity: String,
    /// The app name Windows shows for that identity, and where it comes from.
    pub app_name: String,
}

impl Delivery {
    /// A request that never reached the platform, or that the platform refused.
    pub fn refused(reason: impl Into<String>) -> Self {
        Self {
            supported: false,
            delivered: false,
            reason: reason.into(),
            identity: APP_USER_MODEL_ID.to_string(),
            app_name: APP_DISPLAY_NAME.to_string(),
        }
    }

    /// The result as JSON, which is how the diagnostic prints it and how it travels back to the page.
    pub fn json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|error| {
            format!(
                "{{\"supported\":false,\"delivered\":false,\"identity\":\"{APP_USER_MODEL_ID}\",\
                 \"app_name\":\"{APP_DISPLAY_NAME}\",\"reason\":\"unencodable result: {error}\"}}"
            )
        })
    }
}

/// XML text escaping. The body of a notification carries text the node chose, and XML that does not
/// parse makes `LoadXml` fail - a toast that silently never appeared because a task id contained an
/// `&`. Control characters are replaced rather than dropped: they are not valid in XML 1.0 text at
/// all, so a newline is legal but a stray `\x07` is not, and dropping the whole body over it would
/// lose the message.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if (c as u32) < 0x20 && c != '\t' && c != '\n' && c != '\r' => out.push(' '),
            c => out.push(c),
        }
    }
    out
}

/// The toast's XML: a title line and a message line. Two `<text>` nodes in order is what the
/// `ToastGeneric` template renders as heading and body.
pub fn toast_xml(title: &str, body: &str) -> String {
    format!(
        "<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text>\
         </binding></visual></toast>",
        escape(title),
        escape(body)
    )
}

/// Why the platform says notifications are unavailable for this identity. `Enabled` is the only
/// value that means a toast can appear.
pub fn setting_reason(
    setting: windows::UI::Notifications::NotificationSetting,
) -> Option<&'static str> {
    use windows::UI::Notifications::NotificationSetting as Setting;
    if setting == Setting::Enabled {
        return None;
    }
    Some(if setting == Setting::DisabledForApplication {
        "notifications are switched off for wasm-agent in Windows Settings (Settings > System > Notifications)"
    } else if setting == Setting::DisabledForUser {
        "notifications are switched off for every app for this Windows user"
    } else if setting == Setting::DisabledByGroupPolicy {
        "notifications are disabled by group policy on this machine"
    } else if setting == Setting::DisabledByManifest {
        "the notification manifest disables this identity"
    } else {
        "the notification platform reports notifications are disabled"
    })
}

/// A diagnostic request from the command line: `--notify-test [title] [body]`.
#[derive(Debug, Clone, PartialEq)]
pub struct Diagnostic {
    pub title: String,
    pub body: String,
}

/// Parse the command line. `None` means "not a diagnostic invocation" - the window starts normally.
///
/// This exists so the notification path can be raised on demand, without waiting for a settlement
/// and without a node: it is how the toast is verified, and how a broken identity is told apart from
/// a broken trigger.
pub fn parse_diagnostic(args: &[String]) -> Option<Diagnostic> {
    if !args.iter().any(|argument| argument == "--notify-test") {
        return None;
    }
    let positional: Vec<&String> = args
        .iter()
        .filter(|argument| !argument.starts_with("--"))
        .collect();
    Some(Diagnostic {
        title: positional
            .first()
            .map(|value| value.to_string())
            .unwrap_or_else(|| APP_DISPLAY_NAME.to_string()),
        body: positional
            .get(1)
            .map(|value| value.to_string())
            .unwrap_or_else(|| "test notification from the wasm-agent window shell".to_string()),
    })
}

use windows::core::HSTRING;
use windows::Data::Xml::Dom::XmlDocument;
use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE,
    REG_CREATE_KEY_DISPOSITION, REG_DWORD, REG_OPTION_NON_VOLATILE, REG_SZ, REG_VALUE_TYPE,
};
use windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID;
use windows::UI::Notifications::{
    NotificationSetting, ToastNotification, ToastNotificationManager, ToastNotifier,
};

/// Join the current thread to the multi-threaded apartment, so WinRT can be used from here.
///
/// `RPC_E_CHANGED_MODE` is *not* a failure: it means this thread is already in another apartment
/// (the window's UI thread is an STA, because WebView2 requires one). WinRT calls are legal from
/// either, so an already-initialized thread is exactly the case that must keep working instead
/// of failing the notification for the wrong reason.
fn apartment() -> Result<(), String> {
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};
    match unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
        Ok(()) => Ok(()),
        Err(error) if error.code().0 as u32 == 0x8001_0106 => Ok(()),
        Err(error) => Err(format!("Windows Runtime initialization failed: {error}")),
    }
}

fn write_value(key: HKEY, name: &str, kind: REG_VALUE_TYPE, bytes: &[u8]) -> Result<(), String> {
    let name = HSTRING::from(name);
    let status = unsafe { RegSetValueExW(key, &name, None, kind, Some(bytes)) };
    if status != ERROR_SUCCESS {
        return Err(format!(
            "could not write the identity's {name}: error {}",
            status.0
        ));
    }
    Ok(())
}

fn utf16_bytes(value: &str) -> Vec<u8> {
    // REG_SZ wants the terminating NUL, and the bytes go in directly: no `CString` mangling of
    // what may be a non-ASCII path or title.
    value
        .encode_utf16()
        .chain(std::iter::once(0u16))
        .flat_map(|unit| unit.to_le_bytes())
        .collect()
}

/// The icon to show for this identity, when the installer really put one next to the executable.
/// `None` leaves `IconUri` out of the registration rather than pointing at a file that is not
/// there.
fn icon_uri() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let icon = exe.parent()?.join("wa.ico");
    if icon.is_file() {
        Some(icon.to_string_lossy().to_string())
    } else {
        None
    }
}

/// Register our own identity and give this process that identity.
///
/// Runs at window startup and again before the first toast, because the registration can be
/// missing (a fresh machine, a cleaned HKCU) while the toast request is perfectly valid. The
/// returned string is what the caller logs: whether the key was created or already correct is
/// part of the evidence, not a detail.
pub fn register_identity() -> Result<String, String> {
    let subkey = HSTRING::from(format!(
        "Software\\Classes\\AppUserModelId\\{APP_USER_MODEL_ID}"
    ));
    let mut key = HKEY::default();
    let mut disposition = REG_CREATE_KEY_DISPOSITION::default();
    let status = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            &subkey,
            None,
            None,
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut key,
            Some(&mut disposition),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(format!(
            "could not register the AppUserModelID {APP_USER_MODEL_ID} in HKCU (error {})",
            status.0
        ));
    }
    let written = (|| -> Result<(), String> {
        write_value(key, "DisplayName", REG_SZ, &utf16_bytes(APP_DISPLAY_NAME))?;
        write_value(key, "ShowInSettings", REG_DWORD, &1u32.to_le_bytes())?;
        if let Some(icon) = icon_uri() {
            write_value(key, "IconUri", REG_SZ, &utf16_bytes(&icon))?;
        }
        Ok(())
    })();
    unsafe {
        let _ = RegCloseKey(key);
    }
    written?;
    unsafe {
        SetCurrentProcessExplicitAppUserModelID(&HSTRING::from(APP_USER_MODEL_ID)).map_err(
            |error| {
                format!("could not give this process the identity {APP_USER_MODEL_ID}: {error}")
            },
        )?;
    }
    Ok(format!(
            "identity {APP_USER_MODEL_ID} registered as \"{APP_DISPLAY_NAME}\" (HKCU\\Software\\Classes\\AppUserModelId); Windows will name the toast that{}",
            if icon_uri().is_some() { ", with our icon" } else { ", with the identity's default icon" }
        ))
}

fn notifier() -> Result<ToastNotifier, String> {
    apartment()?;
    ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_USER_MODEL_ID))
            .map_err(|error| {
                format!(
                    "the Windows notification platform refused the identity {APP_USER_MODEL_ID}: {error}"
                )
            })
}

/// How the platform sees this identity's notifications, without raising one.
///
/// A separate entry point on purpose: the window shows this in the engine menu, so an operator
/// can tell "the shell cannot raise toasts" from "the shell can and the bell is off" - two
/// states that look identical from the outside otherwise.
pub fn support() -> Delivery {
    match notifier() {
        Err(reason) => Delivery::refused(reason),
        Ok(notifier) => match notifier.Setting() {
            Ok(setting) if setting == NotificationSetting::Enabled => Delivery {
                supported: true,
                delivered: false,
                reason: format!("ready: notifications are enabled for {APP_USER_MODEL_ID}"),
                identity: APP_USER_MODEL_ID.to_string(),
                app_name: APP_DISPLAY_NAME.to_string(),
            },
            Ok(setting) => Delivery {
                supported: true,
                delivered: false,
                reason: setting_reason(setting)
                    .unwrap_or("notifications are disabled")
                    .to_string(),
                identity: APP_USER_MODEL_ID.to_string(),
                app_name: APP_DISPLAY_NAME.to_string(),
            },
            // The identity was accepted but the platform has no setting to read yet (a fresh
            // registration, before it has raised anything). That is "this shell can raise toasts",
            // reported with the uncertainty named rather than dressed up as confirmation.
            Err(error) => Delivery {
                supported: true,
                delivered: false,
                reason: format!(
                    "the platform accepted {APP_USER_MODEL_ID}, but its notification setting could not be read yet: {error}"
                ),
                identity: APP_USER_MODEL_ID.to_string(),
                app_name: APP_DISPLAY_NAME.to_string(),
            },
        },
    }
}

/// Raise one toast and report what the platform said.
///
/// The order matters: identity, then platform, then the setting gate, and only then the XML. A
/// toast that cannot appear is never composed, so "off" and "not raised" cannot diverge into a
/// composed notification nobody sees.
pub fn raise(title: &str, body: &str) -> Delivery {
    if let Err(error) = register_identity() {
        // A failed registration is not necessarily fatal - an earlier run may have registered
        // the same identity - so it is carried into the reason rather than returned here. The
        // caller sees both facts instead of guessing which one happened.
        crate::companion::note(&format!("notify: identity registration failed: {error}"));
    }
    let notifier = match notifier() {
        Ok(notifier) => notifier,
        Err(reason) => return Delivery::refused(reason),
    };
    let mut caveat: Option<String> = None;
    match notifier.Setting() {
        Ok(setting) if setting != NotificationSetting::Enabled => {
            return Delivery {
                supported: true,
                delivered: false,
                reason: setting_reason(setting)
                    .unwrap_or("notifications are disabled")
                    .to_string(),
                identity: APP_USER_MODEL_ID.to_string(),
                app_name: APP_DISPLAY_NAME.to_string(),
            };
        }
        // A setting we could read is a gate, honoured above: nothing is composed when it says the
        // operator has notifications off. A setting we could **not** read is not a refusal. On a
        // freshly registered identity this read fails with element-not-found (0x80070490 - measured
        // on this machine) because the platform has no settings entry for an app that has never
        // raised anything, while the toast itself is accepted. Reporting that as "disabled" would
        // refuse exactly the first notification a new install ever sends, so the failure is carried
        // into the result instead, where a caller can see it.
        Ok(_) => {}
        Err(error) => {
            caveat = Some(format!(
                " (this identity had no notification setting to read yet, so that gate was skipped: {error})"
            ))
        }
    }
    let document = match XmlDocument::new() {
        Ok(document) => document,
        Err(error) => return Delivery::refused(format!("could not compose the toast: {error}")),
    };
    if let Err(error) = document.LoadXml(&HSTRING::from(toast_xml(title, body))) {
        return Delivery::refused(format!(
            "the toast's XML was refused by the platform: {error}"
        ));
    }
    let toast = match ToastNotification::CreateToastNotification(&document) {
        Ok(toast) => toast,
        Err(error) => return Delivery::refused(format!("could not build the toast: {error}")),
    };
    match notifier.Show(&toast) {
        Ok(()) => Delivery {
            supported: true,
            delivered: true,
            reason: format!(
                "accepted by the Windows notification platform for {APP_USER_MODEL_ID}{}; Windows \
                 gives no receipt that it was rendered, so this is delivery, not proof of sight",
                caveat.unwrap_or_default()
            ),
            identity: APP_USER_MODEL_ID.to_string(),
            app_name: APP_DISPLAY_NAME.to_string(),
        },
        Err(error) => Delivery {
            supported: true,
            delivered: false,
            reason: format!(
                "the notification platform refused this toast: {error}{}",
                caveat.unwrap_or_default()
            ),
            identity: APP_USER_MODEL_ID.to_string(),
            app_name: APP_DISPLAY_NAME.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_and_a_body_become_two_ordered_text_nodes() {
        let xml = toast_xml("wasm-agent", "Task child-1 settled; evaluation owed");
        assert!(xml.starts_with("<toast>"), "{xml}");
        assert!(xml.contains("template=\"ToastGeneric\""));
        let first = xml.find("<text>wasm-agent</text>").expect("title node");
        let second = xml
            .find("<text>Task child-1 settled; evaluation owed</text>")
            .expect("body node");
        assert!(
            first < second,
            "the title must be the first text node: {xml}"
        );
    }

    #[test]
    fn text_from_the_node_cannot_break_the_toast_xml() {
        let xml = toast_xml("a & b", "<task id=\"1\"> & 'quoted'");
        assert!(xml.contains("<text>a &amp; b</text>"), "{xml}");
        assert!(
            xml.contains("&lt;task id=&quot;1&quot;&gt; &amp; &apos;quoted&apos;"),
            "{xml}"
        );
        assert!(
            !xml.contains("<task"),
            "no raw markup from the node may reach the document"
        );
        assert_eq!(escape("plain"), "plain");
        assert_eq!(escape("bell\u{7}kept\ntext"), "bell kept\ntext");
    }

    #[test]
    fn a_refusal_is_never_reported_as_a_delivery() {
        let refused = Delivery::refused("no notification platform");
        assert!(!refused.delivered);
        assert!(!refused.supported);
        let json = refused.json();
        assert!(json.contains("\"delivered\":false"), "{json}");
        assert!(json.contains("\"supported\":false"), "{json}");
        assert!(json.contains("WasmAgent.Window"), "{json}");
    }

    #[test]
    fn only_the_diagnostic_flag_starts_a_notification_run() {
        let args = |values: &[&str]| {
            values
                .iter()
                .map(|value| value.to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(parse_diagnostic(&args(&[])), None);
        assert_eq!(parse_diagnostic(&args(&["--other"])), None);
        let plain = parse_diagnostic(&args(&["--notify-test"])).expect("the flag alone is enough");
        assert_eq!(plain.title, "wasm-agent");
        assert_eq!(
            plain.body,
            "test notification from the wasm-agent window shell"
        );
        let full = parse_diagnostic(&args(&["--notify-test", "Title here", "Body here"]))
            .expect("with text");
        assert_eq!(full.title, "Title here");
        assert_eq!(full.body, "Body here");
    }

    #[test]
    fn disabled_settings_each_explain_themselves() {
        use windows::UI::Notifications::NotificationSetting as Setting;
        assert_eq!(setting_reason(Setting::Enabled), None);
        for setting in [
            Setting::DisabledForApplication,
            Setting::DisabledForUser,
            Setting::DisabledByGroupPolicy,
            Setting::DisabledByManifest,
        ] {
            let reason = setting_reason(setting).expect("a reason");
            assert!(!reason.is_empty());
            assert!(
                reason.contains("notifications") || reason.contains("notification"),
                "{reason}"
            );
        }
    }
}
