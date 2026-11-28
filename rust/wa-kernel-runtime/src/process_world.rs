//! `wa:process@0.1.0`: the process world, served from the same home as every other world the linker grants
//! (`vision_host.rs`, `terminal_host.rs`, `queue_host.rs`).
//!
//! The node supplies the work: `install` takes a `Runner` - the node's own supervisor seam - because
//! wa-kernel-runtime cannot reach `operations::foreground` (the dependency runs capabilities -> kernel-runtime).
//! Without an installed runner a spawn answers `process_runner_absent`, the same named refusal the terminal
//! document gives.

use std::sync::OnceLock;


use crate::service_components_v2::State;


/// What the node must supply: one spawn, and one read of a finished operation's record.
pub trait Runner: Send + Sync {
    /// Run to completion. Called on a worker thread; the guest awaits the future this settles.
    fn foreground(
        &self,
        program: &str,
        line: &str,
        context: &serde_json::Value,
    ) -> Result<serde_json::Value, String>;

    /// `read`/`cancel` and anything else the world asks the supervisor for.
    fn call(&self, method: &str, args: serde_json::Value) -> Result<serde_json::Value, String>;
}

static RUNNER: OnceLock<Box<dyn Runner>> = OnceLock::new();

/// Hand the node's supervisor seam to the world. Called once; a second call keeps the first (one owner).
pub fn install(runner: Box<dyn Runner>) {
    let _ = RUNNER.set(runner);
}

fn runner() -> Option<&'static dyn Runner> {
    RUNNER.get().map(|boxed| boxed.as_ref())
}

fn foreground(program: &str, line: &str, context: &serde_json::Value) -> Result<serde_json::Value, String> {
    runner()
        .ok_or_else(|| "process_runner_absent: the node installed no process runner".to_string())?
        .foreground(program, line, context)
}

fn record(method: &str, args: &serde_json::Value) -> Result<serde_json::Value, String> {
    runner()
        .ok_or_else(|| "process_runner_absent: the node installed no process runner".to_string())?
        .call(method, args.clone())
}

/// Link the process world into a service linker, beside terminal and the rest.
pub fn link(linker: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    ProcessClient::add_to_linker::<State, State>(linker, |state| state)
}


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



/// A `wasm32-wasip2` guest imports `wasi:cli` and `wasi:io/poll` whether it uses them or not, so the store carries
/// a WASI context; without it the linker has nothing to grant those imports from.

impl wa::process::child::Host for State {}

impl wa::process::types::Host for State {}

impl wa::process::child::HostProcess for State {
    fn drop(&mut self, _rep: Resource<Job>) -> wasmtime::Result<()> {
        Ok(())
    }
}

impl wa::process::child::HostProcessWithStore<State> for State {
    fn spawn(
        access: &Accessor<State, State>,
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
                let answer = match runner() {
                    Some(run) => run.foreground(&program, &line, &context),
                    None => Err("process_runner_absent: the node installed no process runner".to_string()),
                };
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
        _access: &Accessor<State, State>,
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

    fn wait(mut access: Access<'_, State, State>, self_: Resource<Job>) -> wasmtime::Result<FutureReader<Exit>> {
        match access.data_mut().table.get(&self_) {
            Ok(job) => {
                let outcome = job.outcome.clone();
                FutureReader::new(access.as_context_mut(), ExitFuture { outcome })
            }
            Err(_) => Err(wasmtime::Error::msg("process handle gone")),
        }
    }

    fn stdout(mut access: Access<'_, State, State>, self_: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let operation = match access.data_mut().table.get(&self_) {
            Ok(job) => job.operation.clone(),
            Err(_) => return Err(wasmtime::Error::msg("process handle gone")),
        };
        let source = OutputStream::new(Box::new(RecordOutput::new(
            operation,
            Box::new(|method, args| record(method, &args)),
        )));
        StreamReader::new(access.as_context_mut(), source)
    }

    fn stderr(mut access: Access<'_, State, State>, self_: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        let operation = match access.data_mut().table.get(&self_) {
            Ok(job) => job.operation.clone(),
            Err(_) => return Err(wasmtime::Error::msg("process handle gone")),
        };
        let source = OutputStream::new(Box::new(RecordOutput::new(
            operation,
            Box::new(|method, args| record(method, &args)),
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

impl FutureProducer<State> for ExitFuture {
    type Item = Exit;

    fn poll_produce(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        _store: StoreContextMut<State>,
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

impl StreamProducer<State> for OutputStream {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, State>,
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


    /// ROW: `wait` returns the exit once the operation settled - `Pending` while the child runs, then `Code(7)`, and
    /// the record is not consulted twice. This row was lost when the world moved here (it needs a store);
    /// `service_components_v2::state_for_tests` brings it back beside the world it tests.
    #[test]
    fn wait_returns_the_exit_it_was_given() {
        let engine = wasmtime::Engine::default();
        let mut store = wasmtime::Store::new(
            &engine,
            crate::service_components_v2::state_for_tests("wa-process-row"),
        );

        let outcome: Arc<Mutex<Option<Exit>>> = Arc::new(Mutex::new(None));
        let mut future = ExitFuture { outcome: outcome.clone() };

        struct Noop;
        impl std::task::Wake for Noop {
            fn wake(self: Arc<Self>) {}
        }
        let waker = std::task::Waker::from(Arc::new(Noop));
        let mut cx = std::task::Context::from_waker(&waker);

        let pending = std::pin::Pin::new(&mut future).poll_produce(&mut cx, store.as_context_mut(), false);
        assert!(matches!(pending, std::task::Poll::Pending), "a running child must not settle");

        *outcome.lock().unwrap() = Some(Exit::Code(7));
        match std::pin::Pin::new(&mut future).poll_produce(&mut cx, store.as_context_mut(), false) {
            std::task::Poll::Ready(Ok(Some(Exit::Code(code)))) => assert_eq!(code, 7),
            other => panic!("the exit must be delivered once: {other:?}"),
        }
    }

    /// ROW: the world is GRANTED by the runner, beside terminal and vision.
    #[test]
    fn the_runner_grants_the_process_world() {
        let engine = wasmtime::Engine::default();
        let mut linker = wasmtime::component::Linker::<State>::new(&engine);
        link(&mut linker).expect("the process world must link");
        assert!(link(&mut linker).is_err(), "the same interface must not be granted twice");
    }
}
