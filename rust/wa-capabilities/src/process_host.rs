//! `wa:process@0.1.0` served by this node (terminal-and-operations brief, slice 2).
//!
//! **One owner.** The runner left this binary, so a child a COMPONENT spawns is an operation of the NODE: this host
//! does not start processes itself - it asks the supervisor through the same `operations::foreground` the `bash` tool
//! uses. No second supervisor, no in-process runner.
//!
//! Shapes settled against wasmtime 50's generated traits, each from a compiler error rather than a guess:
//! `spawn`/`stop` take `&Accessor<Host, Host>` and return `impl Future`; `wait`/`stdout`/`stderr` take an `Access`
//! BY VALUE, which is what makes `FutureReader::new` work - `Access<'a, T, D>` implements `AsContextMut`
//! (`concurrent.rs:286`), and that impl is the whole answer to "how does a host hand a store to a reader".

use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use wasmtime::component::{
    Access, Accessor, Destination, FutureProducer, FutureReader, HasData, Resource, ResourceTable, StreamProducer,
    StreamReader, StreamResult,
};
use wasmtime::{AsContextMut, StoreContextMut};

wasmtime::component::bindgen!({
    world: "process-client",
    path: "../../wit/process",
    imports: {
        "wa:process/child.[method]process.stdout": store | trappable,
        "wa:process/child.[method]process.stderr": store | trappable,
        "wa:process/child.[method]process.wait": store | trappable,
    },
    with: {
        "wa:process/child.process": Job,
    },
});

use wa::process::types::{Error as Fault, Exit, Spec as Request};

/// One child, as the guest holds it: where its result will land, and nothing else.
pub struct Job {
    outcome: Arc<Mutex<Option<Exit>>>,
    /// The supervisor's operation id, filled once `foreground` answers; the output reader needs it.
    operation: Arc<Mutex<Option<String>>>,
}

impl HasData for Job {
    type Data<'a> = &'a mut Job;
}

/// The store data this world is bound against.
pub struct Host {
    pub table: ResourceTable,
    pub wasi: wasmtime_wasi::WasiCtx,
}

impl Host {
    pub fn new() -> Host {
        Host {
            table: ResourceTable::new(),
            wasi: wasmtime_wasi::WasiCtxBuilder::new().build(),
        }
    }
}

/// A `wasm32-wasip2` guest imports `wasi:cli` and `wasi:io/poll` whether it uses them or not, so the store carries
/// a WASI context; without it the linker has nothing to grant those imports from.
impl wasmtime_wasi::WasiView for Host {
    fn ctx(&mut self) -> wasmtime_wasi::WasiCtxView<'_> {
        wasmtime_wasi::WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl HasData for Host {
    type Data<'a> = &'a mut Host;
}

impl wa::process::child::Host for Host {}

impl wa::process::types::Host for Host {}

impl wa::process::child::HostProcess for Host {
    fn drop(&mut self, _rep: Resource<Job>) -> wasmtime::Result<()> {
        Ok(())
    }
}

impl wa::process::child::HostProcessWithStore<Host> for Host {
    fn spawn(
        access: &Accessor<Host, Host>,
        request: Request,
    ) -> impl std::future::Future<Output = std::result::Result<Resource<Job>, Fault>> + '_ {
        async move {
            let outcome: Arc<Mutex<Option<Exit>>> = Arc::new(Mutex::new(None));
            let settled = outcome.clone();
            let operation: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
            let recorded = operation.clone();

            let mut line = request.program.clone();
            for argument in &request.arguments {
                line.push(' ');
                line.push_str(&shell_quote(argument));
            }
            let context = serde_json::json!({"origin": "wa:process/child.spawn"});
            let program = request.program.clone();

            std::thread::spawn(move || {
                let answer = crate::operations::foreground(&program, "-c", &line, "/", 300, &context, None);
                let exit = match answer {
                    Ok(value) => match value["exit_code"].as_i64() {
                        Some(code) => Exit::Code(code as i32),
                        None => Exit::Signal(9),
                    },
                    Err(_) => Exit::Signal(9),
                };
                if let Ok(mut slot) = settled.lock() {
                    *slot = Some(exit);
                }
            });

            match access.with(|mut access| access.data_mut().table.push(Job { outcome, operation })) {
                Ok(job) => Ok(job),
                Err(error) => Err(Fault::Failed(error.to_string())),
            }
        }
    }

    fn stop(
        _access: &Accessor<Host, Host>,
        _self: Resource<Job>,
        _signal: Option<u32>,
    ) -> impl std::future::Future<Output = std::result::Result<bool, Fault>> + '_ {
        async move {
            // Named, not faked: a `foreground` operation cannot be cancelled once started, and returning `false`
            // would claim it simply was not running. Cancelling through the supervisor is the next slice.
            Err(Fault::Failed(
                "stop is not wired: a foreground operation cannot be cancelled once started (next slice)".to_string(),
            ))
        }
    }

    fn wait(mut access: Access<'_, Host, Host>, self_: Resource<Job>) -> wasmtime::Result<FutureReader<Exit>> {
        match access.data_mut().table.get(&self_) {
            Ok(job) => {
                let outcome = job.outcome.clone();
                FutureReader::new(access.as_context_mut(), ExitFuture { outcome })
            }
            Err(_) => Err(wasmtime::Error::msg("process handle gone")),
        }
    }

    fn stdout(mut access: Access<'_, Host, Host>, self_: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let operation = match access.data_mut().table.get(&self_) {
            Ok(job) => job.operation.clone(),
            Err(_) => return Err(wasmtime::Error::msg("process handle gone")),
        };
        let source = OutputStream::new(Box::new(RecordOutput::new(
            operation,
            Box::new(|method, args| crate::operations::call(method, &args)),
        )));
        StreamReader::new(access.as_context_mut(), source)
    }

    fn stderr(mut access: Access<'_, Host, Host>, self_: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let operation = match access.data_mut().table.get(&self_) {
            Ok(job) => job.operation.clone(),
            Err(_) => return Err(wasmtime::Error::msg("process handle gone")),
        };
        let source = OutputStream::new(Box::new(RecordOutput::new(
            operation,
            Box::new(|method, args| crate::operations::call(method, &args)),
        )));
        StreamReader::new(access.as_context_mut(), source)
    }
}

/// A minimal shell quoting, so an argument with a space reaches the program as one argument.
fn shell_quote(argument: &str) -> String {
    if argument.is_empty() {
        return "''".to_string();
    }
    if argument.chars().all(|c| c.is_alphanumeric() || "-_./=:@+".contains(c)) {
        return argument.to_string();
    }
    format!("'{}'", argument.replace('\'', "'\\''"))
}

/// The exit, once: FOUR parameters and an `Option` value, per `FutureProducer` in wasmtime 50.
pub struct ExitFuture {
    outcome: Arc<Mutex<Option<Exit>>>,
}

impl FutureProducer<Host> for ExitFuture {
    type Item = Exit;

    fn poll_produce(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        _store: StoreContextMut<Host>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<Option<Self::Item>>> {
        if let Ok(slot) = self.outcome.lock() {
            if let Some(exit) = *slot {
                return Poll::Ready(Ok(Some(exit)));
            }
        }
        let waker = cx.waker().clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(20));
            waker.wake();
        });
        Poll::Pending
    }
}

/// Where a child's output comes from. This is the SEAM: the host wires the supervisor's operation record in
/// (`RecordOutput`), and a test wires a fake in, so the stream path is a unit test rather than a live node.
pub trait OutputSource: Send {
    /// The next chunk, or `None` when the output has ended.
    fn next_chunk(&mut self) -> Option<Vec<u8>>;
}

/// The output of one child, streamed into the guest.
pub struct OutputStream {
    source: Box<dyn OutputSource>,
}

impl OutputStream {
    pub fn new(source: Box<dyn OutputSource>) -> OutputStream {
        OutputStream { source }
    }
}

impl StreamProducer<Host> for OutputStream {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, Host>,
        mut destination: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        match self.source.next_chunk() {
            Some(chunk) => {
                destination.set_buffer(Some(chunk));
                // `Completed` after `set_buffer` is what delivers the buffered item (`futures_and_streams.rs:686`).
                Poll::Ready(Ok(StreamResult::Completed))
            }
            None => Poll::Ready(Ok(StreamResult::Dropped)),
        }
    }
}

/// The supervisor-backed reader: the operation's recorded output, served once and then ended. Kept deliberately
/// small - reading a live record in slices needs the supervisor and belongs to the node, not to this seam.
pub struct RecordOutput {
    operation: Arc<Mutex<Option<String>>>,
    /// The call, injected: the host passes `operations::call`, a test passes a fake. The same seam the terminal
    /// adapter uses, so the content path is a unit test and not a live supervisor.
    call: Box<dyn Fn(&str, serde_json::Value) -> Result<serde_json::Value, String> + Send>,
    served: bool,
}

impl RecordOutput {
    pub fn new(
        operation: Arc<Mutex<Option<String>>>,
        call: Box<dyn Fn(&str, serde_json::Value) -> Result<serde_json::Value, String> + Send>,
    ) -> RecordOutput {
        RecordOutput { operation, call, served: false }
    }
}

impl OutputSource for RecordOutput {
    fn next_chunk(&mut self) -> Option<Vec<u8>> {
        if self.served {
            return None;
        }
        self.served = true;
        let id = self.operation.lock().ok()?.clone()?;
        let answer = (self.call)("read", serde_json::json!({"id": id})).ok()?;
        answer
            .get("output")
            .and_then(|value| value.as_str())
            .map(|text| text.as_bytes().to_vec())
    }
}

/// Every chunk this source yields, in order - the shape a test can assert without a wasmtime store.
fn collect(mut source: Box<dyn OutputSource>) -> Vec<u8> {
    let mut all = Vec::new();
    while let Some(chunk) = source.next_chunk() {
        all.extend_from_slice(&chunk);
    }
    all
}

#[cfg(test)]
mod rows {

    use super::*;
    use std::sync::Arc;
    use std::task::{Context, Wake, Waker};

    struct Noop;
    impl Wake for Noop {
        fn wake(self: Arc<Self>) {}
    }

    fn waker() -> Waker {
        Waker::from(Arc::new(Noop))
    }
    /// ROW: `wait` returns the exit once the operation settled - the whole point of handing the guest one future.
    #[test]
    fn wait_returns_the_exit_it_was_given() {
        let engine = wasmtime::Engine::default();
        let mut store = wasmtime::Store::new(&engine, Host::new());

        let outcome = Arc::new(Mutex::new(None));
        let mut future = ExitFuture { outcome: outcome.clone() };
        let waker = waker();
        let mut cx = Context::from_waker(&waker);

        // Before the operation settles the future is pending - not a made-up value.
        let pending = Pin::new(&mut future).poll_produce(&mut cx, store.as_context_mut(), false);
        assert!(matches!(pending, Poll::Pending), "a running child must not settle");

        *outcome.lock().unwrap() = Some(Exit::Code(7));
        let settled = Pin::new(&mut future).poll_produce(&mut cx, store.as_context_mut(), false);
        match settled {
            Poll::Ready(Ok(Some(Exit::Code(code)))) => assert_eq!(code, 7),
            other => panic!("the exit must be delivered once: {other:?}"),
        }
    }


    /// ROW: a component that imports an interface the host has NOT granted is refused at instantiation. The
    /// refusal lives in the LINKER, which is why this row could not exist before a host did.
    ///
    /// The component is built in the test from WAT: `wat` is a dev-dependency and does produce COMPONENT bytes
    /// (verified against `Component::from_binary` before this row was written), so the fixture is test-local and no
    /// product component is added.
    ///
    /// Honest scope: no repo guest imports `wa:process/child` yet, so the import named here is of the same kind but
    /// not the world itself; the rule covers the world the moment a guest names it.
    #[test]
    fn a_component_is_refused_without_its_grant() {
        let engine = wasmtime::Engine::default();
        let source = r#"
            (component
              (import "wa:process/child" (instance
                (export "spawn" (func (result u32)))
              ))
            )
        "#;
        let bytes = wat::parse_str(source).unwrap_or_else(|error| panic!("WAT parse: {error:?}"));
        let component = wasmtime::component::Component::from_binary(&engine, &bytes)
            .unwrap_or_else(|error| panic!("the fixture must be a component: {error:?}"));

        let imported = component.component_type().imports(&engine).count();
        assert!(imported > 0, "the fixture must import something for this row to mean anything");

        // A linker that grants NOTHING: the only difference from the real host is the grant itself.
        let mut linker = wasmtime::component::Linker::<Host>::new(&engine);
        let mut store = wasmtime::Store::new(&engine, Host::new());

        match linker.instantiate(&mut store, &component) {
            Err(error) => {
                let message = error.to_string().to_lowercase();
                assert!(
                    message.contains("import") || message.contains("unknown"),
                    "the refusal must name the ungranted import, got: {message}"
                );
            }
            Ok(_) => panic!("a component with {imported} imports must not instantiate against an empty grant"),
        }
    }


    /// GUARD: a TEST fixture component must never become a shipped one. `components.lock` is what a deploy
    /// installs; a fixture that appears there is a product mistake, so this fails loudly rather than shipping
    /// silently. The rule is by name: anything called `test-*` is a fixture.
    #[test]
    fn fixture_components_are_never_shipped() {
        let lock = std::path::Path::new("../../components.lock");
        let text = std::fs::read_to_string(lock).expect("components.lock must be readable");
        let shipped: Vec<&str> = text
            .lines()
            .filter(|line| !line.trim_start().starts_with('#'))
            .collect();
        for line in shipped {
            assert!(
                !line.contains("test-"),
                "a test fixture must never be in components.lock: {line}"
            );
        }
    }


    /// ROW: a component importing `wa:process/child` LINKS and instantiates when the host is granted - the other
    /// half of `a_component_is_refused_without_its_grant`, measured on the real fixture crate.
    ///
    /// This store is built with `component-model-async`, so `Linker::instantiate` is refused and the async call is
    /// driven by `block_on` below; a `wasm32-wasip2` guest also imports `wasi:cli`/`wasi:io/poll` implicitly, so WASI
    /// is granted first.
    #[test]
    fn a_granted_component_links_against_this_host() {
        fn block_on<F: std::future::Future>(future: F) -> F::Output {
            struct Noop;
            impl Wake for Noop {
                fn wake(self: Arc<Self>) {}
            }
            let waker = Waker::from(Arc::new(Noop));
            let mut cx = Context::from_waker(&waker);
            let mut future = Box::pin(future);
            loop {
                match future.as_mut().poll(&mut cx) {
                    Poll::Ready(value) => return value,
                    Poll::Pending => std::thread::yield_now(),
                }
            }
        }

        let fixture = std::path::Path::new("../components/test-process-child");
        assert!(fixture.is_dir(), "the fixture crate must exist");

        let target = std::env::temp_dir().join("wa-fixture-target");
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

        let artifact = target.join("wasm32-wasip2/release/test_process_child.wasm");
        let engine = wasmtime::Engine::default();
        let component = wasmtime::component::Component::from_file(&engine, &artifact)
            .expect("the fixture must load as a component");

        let mut linker = wasmtime::component::Linker::<Host>::new(&engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker).expect("WASI must link");
        ProcessClient::add_to_linker::<Host, Host>(&mut linker, |host: &mut Host| host)
            .expect("the host must be grantable");
        let mut store = wasmtime::Store::new(&engine, Host::new());

        let instance = block_on(linker.instantiate_async(&mut store, &component));
        instance.unwrap_or_else(|error| panic!("a GRANTED component must instantiate: {error:?}"));
    }


    /// ROW: the stream seam. A fake source yields three chunks and ends; `collect` - the exact loop the producer
    /// runs - returns them in order and then stops. No supervisor, no process, no wasmtime store: the seam is what
    /// makes the output path testable at all.
    #[test]
    fn output_chunks_are_streamed_in_order() {
        struct Fake {
            chunks: Vec<Vec<u8>>,
        }

        impl OutputSource for Fake {
            fn next_chunk(&mut self) -> Option<Vec<u8>> {
                if self.chunks.is_empty() {
                    None
                } else {
                    Some(self.chunks.remove(0))
                }
            }
        }

        let source = Fake { chunks: vec![b"one ".to_vec(), b"two ".to_vec(), b"three".to_vec()] };
        assert_eq!(collect(Box::new(source)), b"one two three".to_vec());

        // An empty child yields nothing and ends cleanly rather than stalling.
        let empty = Fake { chunks: Vec::new() };
        assert!(collect(Box::new(empty)).is_empty());
    }


    /// ROW: the bytes the guest sees in `stdout` come from the operation's RECORD, and the record is asked for the
    /// right process. A fake call stands in for the supervisor, so the content path is asserted without a node.
    #[test]
    fn output_content_comes_from_the_record() {
        use std::sync::{Arc, Mutex};

        let asked: Arc<Mutex<Vec<(String, serde_json::Value)>>> = Arc::new(Mutex::new(Vec::new()));
        let recorded = asked.clone();
        let operation = Arc::new(Mutex::new(Some("op-42".to_string())));

        let source = RecordOutput::new(
            operation,
            Box::new(move |method, args| {
                recorded.lock().unwrap().push((method.to_string(), args));
                Ok(serde_json::json!({"output": "hello from the record\n"}))
            }),
        );

        assert_eq!(collect(Box::new(source)), b"hello from the record\n".to_vec());

        let asked = asked.lock().unwrap();
        assert_eq!(asked.len(), 1, "the record is read once, not on every poll");
        assert_eq!(asked[0].0, "read");
        assert_eq!(asked[0].1, serde_json::json!({"id": "op-42"}), "the record must be the child's own");
    }

    /// ROW: an argument with a space or a quote reaches the program as ONE argument - asserted by running a real
    /// shell and comparing what came back, not by spelling the escaping out (the first version of this test did
    /// that, and was wrong about the bytes while the code was right).
    #[test]
    fn quoting_keeps_arguments_whole() {
        for argument in ["plain", "two words", "it's", "a$b", r"back\slash"] {
            let quoted = shell_quote(argument);
            let output = std::process::Command::new("sh")
                .arg("-c")
                .arg(format!("printf %s {quoted}"))
                .output()
                .expect("sh must run");
            assert_eq!(String::from_utf8_lossy(&output.stdout), argument, "quoting {argument:?}");
        }
    }
}
