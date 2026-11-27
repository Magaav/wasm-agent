//! Giving the terminal back: the bytes that leave the fullscreen screen, and the panic hook that
//! writes them before a message is printed.
//!
//! MOVED OUT OF `wa-term` in the last slice of `wa-term-own-program`: owning the terminal is this
//! process's job (its own `crate::tty` writes every frame, and these are the two moments it must hand
//! it back), and the drawing crate need not be linked for it.
use std::sync::{Arc, Mutex};

/// How this process took the screen: the whole terminal (the console), or its own rows only.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode { Fullscreen, Inline }

type Hook = Box<dyn Fn(&std::panic::PanicHookInfo<'_>) + Sync + Send + 'static>;

pub fn leave_bytes(mode: Mode) -> String {
    if mode == Mode::Inline { return String::new(); }
    format!("{}\x1b[?2004l\x1b[?25h\x1b[0m\x1b[?1049l", crate::selection::DISABLE)
}

pub fn enter_bytes(mode: Mode) -> String {
    if mode == Mode::Inline { return String::new(); }
    format!("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l{}", crate::selection::ENABLE)
}

pub struct PanicRestore { slot: Arc<Mutex<Option<Hook>>> }

impl PanicRestore {
    pub fn restore(self) {
        if let Some(previous) = self.slot.lock().ok().and_then(|mut slot| slot.take()) {
            std::panic::set_hook(previous);
        }
    }
}

pub fn install_panic_restore_with(mode: Mode, sink: impl FnMut(&str) + Send + 'static) -> PanicRestore {
    let slot: Arc<Mutex<Option<Hook>>> = Arc::new(Mutex::new(Some(std::panic::take_hook())));
    let kept = slot.clone();
    let sink = Mutex::new(sink);
    let restore = leave_bytes(mode);
    std::panic::set_hook(Box::new(move |info| {
        if let Ok(mut sink) = sink.lock() { sink(&restore); }
        // The previous hook prints the message; it must see the restored screen.
        if let Ok(slot) = kept.lock() {
            if let Some(previous) = slot.as_ref() { previous(info); }
        }
    }));
    PanicRestore { slot }
}
