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
                FutureReader::new(access.as_context_mut(), ExitFuture { outcome })
            }
            Err(_) => Err(wasmtime::Error::msg("process handle gone")),
        }
    }

    fn stdout(mut access: Access<'_, Host, Host>, _self: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access.as_context_mut(), EmptyStream)
    }

    fn stderr(mut access: Access<'_, Host, Host>, _self: Resource<Job>) -> wasmtime::Result<StreamReader<Vec<u8>>> {
        StreamReader::new(access.as_context_mut(), EmptyStream)
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
