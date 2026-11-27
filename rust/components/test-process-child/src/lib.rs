//! TEST FIXTURE for the process world. Not shipped, not published, not in `components.lock`.

wit_bindgen::generate!({
    path: "wit",
    world: "fixture",
    generate_all,
});

use crate::exports::wa::test_process_child::driver::{Guest, Report};
use crate::wa::process::child::{self, Process};
use crate::wa::process::types::{Error as Fault, Exit, Spec};

struct Fixture;

impl Guest for Fixture {
    async fn run(program: String, arguments: Vec<String>) -> Result<Report, String> {
        let spec = Spec {
            program,
            arguments,
            environment: Vec::new(),
            working_directory: None,
        };
        let process: Process = Process::spawn(spec).await.map_err(|error| describe(&error))?;
        let exit = process.wait().await;
        let code = match exit {
            Exit::Code(code) => code,
            Exit::Signal(signal) => -(signal as i32),
        };
        Ok(Report { exit: code, stdout_bytes: 0, stderr_bytes: 0 })
    }
}

fn describe(error: &Fault) -> String {
    match error {
        Fault::Failed(message) => message.clone(),
        Fault::Closed => "closed".to_string(),
        other => format!("{other:?}"),
    }
}

export!(Fixture);
