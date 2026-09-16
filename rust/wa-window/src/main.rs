//! wasm-agent desktop window (Windows / WebView2).
//!
//! A borderless, translucent, always-on-top companion that collapses to a round
//! avatar and expands into the chat panel. It loads the same `wa serve` UI over
//! the SSH tunnel, so the UI still hot-reloads while it runs.
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

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
    use wry::{PageLoadEvent, WebContext, WebView, WebViewBuilder};

    const COMPACT: u32 = 88;
    const PANEL_WIDTH: u32 = 430;
    const PANEL_HEIGHT: u32 = 640;
    const TOPMOST_INTERVAL: Duration = Duration::from_millis(750);
    const DEFAULT_URL: &str = "http://127.0.0.1:8799/";

    #[derive(Debug)]
    enum UserEvent {
        Ipc(String),
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
    }

    struct State {
        mode: String,
        topmost: bool,
        next_topmost: Instant,
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
    drag: () => send('drag'),
    topmost: (enabled) => send('topmost', { enabled: enabled !== false }),
    quit: () => send('quit')
  }});
})();
"#
    }

    fn resize(window: &Window, mode: &str, width: u32, height: u32) {
        let old_size = window.outer_size();
        let old_position = window.outer_position().unwrap_or_default();
        let logical = if mode == "expanded" {
            LogicalSize::new(width.clamp(320, 900) as f64, height.clamp(420, 1200) as f64)
        } else {
            LogicalSize::new(COMPACT as f64, COMPACT as f64)
        };
        // Fixed-size: a sizing frame would inset the client area and leave a
        // visible border around the frameless translucent window.
        window.set_resizable(false);
        let physical: PhysicalSize<u32> = logical.to_physical(window.scale_factor());
        window.set_inner_size(physical);
        let observed = window.outer_size();
        window.set_outer_position(PhysicalPosition::new(
            old_position.x + old_size.width as i32 - observed.width as i32,
            old_position.y + old_size.height as i32 - observed.height as i32,
        ));
        window.set_focusable(mode == "expanded");
        if mode == "expanded" {
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
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 238, LWA_ALPHA);
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
            let region = if mode == "expanded" {
                // Match the panel's CSS `border-radius: 18px` in physical pixels.
                let r = (36.0 * scale).round().max(8.0) as i32;
                CreateRoundRectRgn(0, 0, w + 1, h + 1, r, r)
            } else {
                // A centred circle of the smaller dimension, so the avatar stays
                // round even if the client area is not exactly square.
                let d = w.min(h);
                let (cx, cy) = (w / 2, h / 2);
                CreateEllipticRgn(cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2)
            };
            SetWindowRgn(hwnd, Some(region), true);
        }
    }

    fn style_window(window: &Window, webview: &WebView, mode: &str) {
        apply_style(window);
        apply_layout(window, webview, mode);
    }

    fn handle(window: &Window, webview: &WebView, state: &mut State, body: &str) -> bool {
        let request: IpcRequest = serde_json::from_str(body).unwrap_or_default();
        match request.operation.as_str() {
            "set_mode" => {
                state.mode = if request.mode == "expanded" { "expanded" } else { "compact" }.into();
                resize(window, &state.mode, request.panel_width.max(PANEL_WIDTH),
                       request.panel_height.max(PANEL_HEIGHT));
                style_window(window, webview, &state.mode);
            }
            "drag" => {
                let _ = window.drag_window();
            }
            "topmost" => {
                state.topmost = request.enabled.unwrap_or(true);
                window.set_always_on_top(state.topmost);
            }
            "quit" => {
                note("quit requested by page");
                let _ = webview;
                return true;
            }
            _ => {}
        }
        false
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
        let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
        let window = WindowBuilder::new()
            .with_title("wasm-agent")
            .with_inner_size(PhysicalSize::new(COMPACT, COMPACT))
            .with_decorations(false)
            .with_transparent(false)
            .with_always_on_top(true)
            .with_visible(false)
            .with_skip_taskbar(true)
            .with_focusable(false)
            .with_resizable(false)
            // No DWM drop shadow: it draws a soft border around the frameless
            // translucent window that reads as stray edges.
            .with_undecorated_shadow(false)
            .build(&event_loop)
            .context("create companion window")?;
        note("window created");
        // Size the window before the WebView is created so its initial bounds
        // are correct (wry does not resize the controller on its own).
        resize(&window, "compact", PANEL_WIDTH, PANEL_HEIGHT);
        let ipc_proxy = event_loop.create_proxy();
        let load_proxy = event_loop.create_proxy();
        let mut web_context = WebContext::new(Some(data_dir()));
        let webview = WebViewBuilder::new_with_web_context(&mut web_context)
            .with_url(&url)
            .with_transparent(false)
            .with_initialization_script(bridge_script())
            .with_ipc_handler(move |request| {
                let _ = ipc_proxy.send_event(UserEvent::Ipc(request.body().clone()));
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
        window.set_visible(true);
        resize(&window, "compact", PANEL_WIDTH, PANEL_HEIGHT);
        style_window(&window, &webview, "compact");
        note(&format!("window visible inner={:?}", window.inner_size()));

        let mut state = State {
            mode: "compact".into(),
            topmost: true,
            next_topmost: Instant::now() + TOPMOST_INTERVAL,
        };
        event_loop.run(move |event, _, control_flow| {
            *control_flow = ControlFlow::WaitUntil(state.next_topmost);
            match event {
                Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                    if state.topmost {
                        window.set_always_on_top(true);
                    }
                    state.next_topmost = Instant::now() + TOPMOST_INTERVAL;
                }
                Event::UserEvent(UserEvent::Ipc(body)) => {
                    if handle(&window, &webview, &mut state, &body) {
                        window.set_visible(false);
                        *control_flow = ControlFlow::Exit;
                    }
                }
                Event::UserEvent(UserEvent::Loaded) => note("page loaded"),
                Event::WindowEvent { event: WindowEvent::Resized(_), .. } => {
                    // Manual resize: re-pin the WebView and re-cut the region.
                    apply_layout(&window, &webview, &state.mode);
                }
                Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                    note("close requested");
                    window.set_visible(false);
                    *control_flow = ControlFlow::Exit;
                }
                Event::WindowEvent { event: WindowEvent::Destroyed, .. } => note("window destroyed"),
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
