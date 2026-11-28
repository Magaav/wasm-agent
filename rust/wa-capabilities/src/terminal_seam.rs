//! The `wa:terminal` seam: the DOCUMENT the node paints, behind a trait so the node wires `wa-term`'s program in
//! (over `wa-term-proto`) and a test wires a script.
//!
//! The world was reshaped on 28/11 after reading the program's own dispatcher: it answers a document (write,
//! block, code_block, head, rewrite, pin_toggle) and no `open` - a pty is the operations runner's job (law 17).

use std::future;
use wasmtime::component::{Access, Accessor, HasData, ResourceTable};

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

pub struct Host {
    pub table: ResourceTable,
    pub document: Box<dyn Document>,
    pub wasi: wasmtime_wasi::WasiCtx,
}

impl Host {
    pub fn new(document: Box<dyn Document>) -> Host {
        Host { table: ResourceTable::new(), document, wasi: wasmtime_wasi::WasiCtxBuilder::new().build() }
    }
}

impl HasData for Host {
    type Data<'a> = &'a mut Host;
}

impl wasmtime_wasi::WasiView for Host {
    fn ctx(&mut self) -> wasmtime_wasi::WasiCtxView<'_> {
        wasmtime_wasi::WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wa::terminal::types::Host for Host {}

/// The one sync verb: whether the document changed since the last frame.
impl wa::terminal::document::Host for Host {
    fn dirty(&mut self) -> bool {
        self.document.dirty()
    }
}

/// The async verbs. They resolve FLAT to the WIT error - no `wasmtime::Result` layer, unlike the resource methods
/// of the process world, which nest.
impl wa::terminal::document::HostWithStore<Host> for Host {
    fn write<'a>(
        access: &'a Accessor<Host, Host>,
        text: String,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.write(&text)) }
    }

    fn block<'a>(
        access: &'a Accessor<Host, Host>,
        open: bool,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.block(open)) }
    }

    fn code_block<'a>(
        access: &'a Accessor<Host, Host>,
    ) -> impl future::Future<Output = Result<(), Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.code_block()) }
    }

    fn head<'a>(
        access: &'a Accessor<Host, Host>,
        text: String,
    ) -> impl future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.head(&text)) }
    }

    fn rewrite<'a>(
        access: &'a Accessor<Host, Host>,
        line: u32,
        text: String,
    ) -> impl future::Future<Output = Result<u32, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.rewrite(line, &text)) }
    }

    fn pin_toggle<'a>(
        access: &'a Accessor<Host, Host>,
    ) -> impl future::Future<Output = Result<Option<bool>, Fault>> + Send + 'a {
        async move { access.with(|mut access| access.data_mut().document.pin_toggle()) }
    }
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


    /// ROW: a real component that imports `wa:terminal/document` LINKS against this host. The fixture crate is built
    /// in the test (its own target dir), granted WASI and the document interface, and instantiated ASYNC - this store
    /// is `component-model-async`, so `Linker::instantiate` is refused outright.
    #[test]
    fn a_guest_that_paints_links_against_the_document_seam() {
        struct Noop;
        impl std::task::Wake for Noop {
            fn wake(self: std::sync::Arc<Self>) {}
        }
        fn block_on<F: std::future::Future>(future: F) -> F::Output {
            let waker = std::task::Waker::from(std::sync::Arc::new(Noop));
            let mut cx = std::task::Context::from_waker(&waker);
            let mut future = Box::pin(future);
            loop {
                match future.as_mut().poll(&mut cx) {
                    std::task::Poll::Ready(value) => return value,
                    std::task::Poll::Pending => std::thread::yield_now(),
                }
            }
        }

        let fixture = std::path::Path::new("../components/test-terminal-document");
        assert!(fixture.is_dir(), "the fixture crate must exist");

        let target = std::env::temp_dir().join("wa-terminal-fixture-target");
        let built = std::process::Command::new("cargo")
            .current_dir(fixture)
            .env("CARGO_TARGET_DIR", &target)
            .args(["build", "--offline", "--target", "wasm32-wasip2", "--release"])
            .output()
            .expect("cargo must run");
        assert!(
            built.status.success(),
            "the fixture must build: {}",
            String::from_utf8_lossy(&built.stderr)
        );

        let artifact = target.join("wasm32-wasip2/release/test_terminal_document.wasm");
        let engine = wasmtime::Engine::default();
        let component = wasmtime::component::Component::from_file(&engine, &artifact)
            .expect("the fixture must load as a component");

        struct Quiet;
        impl Document for Quiet {
            fn write(&mut self, _text: &str) -> Result<(), Fault> { Ok(()) }
            fn block(&mut self, _open: bool) -> Result<(), Fault> { Ok(()) }
            fn code_block(&mut self) -> Result<(), Fault> { Ok(()) }
            fn head(&mut self, _text: &str) -> Result<u32, Fault> { Ok(1) }
            fn rewrite(&mut self, line: u32, _text: &str) -> Result<u32, Fault> { Ok(line) }
            fn pin_toggle(&mut self) -> Result<Option<bool>, Fault> { Ok(None) }
            fn dirty(&mut self) -> bool { false }
        }

        let mut linker = wasmtime::component::Linker::<Host>::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker).expect("WASI must link");
        TerminalClient::add_to_linker::<Host, Host>(&mut linker, |host: &mut Host| host)
            .expect("the document seam must be grantable");
        let mut store = wasmtime::Store::new(&engine, Host::new(Box::new(Quiet)));

        block_on(linker.instantiate_async(&mut store, &component))
            .unwrap_or_else(|error| panic!("a granted painter must instantiate: {error:?}"));
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
