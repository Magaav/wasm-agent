//! wasm-agent desktop window (Windows / WebView2).
//!
//! A borderless, translucent, always-on-top companion that collapses to a round
//! avatar and expands into the chat panel. It loads the same `wa serve` UI over
//! the SSH tunnel, so the UI still hot-reloads while it runs.
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

#[cfg(target_os = "windows")]
mod client;

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("wa-window is a Windows companion; run `wa ui` on Windows.");
}

#[cfg(target_os = "windows")]
mod companion {
    use anyhow::{Context, Result};
    use serde::Deserialize;
    use std::path::PathBuf;
    use std::time::{Duration, Instant};
    use tao::platform::windows::{WindowBuilderExtWindows, WindowExtWindows};
    use tao::{
        dpi::{LogicalPosition, LogicalSize, PhysicalPosition, PhysicalSize},
        event::{Event, StartCause, WindowEvent},
        event_loop::{ControlFlow, EventLoopBuilder},
        window::{Window, WindowBuilder},
    };
    use wry::{PageLoadEvent, WebContext, WebView, WebViewBuilder, WebViewBuilderExtWindows};

    const COMPACT: u32 = 88;
    const PANEL_WIDTH: u32 = 430;
    const PANEL_HEIGHT: u32 = 640;
    const TOPMOST_INTERVAL: Duration = Duration::from_millis(750);
    const DEFAULT_URL: &str = "http://127.0.0.1:8799/";

    #[derive(Debug)]
    enum UserEvent {
        /// An IPC message, tagged with the window that sent it: operations act on the window that
        /// asked, not on the main one. A second window whose "maximize" resized the chat would be
        /// worse than no second window.
        Ipc(usize, String),
        Loaded,
    }

    #[derive(Debug, Default, Deserialize)]
    struct IpcRequest {
        #[serde(default)]
        operation: String,
        #[serde(default)]
        mode: String,
        #[serde(default)]
        panel_width: u32,
        #[serde(default)]
        panel_height: u32,
        #[serde(default)]
        enabled: Option<bool>,
        /// Which view to open (`open_view`), and where to load it from.
        #[serde(default)]
        view: String,
        #[serde(default)]
        url: String,
    }

    /// A view window: a real OS window, decorated and resizable, deliberately *not* always on top.
    /// The chat is the thing that floats above; this is the screen being worked in.
    struct View {
        id: usize,
        window: Window,
        _webview: WebView,
    }

    struct State {
        mode: String,
        topmost: bool,
        next_topmost: Instant,
        views: Vec<View>,
    }

    /// Give the window (taskbar, alt-tab) the embedded wasm-agent icon.
    fn set_window_icon(window: &Window) {
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
        use windows::Win32::System::LibraryLoader::GetModuleHandleW;
        use windows::Win32::UI::WindowsAndMessaging::{
            LoadIconW, SendMessageW, ICON_BIG, ICON_SMALL, WM_SETICON,
        };
        let hwnd = HWND(window.hwnd() as _);
        unsafe {
            let Ok(module) = GetModuleHandleW(None) else { return };
            let Ok(icon) = LoadIconW(Some(module.into()), PCWSTR(1 as *const u16)) else { return };
            SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(icon.0 as isize)));
            SendMessageW(hwnd, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(icon.0 as isize)));
        }
    }

    fn data_dir() -> PathBuf {
        let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
        let dir = PathBuf::from(base).join("wasm-agent").join("WebView2");
        let _ = std::fs::create_dir_all(&dir);
        dir
    }

    fn log_path() -> PathBuf {
        let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
        PathBuf::from(base).join("wasm-agent").join("wa-window.log")
    }

    /// Append a line to `%LOCALAPPDATA%\wasm-agent\wa-window.log` (a GUI process
    /// has no console, so errors are written here).
    pub fn note(message: &str) {
        use std::io::Write;
        let path = log_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(file, "{message}");
        }
    }

    fn bridge_script() -> &'static str {
        r#"
(() => {
  const send = (operation, value = {}) => window.ipc.postMessage(JSON.stringify({ operation, ...value }));
  Object.defineProperty(window, 'wasmAgent', { configurable: false, value: {
    native: true,
    platform: 'windows',
    runtime: 'webview2',
    setMode: (mode, width, height) => send('set_mode', { mode, panel_width: width || 0, panel_height: height || 0 }),
    compact: () => send('set_mode', { mode: 'compact' }),
    expand: () => send('set_mode', { mode: 'expanded' }),
    maximize: () => send('set_mode', { mode: 'maximized' }),
    drag: () => send('drag'),
    topmost: (enabled) => send('topmost', { enabled: enabled !== false }),
    // A view in its own window: the chat stays the chat, and this is a screen you work in. The URL
    // is built by the page, because the page is what knows where it was loaded from.
    openView: (view, url) => send('open_view', { view: String(view || 'view'), url: String(url || '') }),
    closeView: () => send('close_view'),
    quit: () => send('quit')
  }});
})();
"#
    }

    /// Work area (screen minus taskbar) of the monitor the window is nearest to.
    fn monitor_work_area(window: &Window) -> Option<(i32, i32, i32, i32)> {
        use windows::Win32::Foundation::{HWND, RECT};
        use windows::Win32::Graphics::Gdi::{
            GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
        };
        let hwnd = HWND(window.hwnd() as _);
        unsafe {
            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                rcMonitor: RECT::default(),
                rcWork: RECT::default(),
                dwFlags: 0,
            };
            if GetMonitorInfoW(monitor, &mut info).as_bool() {
                Some((info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom))
            } else {
                None
            }
        }
    }

    /// Keep the whole window inside the work area so it can never be dragged or
    /// grown off-screen.
    fn clamp_to_work_area(window: &Window) {
        let Some((left, top, right, bottom)) = monitor_work_area(window) else { return };
        let size = window.outer_size();
        let position = window.outer_position().unwrap_or_default();
        let (w, h) = (size.width as i32, size.height as i32);
        let (max_x, max_y) = ((right - w).max(left), (bottom - h).max(top));
        let (x, y) = (position.x.clamp(left, max_x), position.y.clamp(top, max_y));
        if x != position.x || y != position.y {
            window.set_outer_position(PhysicalPosition::new(x, y));
        }
    }

    fn resize(window: &Window, mode: &str, width: u32, height: u32) {
        let old_size = window.outer_size();
        let old_position = window.outer_position().unwrap_or_default();
        if mode == "maximized" {
            // The whole work area, pinned to its corner: "fill the screen" is a rectangle, and
            // the page cannot ask for more than the window it is in.
            if let Some((left, top, right, bottom)) = monitor_work_area(window) {
                window.set_resizable(false);
                window.set_inner_size(PhysicalSize::new(
                    (right - left).max(1) as u32,
                    (bottom - top).max(1) as u32,
                ));
                window.set_outer_position(PhysicalPosition::new(left, top));
                window.set_focusable(true);
                window.set_focus();
                return;
            }
        }
        let logical = if mode == "expanded" {
            LogicalSize::new(width.clamp(320, 900) as f64, height.clamp(420, 1200) as f64)
        } else {
            LogicalSize::new(COMPACT as f64, COMPACT as f64)
        };
        // Fixed-size: a sizing frame would inset the client area and leave a
        // visible border around the frameless translucent window.
        window.set_resizable(false);
        let mut physical: PhysicalSize<u32> = logical.to_physical(window.scale_factor());
        // Never grow past the monitor work area.
        if let Some((left, top, right, bottom)) = monitor_work_area(window) {
            physical.width = physical.width.min((right - left).max(1) as u32);
            physical.height = physical.height.min((bottom - top).max(1) as u32);
        }
        window.set_inner_size(physical);
        let observed = window.outer_size();
        let mut target = PhysicalPosition::new(
            old_position.x + old_size.width as i32 - observed.width as i32,
            old_position.y + old_size.height as i32 - observed.height as i32,
        );
        // Clamp the computed target: reading the position back after
        // `set_outer_position` can race, so never trust it here.
        if let Some((left, top, right, bottom)) = monitor_work_area(window) {
            let max_x = (right - observed.width as i32).max(left);
            let max_y = (bottom - observed.height as i32).max(top);
            target.x = target.x.clamp(left, max_x);
            target.y = target.y.clamp(top, max_y);
        }
        window.set_outer_position(target);
        window.set_focusable(mode != "compact");
        if mode != "compact" {
            window.set_focus();
        }
    }

    /// Style the window for its current mode: topmost, slightly translucent
    /// (`WS_EX_LAYERED` + `LWA_ALPHA`, which works even without per-pixel DWM
    /// transparency), and clipped to a circle when compact or a rounded rect
    /// when expanded so the frameless window has no square corners.
    /// Alpha, topmost z-order and the initial show. Called once after the
    /// window is made visible.
    fn apply_style(window: &Window) {
        use windows::Win32::Foundation::{COLORREF, HWND};
        use windows::Win32::UI::WindowsAndMessaging::{
            GetWindowLongPtrW, SetLayeredWindowAttributes, SetWindowLongPtrW, SetWindowPos,
            GWL_EXSTYLE, HWND_TOPMOST, LWA_ALPHA, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
            SWP_SHOWWINDOW, WS_EX_LAYERED,
        };
        let hwnd = HWND(window.hwnd() as _);
        unsafe {
            let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED.0 as isize);
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 246, LWA_ALPHA);
            let _ = SetWindowPos(
                hwnd,
                Some(HWND_TOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
        }
    }

    /// Keep the WebView bounds and the window region in step with the client
    /// area. Runs on every mode change and on every manual resize.
    fn apply_layout(window: &Window, webview: &WebView, mode: &str) {
        use windows::Win32::Foundation::{HWND, RECT};
        use windows::Win32::Graphics::Gdi::{CreateEllipticRgn, CreateRoundRectRgn, SetWindowRgn};
        use windows::Win32::UI::WindowsAndMessaging::GetClientRect;
        let hwnd = HWND(window.hwnd() as _);
        let scale = window.scale_factor();
        unsafe {
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            let (w, h) = (rc.right.max(1), rc.bottom.max(1));
            // The WebView keeps the size it was created with until told
            // otherwise, so pin it to the client area on every relayout.
            let _ = webview.set_bounds(wry::Rect {
                position: LogicalPosition::new(0.0, 0.0).into(),
                size: LogicalSize::new(w as f64 / scale, h as f64 / scale).into(),
            });
            let region = if mode == "maximized" {
                // A full rectangle: rounding is for a floating panel, and this is not one.
                None
            } else if mode == "expanded" {
                // Match the panel's CSS `border-radius: 18px` in physical pixels.
                let r = (36.0 * scale).round().max(8.0) as i32;
                Some(CreateRoundRectRgn(0, 0, w + 1, h + 1, r, r))
            } else {
                // A centred circle of the smaller dimension, so the avatar stays
                // round even if the client area is not exactly square.
                let d = w.min(h);
                let (cx, cy) = (w / 2, h / 2);
                Some(CreateEllipticRgn(cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2))
            };
            SetWindowRgn(hwnd, region, true);
        }
    }

    fn style_window(window: &Window, webview: &WebView, mode: &str) {
        apply_style(window);
        apply_layout(window, webview, mode);
    }

    fn handle(main: &Window, main_webview: &WebView, state: &mut State, sender: usize,
              body: &str, target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
              proxy: &tao::event_loop::EventLoopProxy<UserEvent>) -> bool {
        let request: IpcRequest = serde_json::from_str(body).unwrap_or_default();
        let from_main = sender == encode_id(main.id());
        match request.operation.as_str() {
            // A view in its own window. Decorated, resizable, movable and *not* always on top -
            // the chat is the thing that floats above; a control view is a screen you work in. It
            // is a normal window on purpose: the operating system already knows how to move,
            // resize, maximise, snap and Alt-Tab it, and re-implementing that would only be worse.
            "open_view" if from_main => {
                let view = if request.view.is_empty() { "view".to_string() } else { request.view.clone() };
                if state.views.iter().any(|open| open.window.title() == view) {
                    note(&format!("view {view} is already open"));
                    return false;
                }
                let url = if request.url.is_empty() {
                    let separator = if DEFAULT_URL.contains('?') { '&' } else { '?' };
                    format!("{DEFAULT_URL}{separator}view={view}")
                } else {
                    request.url.clone()
                };
                match open_view(target, proxy, &view, &url) {
                    Ok((window, window_id, webview)) => {
                        note(&format!("view {view} opened: {url}"));
                        state.views.push(View { id: window_id, window, _webview: webview });
                    }
                    Err(error) => note(&format!("view {view} failed: {error:#}")),
                }
            }
            "close_view" => {
                let before = state.views.len();
                state.views.retain(|view| view.id != sender);
                note(&format!("view closed by its page ({} of {before} left)", state.views.len()));
            }
            "set_mode" if from_main => {
                state.mode = match request.mode.as_str() {
                    "expanded" => "expanded",
                    // The control view asks for this: a remote desktop wants the screen, and the
                    // panel is sized for conversations.
                    "maximized" => "maximized",
                    _ => "compact",
                }
                .into();
                resize(main, &state.mode, request.panel_width.max(PANEL_WIDTH),
                       request.panel_height.max(PANEL_HEIGHT));
                style_window(main, main_webview, &state.mode);
            }
            "drag" if from_main => {
                let _ = main.drag_window();
                clamp_to_work_area(main);
            }
            "topmost" if from_main => {
                state.topmost = request.enabled.unwrap_or(true);
                main.set_always_on_top(state.topmost);
            }
            "quit" => {
                note("quit requested by page");
                let _ = main_webview;
                return true;
            }
            _ => {}
        }
        false
    }

    /// Open a view as its own window, with its own webview. Each gets its own WebView2 profile
    /// directory: two controllers sharing one profile is a fight over a cache for no benefit.
    fn open_view(target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
                 proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
                 title: &str, url: &str) -> Result<(Window, usize, WebView)> {
        let window = WindowBuilder::new()
            .with_title(format!("wasm-agent {title}"))
            .with_inner_size(PhysicalSize::new(900, 620))
            .with_min_inner_size(PhysicalSize::new(360, 260))
            .with_decorations(true)
            .with_resizable(true)
            .with_always_on_top(false)
            .with_visible(true)
            .with_skip_taskbar(false)
            .with_focusable(true)
            .build(target)
            .context("create view window")?;
        let profile = data_dir().join("views").join(title.replace([':', '/', '\\'], "-"));
        let _ = std::fs::create_dir_all(&profile);
        let mut context = WebContext::new(Some(profile));
        let proxy = proxy.clone();
        let id = encode_id(window.id());
        let webview = WebViewBuilder::new_with_web_context(&mut context)
            .with_url(url)
            .with_default_context_menus(true)
            .with_initialization_script(bridge_script())
            .with_ipc_handler(move |request| {
                // Tagged with the sending window, so an operation acts on the window that asked.
                let _ = proxy.send_event(UserEvent::Ipc(id, request.body().clone()));
            })
            .build(&window)
            .context("create view webview")?;
        Ok((window, id, webview))
    }

    /// `WindowId` is opaque; its debug form is stable enough to carry through an event and compare
    /// back, which is all this needs - the alternative is a map keyed by the id type itself.
    fn encode_id(id: tao::window::WindowId) -> usize {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        format!("{id:?}").hash(&mut hasher);
        hasher.finish() as usize
    }

    /// Declare per-monitor DPI awareness before any window exists, so tao's
    /// logical/physical conversions match the operating system on scaled displays.
    fn become_dpi_aware() {
        use windows::Win32::UI::HiDpi::{
            SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        unsafe {
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
    }

    pub fn run() -> Result<()> {
        become_dpi_aware();
        std::panic::set_hook(Box::new(|info| note(&format!("panic: {info}"))));
        let url = std::env::var("WASM_AGENT_UI_URL").unwrap_or_else(|_| DEFAULT_URL.to_string());
        note(&format!("start url={url}"));
        // Background executor for client tools (screenshot/input/CDP).
        crate::client::spawn();
        let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
        let window = WindowBuilder::new()
            .with_title("wasm-agent")
            .with_inner_size(PhysicalSize::new(COMPACT, COMPACT))
            .with_decorations(false)
            .with_transparent(false)
            .with_always_on_top(true)
            .with_visible(false)
            .with_skip_taskbar(false)
            .with_focusable(false)
            .with_resizable(false)
            // No DWM drop shadow: it draws a soft border around the frameless
            // translucent window that reads as stray edges.
            .with_undecorated_shadow(false)
            .build(&event_loop)
            .context("create companion window")?;
        set_window_icon(&window);
        note("window created");
        // Size the window before the WebView is created so its initial bounds
        // are correct (wry does not resize the controller on its own).
        resize(&window, "compact", PANEL_WIDTH, PANEL_HEIGHT);
        let ipc_proxy = event_loop.create_proxy();
        let load_proxy = event_loop.create_proxy();
        let mut web_context = WebContext::new(Some(data_dir()));
        // The main window's identity, so the loop can tell which window an event or an IPC came
        // from - a view's "close" must close the view, not the chat.
        let main_id = encode_id(window.id());
        let webview = WebViewBuilder::new_with_web_context(&mut web_context)
            .with_url(&url)
            .with_transparent(false)
            // We draw our own right-click menu in the page.
            .with_default_context_menus(false)
            .with_initialization_script(bridge_script())
            .with_ipc_handler(move |request| {
                let _ = ipc_proxy.send_event(UserEvent::Ipc(main_id, request.body().clone()));
            })
            .with_on_page_load_handler(move |event, _url| {
                if matches!(event, PageLoadEvent::Finished) {
                    let _ = load_proxy.send_event(UserEvent::Loaded);
                }
            })
            .build(&window)
            .context("create WebView2 companion")?;
        note(&format!("webview created for {url} inner={:?}", window.inner_size()));
        // Force the WebView controller to size itself to the window (otherwise it
        // can stay at zero bounds and never paint).
        resize(&window, "compact", PANEL_WIDTH, PANEL_HEIGHT);

        if let Some(monitor) = window.current_monitor() {
            let size = monitor.size();
            let origin = monitor.position();
            let compact = window.outer_size();
            window.set_outer_position(PhysicalPosition::new(
                origin.x + size.width as i32 - compact.width as i32 - 16,
                origin.y + size.height as i32 - compact.height as i32 - 56,
            ));
        }
        clamp_to_work_area(&window);
        window.set_visible(true);
        resize(&window, "compact", PANEL_WIDTH, PANEL_HEIGHT);
        style_window(&window, &webview, "compact");
        note(&format!("window visible inner={:?}", window.inner_size()));

        let mut state = State {
            mode: "compact".into(),
            topmost: true,
            next_topmost: Instant::now() + TOPMOST_INTERVAL,
            views: Vec::new(),
        };
        let view_proxy = event_loop.create_proxy();
        event_loop.run(move |event, target, control_flow| {
            *control_flow = ControlFlow::WaitUntil(state.next_topmost);
            match event {
                Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                    if state.topmost {
                        window.set_always_on_top(true);
                    }
                    state.next_topmost = Instant::now() + TOPMOST_INTERVAL;
                }
                Event::UserEvent(UserEvent::Ipc(sender, body)) => {
                    if handle(&window, &webview, &mut state, sender, &body, target, &view_proxy) {
                        window.set_visible(false);
                        *control_flow = ControlFlow::Exit;
                    }
                }
                Event::UserEvent(UserEvent::Loaded) => note("page loaded"),
                Event::WindowEvent { window_id, event: WindowEvent::Resized(_), .. } => {
                    // Manual resize: re-pin the WebView and re-cut the region. Only the main window
                    // is hand-styled; a view is an ordinary window and the OS sizes it.
                    if encode_id(window_id) == main_id {
                        apply_layout(&window, &webview, &state.mode);
                    }
                }
                Event::WindowEvent { window_id, event: WindowEvent::CloseRequested, .. } => {
                    if encode_id(window_id) == main_id {
                        // Closing the chat closes what the chat opened: a view is a thing the chat
                        // asked for, and leaving it behind would be a window nobody can explain.
                        note(&format!("close requested; closing {} view(s)", state.views.len()));
                        state.views.clear();
                        window.set_visible(false);
                        *control_flow = ControlFlow::Exit;
                    } else {
                        state.views.retain(|view| view.id != encode_id(window_id));
                        note("view closed");
                    }
                }
                Event::WindowEvent { window_id, event: WindowEvent::Destroyed, .. } => {
                    state.views.retain(|view| view.id != encode_id(window_id));
                }
                Event::LoopDestroyed => note("loop destroyed"),
                _ => {}
            }
        });
    }
}

#[cfg(target_os = "windows")]
fn main() {
    if let Err(error) = companion::run() {
        companion::note(&format!("fatal: {error:#}"));
        std::process::exit(1);
    }
}
