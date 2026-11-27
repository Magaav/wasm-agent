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
use wasmtime::StoreContextMut;

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
}

impl HasData for Job {
    type Data<'a> = &'a mut Job;
}

/// The store data this world is bound against.
pub struct Host {
    pub table: ResourceTable,
}

impl Host {
    pub fn new() -> Host {
        Host { table: ResourceTable::new() }
    }
}

impl HasData for Host {
    type Data<'a> = &'a mut Host;
}

impl wa::process::child::Host for Host {}

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

            match access.with(|mut access| access.data_mut().table.push(Job { outcome })) {
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
                FutureReader::new(access, ExitFuture { outcome })
            }
            Err(_) => Err(wasmtime::Error::msg("process handle gone")),
        }
    }

    fn stdout(mut access: Access<'_, Host, Host>, _self: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access, EmptyStream)
    }

    fn stderr(mut access: Access<'_, Host, Host>, _self: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access, EmptyStream)
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

/// The output streams, declared and ended at once: the bytes live in the operation record.
pub struct EmptyStream;

impl StreamProducer<Host> for EmptyStream {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _store: StoreContextMut<'a, Host>,
        _destination: Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> Poll<wasmtime::Result<StreamResult>> {
        Poll::Ready(Ok(StreamResult::Dropped))
    }
}
