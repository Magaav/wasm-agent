//! `wa:terminal@0.1.0`: the DOCUMENT the node paints, granted to components from here - the same home as
//! `vision_host.rs`, `bus_host.rs`, `queue_host.rs` and every other world the linker serves.
//!
//! The world has no resources (the PTY shape was dropped on 28/11 when the program turned out to answer a
//! document), so every verb is a plain interface function and the traits implement on `State` directly.
//!
//! The provider is injected: `install` hands this module the node's own client (`screen::document`, which creates it
//! on a worker thread because that client is thread-local). wa-kernel-runtime cannot reach that client itself - the
//! dependency runs capabilities -> kernel-runtime - so the node supplies it, as it supplies the policy and the facts.

use std::future;
use std::sync::{Mutex, OnceLock};
use wasmtime::component::Accessor;

use crate::service_components_v2::State;

wasmtime::component::bindgen!({
    world: "terminal-client",
    path: "../../wit/terminal",
});

use wa::terminal::types::Error as Fault;

/// Where the document comes from: the node backs this with the terminal program, a test with a script.
pub trait Document: Send {
    fn write(&mut self, text: &str) -> Result<(), Fault>;
    fn block(&mut self, open: bool) -> Result<(), Fault>;
    fn code_block(&mut self) -> Result<(), Fault>;
    fn head(&mut self, text: &str) -> Result<u32, Fault>;
    fn rewrite(&mut self, line: u32, text: &str) -> Result<u32, Fault>;
    fn pin_toggle(&mut self) -> Result<Option<bool>, Fault>;
    fn dirty(&mut self) -> bool;
}

#[cfg(test)]
mod rows {
    use super::*;

    #[derive(Default)]
    struct Script {
        lines: Vec<String>,
        pinned: Option<bool>,
        dirty: bool,
    }

    impl Document for Script {
        fn write(&mut self, text: &str) -> Result<(), Fault> {
            self.lines.push(text.to_string());
            self.dirty = true;
            Ok(())
        }

        fn block(&mut self, _open: bool) -> Result<(), Fault> {
            Ok(())
        }

        fn code_block(&mut self) -> Result<(), Fault> {
            Ok(())
        }

        fn head(&mut self, text: &str) -> Result<u32, Fault> {
            self.lines.push(text.to_string());
            Ok(self.lines.len() as u32)
        }

        fn rewrite(&mut self, line: u32, text: &str) -> Result<u32, Fault> {
            if line == 0 || line as usize > self.lines.len() {
                return Err(Fault::Refused("no such line".to_string()));
            }
            self.lines[line as usize - 1] = text.to_string();
            Ok(line)
        }

        fn pin_toggle(&mut self) -> Result<Option<bool>, Fault> {
            Ok(self.pinned)
        }

        fn dirty(&mut self) -> bool {
            self.dirty
        }
    }


    /// ROW: the adapter speaks the program's OWN method names over the wire - `write`, `block`, `head`,
    /// `pin_toggle` - because those are what `rust/wa-term/src/session.rs` answers. A recorder stands in for the
    /// program, so the mapping is asserted without one.
    #[test]
    fn the_adapter_speaks_the_programs_method_names() {
        use std::sync::{Arc, Mutex};

        let seen: Arc<Mutex<Vec<(String, serde_json::Value)>>> = Arc::new(Mutex::new(Vec::new()));
        let record = seen.clone();
        let mut document = ProtoDocument::new(Box::new(move |method, args| {
            record.lock().unwrap().push((method.to_string(), args));
            Ok(serde_json::json!(3))
        }));

        document.write("hello").unwrap();
        document.block(true).unwrap();
        assert_eq!(document.head("title").unwrap(), 3);
        assert_eq!(document.rewrite(2, "new").unwrap(), 3);
        document.pin_toggle().unwrap();

        let calls = seen.lock().unwrap();
        let names: Vec<&str> = calls.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, vec!["write", "block", "head", "rewrite", "pin_toggle"]);
        assert_eq!(calls[0].1, serde_json::json!(["hello"]));
        assert_eq!(calls[3].1, serde_json::json!([2, "new"]));

        // The dirty flag follows the writes and is cleared by asking.
        assert!(document.dirty());
        assert!(!document.dirty());
    }


    /// ROW: the channel keeps ONE owner of the wire. The client is created on the worker thread (never on the
    /// caller's), calls cross the channel, and a document built that way answers like any other. This is the shape
    /// the node will use, because `screen.rs`'s client cannot be `Send`.
    #[test]
    fn a_channel_document_keeps_the_wire_on_one_thread() {
        use std::sync::{Arc, Mutex};

        let caller_thread = std::thread::current().id();
        let worker_thread: Arc<Mutex<Option<std::thread::ThreadId>>> = Arc::new(Mutex::new(None));
        let recorded = Arc::new(Mutex::new(Vec::<String>::new()));

        let seen = worker_thread.clone();
        let log = recorded.clone();
        let mut document = channel_document(move || {
            *seen.lock().unwrap() = Some(std::thread::current().id());
            Box::new(move |method, _args| {
                log.lock().unwrap().push(method.to_string());
                Ok(serde_json::json!(7))
            })
        });

        document.write("hello").unwrap();
        assert_eq!(document.head("title").unwrap(), 7);

        let worker = worker_thread.lock().unwrap().expect("the worker must have started");
        assert_ne!(worker, caller_thread, "the client must be created on the worker thread, not the caller's");
        assert_eq!(*recorded.lock().unwrap(), vec!["write", "head"]);
    }


    /// ROW: the world is GRANTED by the runner - `link` puts the document interface on a service linker, and a
    /// second call on the same linker is an error rather than a silent duplicate.
    ///
    /// The fixture-instantiation row that used to sit here lived in wa-capabilities, where the store was a small
    /// `Host`. Here the store is `State`, which the runner owns, so this row asserts the GRANT itself; the guest
    /// row stays where a State can be built.
    #[test]
    fn the_runner_grants_the_document_interface() {
        let engine = wasmtime::Engine::default();
        let mut linker = wasmtime::component::Linker::<State>::new(&engine);
        link(&mut linker).expect("the document interface must link");
        // A second grant of the same interface is an error, which proves the first one landed.
        assert!(link(&mut linker).is_err(), "the same interface must not be granted twice");
    }


    /// ROW: a node that installed no document says so BY NAME, rather than behaving like an empty terminal. The code
    /// `terminal_document_absent` is what an operator greps for, so a row pins it - the refusal is the contract, not
    /// the absence.
    #[test]
    fn a_missing_document_is_refused_by_name() {
        match missing() {
            Fault::Refused(reason) => assert!(
                reason.starts_with("terminal_document_absent"),
                "the refusal must lead with its code, got: {reason}"
            ),
            other => panic!("a missing document must be a refusal, got {other:?}"),
        }
        // And the lookup really is empty when nothing installed one: this row runs before any install in this binary.
        assert!(with_document(|document| document.dirty()).is_none(), "no document must be installed in this test binary");
    }

    /// ROW: the document seam answers in the program's own terms - a heading lands where the program says it did,
    /// a rewrite of a line that does not exist is a refusal rather than a silent nothing, and `dirty` follows the
    /// writes. This is the shape `wa-term-proto` carries, tested without the program.
    #[test]
    fn document_verbs_answer_in_the_programs_terms() {
        let mut document = Script::default();
        assert_eq!(document.head("one").unwrap(), 1);
        assert_eq!(document.head("two").unwrap(), 2);
        document.write("three").unwrap();
        assert!(document.dirty());
        assert_eq!(document.rewrite(2, "second").unwrap(), 2);
        match document.rewrite(9, "nowhere") {
            Err(Fault::Refused(_)) => {}
            other => panic!("rewriting a missing line must be refused, got {other:?}"),
        }
        assert_eq!(document.pin_toggle().unwrap(), None);
    }
}

/// The document this node paints through, installed once at startup.
///
/// A `Mutex` because the trait's sync verb (`dirty`) needs `&mut` while the async ones need the same one document;
/// the guard is never held across an await, so no task is parked on it.
static DOCUMENT: OnceLock<Mutex<Box<dyn Document>>> = OnceLock::new();

/// Hand the node's own client to the world. Called once; a second call keeps the first (one owner).
pub fn install(document: Box<dyn Document>) {
    let _ = DOCUMENT.set(Mutex::new(document));
}

fn with_document<R>(f: impl FnOnce(&mut dyn Document) -> R) -> Option<R> {
    let locked = DOCUMENT.get()?;
    let mut guard = locked.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    Some(f(guard.as_mut()))
}

/// `dirty` is the only sync verb.
impl wa::terminal::document::Host for State {
    fn dirty(&mut self) -> bool {
        with_document(|document| document.dirty()).unwrap_or(false)
    }
}

impl wa::terminal::types::Host for State {}

impl wa::terminal::document::HostWithStore<State> for State {
    fn write<'a>(
        _access: &'a Accessor<State, State>,
        text: String,
    ) -> impl std::future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { with_document(|document| document.write(&text)).ok_or_else(missing)? }
    }

    fn block<'a>(
        _access: &'a Accessor<State, State>,
        open: bool,
    ) -> impl std::future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { with_document(|document| document.block(open)).ok_or_else(missing)? }
    }

    fn code_block<'a>(
        _access: &'a Accessor<State, State>,
    ) -> impl std::future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { with_document(|document| document.code_block()).ok_or_else(missing)? }
    }

    fn head<'a>(
        _access: &'a Accessor<State, State>,
        text: String,
    ) -> impl std::future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { with_document(|document| document.head(&text)).ok_or_else(missing)? }
    }

    fn rewrite<'a>(
        _access: &'a Accessor<State, State>,
        line: u32,
        text: String,
    ) -> impl std::future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { with_document(|document| document.rewrite(line, &text)).ok_or_else(missing)? }
    }

    fn pin_toggle<'a>(
        _access: &'a Accessor<State, State>,
    ) -> impl std::future::Future<Output = Result<Option<bool>, Fault>> + Send + 'a {
        async move { with_document(|document| document.pin_toggle()).ok_or_else(missing)? }
    }
}

/// Link the document interface into a service linker, beside vision and the rest.
pub fn link(linker: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    wa::terminal::document::add_to_linker::<State, State>(linker, |state| state)
}

/// The document, spoken over `wa-term-proto`: the SAME wire `screen.rs:762` uses. It takes the call as a closure so
/// the adapter is testable without the program - `screen.rs` passes its own `call`, a test passes a recorder.
pub struct ProtoDocument {
    call: Box<dyn Fn(&str, serde_json::Value) -> Result<serde_json::Value, String> + Send>,
    dirty: bool,
}

impl ProtoDocument {
    pub fn new(call: Box<dyn Fn(&str, serde_json::Value) -> Result<serde_json::Value, String> + Send>) -> ProtoDocument {
        ProtoDocument { call, dirty: false }
    }

    fn ask(&mut self, method: &str, args: serde_json::Value) -> Result<serde_json::Value, Fault> {
        match (self.call)(method, args) {
            Ok(value) => {
                self.dirty = true;
                Ok(value)
            }
            Err(message) => Err(Fault::Failed(message)),
        }
    }
}

impl Document for ProtoDocument {
    fn write(&mut self, text: &str) -> Result<(), Fault> {
        self.ask("write", serde_json::json!([text]))?;
        Ok(())
    }

    fn block(&mut self, open: bool) -> Result<(), Fault> {
        self.ask("block", serde_json::json!([open]))?;
        Ok(())
    }

    fn code_block(&mut self) -> Result<(), Fault> {
        self.ask("code_block", serde_json::json!([]))?;
        Ok(())
    }

    fn head(&mut self, text: &str) -> Result<u32, Fault> {
        let value = self.ask("head", serde_json::json!([text]))?;
        value.as_u64().map(|line| line as u32).ok_or_else(|| Fault::Failed("head answered no line".to_string()))
    }

    fn rewrite(&mut self, line: u32, text: &str) -> Result<u32, Fault> {
        let value = self.ask("rewrite", serde_json::json!([line, text]))?;
        value.as_u64().map(|line| line as u32).ok_or_else(|| Fault::Failed("rewrite answered no line".to_string()))
    }

    fn pin_toggle(&mut self) -> Result<Option<bool>, Fault> {
        let value = self.ask("pin_toggle", serde_json::json!([]))?;
        Ok(value.as_bool())
    }

    /// Whether anything changed since the last frame. The program carries this flag on every reply; here it is the
    /// adapter's own bookkeeping - any successful call marks the document changed, and asking clears it.
    fn dirty(&mut self) -> bool {
        let changed = self.dirty;
        self.dirty = false;
        changed
    }
}


/// A `Document` whose wire is owned by ONE worker thread.
///
/// The node's terminal client is thread-local (`Rc`/`RefCell`, `screen.rs:813` `exchange`), while this seam must be
/// `Send` for the host's async verbs. So the client is CREATED on the worker (`open` runs there, not on the caller's
/// thread) and every call crosses an mpsc channel: one owner of the wire, and `screen.rs` keeps its threading.
pub fn channel_document<F>(open: F) -> ProtoDocument
where
    F: FnOnce() -> Box<dyn FnMut(&str, serde_json::Value) -> Result<serde_json::Value, String>> + Send + 'static,
{
    use std::sync::mpsc;

    type Request = (String, serde_json::Value, mpsc::Sender<Result<serde_json::Value, String>>);
    let (requests, incoming) = mpsc::channel::<Request>();

    std::thread::spawn(move || {
        let mut call = open();
        while let Ok((method, args, reply)) = incoming.recv() {
            let _ = reply.send(call(&method, args));
        }
    });

    ProtoDocument::new(Box::new(move |method, args| {
        let (reply, answer) = mpsc::channel();
        requests
            .send((method.to_string(), args, reply))
            .map_err(|_| "the terminal worker is gone".to_string())?;
        answer.recv().map_err(|_| "the terminal worker is gone".to_string())?
    }))
}

/// A node that never installed a document says so, rather than answering as an empty terminal.
fn missing() -> Fault {
    Fault::Refused("terminal_document_absent: the node did not install a document to paint through".to_string())
}

