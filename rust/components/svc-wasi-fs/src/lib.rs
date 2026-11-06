//! Fixture for the WASI grant policy (`docs/WASI-INTERFACES.md`, tier B): `wasi:filesystem@0.3.0`.
//!
//! What it proves, in the component's own log:
//!   * `fs preopens=[("/data", "data"|"ro")]` - which guest paths the host preopened and whether it
//!     granted write. A grant with no `dirs` never reaches this line: the interface is not linked and
//!     the component is refused before it runs (`wasi_import_not_granted`).
//!   * `fs read note.txt=<text>` - the file inside the preopen is readable, so the preopen points at
//!     the directory the operator named.
//!   * `fs escape denied=<code>` - `open-at("../escape.txt")` is refused. `../` is the escape the
//!     operator worries about; the preopen's confinement answers it, and the test asserts the file
//!     outside the preopen was neither read nor created.
//!   * `fs write ok` only when the preopen was granted read-write, so a read-only grant is provable
//!     by the failure it produces rather than by the absence of a line.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-fs", generate_all });

use std::time::Duration;
use wa::kernel::{lifecycle, log};
use wasi::clocks::monotonic_clock;
use wasi::filesystem::preopens;
use wasi::filesystem::types::{self, DescriptorFlags, OpenFlags, PathFlags};

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "wasi-fs", text);
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(_config: String) -> Result<(), String> {
        let dirs = preopens::get_directories();
        let summary: Vec<String> = dirs.iter().map(|(_, guest)| guest.clone()).collect();
        line(&format!("fs preopens={summary:?}"));
        let Some((root, guest)) = dirs.first() else {
            line("fs no preopens");
            return Ok(());
        };
        line(&format!("fs guest={guest}"));

        // A read inside the preopen: the operator's `head` of the file, bounded.
        match root
            .open_at(PathFlags::empty(), "note.txt".to_string(), OpenFlags::empty(), DescriptorFlags::READ)
            .await
        {
            Ok(file) => {
                let (mut stream, _errors) = file.read_via_stream(0);
                let mut text = Vec::new();
                while let Some(byte) = stream.next().await {
                    text.push(byte);
                    if text.len() >= 512 {
                        break;
                    }
                }
                line(&format!("fs read note.txt={}", String::from_utf8_lossy(&text).trim()));
            }
            Err(error) => line(&format!("fs read refused={error:?}")),
        }

        // A write open, which a read-only preopen must refuse: `write ok` / `write refused=<code>`.
        // The bytes themselves are not written - `write-via-stream` takes a guest-made `stream<u8>`,
        // which would be a second thing to test - because the *grant* is what decides here: the open
        // is where a read-only preopen answers `not-permitted`.
        match root
            .open_at(
                PathFlags::empty(),
                "written.txt".to_string(),
                OpenFlags::CREATE | OpenFlags::TRUNCATE,
                DescriptorFlags::WRITE,
            )
            .await
        {
            Ok(_) => line("fs write open ok"),
            Err(error) => line(&format!("fs write refused={error:?}")),
        }

        // The escape, aimed one level above the preopen. It must be a refusal whatever the grant says.
        match root
            .open_at(PathFlags::empty(), "../escape.txt".to_string(), OpenFlags::empty(), DescriptorFlags::READ)
            .await
        {
            Ok(_) => line("fs escape allowed"),
            Err(error) => line(&format!("fs escape denied={error:?}")),
        }
        // An absolute path is another spelling of the same escape.
        match root
            .open_at(PathFlags::empty(), "/escape.txt".to_string(), OpenFlags::empty(), DescriptorFlags::READ)
            .await
        {
            Ok(_) => line("fs absolute allowed"),
            Err(_) => line("fs absolute denied"),
        }
        // `types` is imported for its flags alone; one call keeps the import exercised.
        line(&format!("fs descriptor-kind={:?}", root.get_type().await));

        lifecycle::report(lifecycle::Health::Ready, None);
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            monotonic_clock::wait_for(Duration::from_millis(100).as_nanos() as u64).await;
        }
    }
}

// The descriptor methods used above are inherent to the generated `Descriptor` type; this alias
// keeps the `types` import meaningful for a reader looking for it.
type _Descriptor = types::Descriptor;

export!(Service);
