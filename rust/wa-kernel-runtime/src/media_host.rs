//! Running the media component (`wa:media`) with the grant it was given - and checking its answer.
//!
//! WHY THIS IS A MODULE OF THE RUNTIME AND NOT A CALLER'S BUSINESS. The kernel already owns the two things
//! this needs and no caller should re-implement: `Grant.dirs` (a host directory, a guest path, and whether it
//! is writable) and the preopen that turns it into a capability the guest can reach. What it did not have is a
//! way to CALL a component's typed exports - every other path runs a component as a process with JSON on
//! stdin, which would base64 media through messages. This module instantiates the component and calls the three
//! `wa:media` operations directly, with a WasiCtx built from the grant.
//!
//! THE PART THAT MATTERS IS THE CHECK AFTER THE CALL, not the call. A component that writes a file can claim
//! any path, any size and any digest; the same is true of a component that has been compromised. So the answer
//! is only reported after: the returned path is proven to lie inside the granted out-dir (no `..`, no absolute
//! surprise), the host maps that guest path back to its own file, and the size and sha256 are recomputed from
//! the bytes on disk and compared with what the component said. A disagreement is a failure, never a warning.

use std::path::{Path, PathBuf};

use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::{FsPerms, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

use crate::components::DirGrant;

wasmtime::component::bindgen!({
    path: "../components/media/wit",
    world: "media-service",
});

/// The KERNEL-side contract (`wa:kernel/media@0.2.0`), generated from the package the runner links. A component
/// that wants media declares `world service-media` - the same shape the image reader uses with
/// `service-vision` - and the runner serves it from here. Generating these bindings is also what proves the
/// interface parses; the `Host` impl and its linker call land with the runner wiring, and nothing is served
/// until they do.
pub mod kernel_media {
    wasmtime::component::bindgen!({
        path: "../../wit/kernel-v2",
        world: "service-media",
    });
}

/// Load the INSTALLED component by name - `components::load` verifies its bytes against the pin beside it,
/// and `service_components_v2::compiled` compiles it through the node's cache, so a second call costs nothing.
/// A caller that named a path instead would bypass the pin, which is the one thing installation exists for.
pub fn load(engine: &Engine, name: &str) -> Result<Component, String> {
    let installed = crate::components::load(name).map_err(|error| error.to_string())?;
    crate::service_components_v2::compiled(engine, &installed.sha256, &installed.bytes)
        .map_err(|error| format!("compile:{error}"))
}

struct Host {
    ctx: WasiCtx,
    table: ResourceTable,
}

impl WasiView for Host {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.ctx, table: &mut self.table }
    }
}

/// One `file` the component answered, after the host proved it.
pub struct VerifiedFile {
    /// The path as the HOST sees it (guest path mapped back through the grant).
    pub host_path: PathBuf,
    pub bytes: u64,
    pub sha256: String,
    pub mime: String,
}

/// Why an answer could not be trusted. Each variant is a different lie a component could tell.
#[derive(Debug, PartialEq, Eq)]
pub enum Unverified {
    /// The path is not under the granted out-dir, or walks out of it.
    OutsideTheGrant(String),
    /// The guest path names no directory the host granted, so it cannot be mapped back to a file.
    NoSuchGrant(String),
    /// The file is not there, or cannot be read.
    Missing(String),
    /// The bytes on disk are not the bytes the component described.
    SizeMismatch { claimed: u64, found: u64 },
    /// The digest on disk is not the digest the component described.
    DigestMismatch { claimed: String, found: String },
}

impl std::fmt::Display for Unverified {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Unverified::OutsideTheGrant(path) => write!(formatter, "outside_the_grant:{path}"),
            Unverified::NoSuchGrant(path) => write!(formatter, "no_such_grant:{path}"),
            Unverified::Missing(path) => write!(formatter, "missing:{path}"),
            Unverified::SizeMismatch { claimed, found } => {
                write!(formatter, "size_mismatch:claimed={claimed}:found={found}")
            }
            Unverified::DigestMismatch { claimed, found } => {
                write!(formatter, "digest_mismatch:claimed={claimed}:found={found}")
            }
        }
    }
}

/// The guest path the file lives at, resolved through the grants.
fn host_path_for(guest: &str, grants: &[DirGrant]) -> Result<PathBuf, Unverified> {
    if guest.split('/').any(|part| part == "..") {
        return Err(Unverified::OutsideTheGrant(guest.to_string()));
    }
    // The longest matching guest prefix wins: `/out` must not be shadowed by `/`.
    let mut best: Option<(&DirGrant, &str)> = None;
    for grant in grants {
        let prefix = grant.guest.trim_end_matches('/');
        if let Some(rest) = guest.strip_prefix(prefix) {
            if rest.is_empty() || rest.starts_with('/') {
                if best.map(|(current, _)| prefix.len() > current.guest.trim_end_matches('/').len()).unwrap_or(true) {
                    best = Some((grant, rest));
                }
            }
        }
    }
    let (grant, rest) = best.ok_or_else(|| Unverified::NoSuchGrant(guest.to_string()))?;
    // A file must live INSIDE the directory, never be the directory itself.
    if rest.is_empty() {
        return Err(Unverified::OutsideTheGrant(guest.to_string()));
    }
    Ok(Path::new(&grant.host).join(rest.trim_start_matches('/')))
}

/// Prove that what the component said about a written file is what is on disk.
pub fn verify_file(
    claimed_path: &str,
    claimed_bytes: u64,
    claimed_digest: &str,
    grants: &[DirGrant],
) -> Result<VerifiedFile, Unverified> {
    let host_path = host_path_for(claimed_path, grants)?;
    let bytes = std::fs::read(&host_path).map_err(|_| Unverified::Missing(host_path.display().to_string()))?;
    if bytes.len() as u64 != claimed_bytes {
        return Err(Unverified::SizeMismatch { claimed: claimed_bytes, found: bytes.len() as u64 });
    }
    // ring, like every other digest in this crate: one implementation of sha256 per node.
    let found: String = ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect();
    if !claimed_digest.eq_ignore_ascii_case(&found) {
        return Err(Unverified::DigestMismatch { claimed: claimed_digest.to_string(), found });
    }
    Ok(VerifiedFile {
        host_path,
        bytes: claimed_bytes,
        sha256: found,
        mime: String::new(),
    })
}

/// How many engine ticks a call may take before it is interrupted. The ticker's period is TICK (components.rs),
/// so this is a wall-clock budget for one operation, not an unbounded run.
const EPOCH_TICKS: u64 = 3_000;

/// Build the store the component runs in, from the grant: the directories it may touch, and nothing else.
fn store(engine: &Engine, dirs: &[DirGrant]) -> Result<Store<Host>, String> {
    let mut builder = WasiCtxBuilder::new();
    for dir in dirs {
        let perms = if dir.write { FsPerms::ReadWrite } else { FsPerms::ReadOnly };
        builder
            .preopened_dir(&dir.host, &dir.guest, perms)
            .map_err(|_| format!("component_dir_unavailable:{}", dir.guest))?;
    }
    builder.inherit_stderr();
    let mut store = Store::new(engine, Host { ctx: builder.build(), table: ResourceTable::new() });
    // The node's engine is built with `epoch_interruption(true)` (components.rs:73) and a ticker bumps the
    // epoch every TICK (10 ms, components.rs:44). A store that never arms a deadline traps on its first
    // instantiate; a store armed too tightly traps DURING the work and the trap surfaces wherever the wasm
    // happened to be - for a four-tick budget (40 ms) that was inside `__wasilibc_read` while decoding audio,
    // which reads like a media bug and is a budget bug. 3000 ticks is 30 s: finite, and far above the 5-136 ms
    // these calls measured.
    store.set_epoch_deadline(EPOCH_TICKS);
    Ok(store)
}

fn linker(engine: &Engine) -> Result<Linker<Host>, String> {
    let mut linker = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut linker).map_err(|error| format!("linker:{error}"))?;
    Ok(linker)
}

/// What `probe` answered, after verification of anything it wrote (probe writes nothing).
pub struct Description {
    pub format: String,
    pub duration_ms: u64,
    pub streams: Vec<(String, String, u32, u32)>,
    pub has_audio: bool,
}

/// Run `probe.describe` for one file inside the granted directories.
pub async fn probe(
    engine: &Engine,
    component: &Component,
    dirs: &[DirGrant],
    guest_source: &str,
    host_source: &Path,
) -> Result<Description, String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, dirs)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate_async(&mut store, component, &linker)
        .await
        .map_err(|error| format!("instantiate:{error}"))?;
    let source = wa::media::types::File {
        path: guest_source.to_string(),
        bytes,
        sha256: String::new(),
        mime: String::new(),
    };
    // `run_concurrent` is what lets an async export suspend: the closure gets the store, and the call is a
    // future inside it. Calling through `&mut Store` directly is what wasmtime rejects for an async store.
    let answer = store
        .run_concurrent(async move |store| {
            bindings.wa_media_probe().call_describe(store, source).await
        })
        .await
        .map_err(|error| format!("call:{error}"))?;
    // Two levels: `run_concurrent` answers with the CALL's outcome, and inside it is the guest's own answer.
    // Two levels, measured rather than assumed: `run_concurrent` answers `Result<Result<T, Error>, Error>` -
    // the concurrent call, then the guest's own answer.
    let description = answer
        .map_err(|error| format!("call:{error}"))?
        .map_err(|error| format!("refused:{error:?}"))?;
    Ok(Description {
        format: description.format,
        duration_ms: description.duration_ms,
        streams: description
            .streams
            .iter()
            .map(|stream| (stream.kind.clone(), stream.codec.clone(), stream.width, stream.height))
            .collect(),
        has_audio: description.has_audio,
    })
}

/// Run `frames.take` and prove every still it answered.
pub async fn frames(
    engine: &Engine,
    component: &Component,
    dirs: &[DirGrant],
    guest_source: &str,
    host_source: &Path,
    moments_ms: &[u64],
    max_pixels: u32,
    guest_out: &str,
) -> Result<Vec<(u64, VerifiedFile)>, String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, dirs)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate_async(&mut store, component, &linker)
        .await
        .map_err(|error| format!("instantiate:{error}"))?;
    let request = exports::wa::media::frames::Request {
        source: wa::media::types::File {
            path: guest_source.to_string(),
            bytes,
            sha256: String::new(),
            mime: String::new(),
        },
        moments: moments_ms
            .iter()
            .map(|at_ms| exports::wa::media::frames::Moment { at_ms: *at_ms, scene: false })
            .collect(),
        max_pixels,
        out_dir: guest_out.to_string(),
    };
    // `run_concurrent` is what lets an async export suspend: the closure gets the store, and the call is a
    // future inside it. Calling through `&mut Store` directly is what wasmtime rejects for an async store.
    let answer = store
        .run_concurrent(async move |store| {
            bindings.wa_media_frames().call_take(store, request).await
        })
        .await
        .map_err(|error| format!("call:{error}"))?;
    let stills = answer
        .map_err(|error| format!("call:{error}"))?
        .map_err(|error| format!("refused:{error:?}"))?;
    {
        {
            let mut verified = Vec::new();
            for still in stills {
                let file = verify_file(&still.image.path, still.image.bytes, &still.image.sha256, dirs)
                    .map_err(|error| error.to_string())?;
                verified.push((still.at_ms, file));
            }
            Ok(verified)
        }
    }
}

/// Run `audio.extract` and prove the track it answered.
pub async fn audio(
    engine: &Engine,
    component: &Component,
    dirs: &[DirGrant],
    guest_source: &str,
    host_source: &Path,
    sample_rate: u32,
    channels: u32,
    guest_out: &str,
) -> Result<(VerifiedFile, u64), String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, dirs)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate_async(&mut store, component, &linker)
        .await
        .map_err(|error| format!("instantiate:{error}"))?;
    let request = exports::wa::media::audio::Request {
        source: wa::media::types::File {
            path: guest_source.to_string(),
            bytes,
            sha256: String::new(),
            mime: String::new(),
        },
        sample_rate,
        channels,
        out_dir: guest_out.to_string(),
    };
    // `run_concurrent` is what lets an async export suspend: the closure gets the store, and the call is a
    // future inside it. Calling through `&mut Store` directly is what wasmtime rejects for an async store.
    let answer = store
        .run_concurrent(async move |store| {
            bindings.wa_media_audio().call_extract(store, request).await
        })
        .await
        .map_err(|error| format!("call:{error}"))?;
    let track = answer
        .map_err(|error| format!("call:{error}"))?
        .map_err(|error| format!("refused:{error:?}"))?;
    let file = verify_file(&track.audio.path, track.audio.bytes, &track.audio.sha256, dirs)
        .map_err(|error| error.to_string())?;
    Ok((file, track.duration_ms))
}


// -----------------------------------------------------------------------------------------------------------
// The capability itself: `wa:kernel/media@0.2.0`, served to a component whose world imports it.
// -----------------------------------------------------------------------------------------------------------

use crate::service_components_v2::State;
use wa_governance::node_telemetry::HostCallGuard;
use wa_grant_policy::Decision;
use wasmtime::component::Accessor;

use kernel_media::wa::kernel::types::Error as KError;

/// The kernel interface has no resource of its own, so its plain `Host` trait is empty - the generated
/// linker still asks for it beside `HostWithStore`, exactly as the websocket and vision bindings do.
impl kernel_media::wa::kernel::media::Host for State {}

/// Ask the node policy before the decoder does anything, the way `vision.read` does. The capability is
/// `media.read` for a probe and `media.write` for the two operations that produce a file - writing is a
/// different question from reading, and an operator may well answer them differently.
fn gate(name: &str, capability: &str) -> Result<(), KError> {
    match wa_governance::node_policy::check(name, capability, None) {
        Decision::Allow => Ok(()),
        Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => Err(KError::Again),
        other => Err(KError::Refused(other.reason_str().to_string())),
    }
}

/// Why a media call could not answer, in the guest's vocabulary.
fn refusal(reason: String) -> KError {
    // A caller that hit the tick budget is told to come back; anything else is this component's own failure
    // and carries the word (`outside_the_grant`, `no_such_grant`, `digest_mismatch`, `refused:...`).
    if reason.contains("interrupt") {
        KError::Again
    } else {
        KError::Failed(reason)
    }
}

/// The engine and the component, loaded once per call through the node's compiled cache: `load` verifies the
/// pin, so the bytes served are the bytes that were installed.
async fn call_probe(dirs: &[crate::components::DirGrant], guest_path: &str, host_path: &std::path::Path)
    -> Result<kernel_media::wa::kernel::media::Description, String>
{
    let engine = crate::service_components_v2::engine().map_err(|error| format!("engine:{error}"))?;
    let component = load(&engine, "media")?;
    let description = probe(&engine, &component, dirs, guest_path, host_path).await?;
    Ok(kernel_media::wa::kernel::media::Description {
        duration_ms: description.duration_ms,
        format: description.format,
        streams: description
            .streams
            .into_iter()
            .map(|(kind, codec, width, height)| kernel_media::wa::kernel::media::MediaStream {
                kind,
                codec,
                width,
                height,
                sample_rate: 0,
                channels: 0,
            })
            .collect(),
        has_audio: description.has_audio,
        elapsed_ms: 0,
    })
}

impl kernel_media::wa::kernel::media::HostWithStore<State> for State {
    /// `probe(path)`: what the container is. Reads only, and writes nothing.
    async fn probe(
        accessor: &Accessor<State, Self>,
        path: String,
    ) -> Result<kernel_media::wa::kernel::media::Description, KError> {
        let name = crate::service_components_v2::who(accessor);
        let mut call = HostCallGuard::start(&name, "media.probe");
        let dirs = accessor.with(|mut access| access.get().dirs.clone());
        let out = async {
            gate(&name, "media.read")?;
            let host_path = host_path_for(&path, &dirs).map_err(|error| refusal(error.to_string()))?;
            call_probe(&dirs, &path, &host_path).await.map_err(refusal)
        }
        .await;
        call.outcome(&out);
        out
    }

    /// `frames(path, moments, max-pixels, out-dir)`: stills written into the granted directory.
    async fn frames(
        accessor: &Accessor<State, Self>,
        path: String,
        moments_ms: Vec<u64>,
        max_pixels: u32,
        out_dir: String,
    ) -> Result<Vec<kernel_media::wa::kernel::media::Still>, KError> {
        let name = crate::service_components_v2::who(accessor);
        let mut call = HostCallGuard::start(&name, "media.frames");
        let dirs = accessor.with(|mut access| access.get().dirs.clone());
        let out = async {
            gate(&name, "media.write")?;
            let host_path = host_path_for(&path, &dirs).map_err(|error| refusal(error.to_string()))?;
            let engine = crate::service_components_v2::engine().map_err(|error| refusal(format!("engine:{error}")))?;
            let component = load(&engine, "media").map_err(refusal)?;
            let stills = frames(&engine, &component, &dirs, &path, &host_path, &moments_ms, max_pixels, &out_dir)
                .await
                .map_err(refusal)?;
            Ok(stills
                .into_iter()
                .map(|(at_ms, file)| kernel_media::wa::kernel::media::Still {
                    at_ms,
                    path: file.host_path.display().to_string(),
                    bytes: file.bytes,
                    sha256: file.sha256,
                })
                .collect())
        }
        .await;
        call.outcome(&out);
        out
    }

    /// `audio(path, sample-rate, channels, out-dir)`: the track as WAV, written into the granted directory.
    async fn audio(
        accessor: &Accessor<State, Self>,
        path: String,
        sample_rate: u32,
        channels: u32,
        out_dir: String,
    ) -> Result<kernel_media::wa::kernel::media::Track, KError> {
        let name = crate::service_components_v2::who(accessor);
        let mut call = HostCallGuard::start(&name, "media.audio");
        let dirs = accessor.with(|mut access| access.get().dirs.clone());
        let out = async {
            gate(&name, "media.write")?;
            let host_path = host_path_for(&path, &dirs).map_err(|error| refusal(error.to_string()))?;
            let engine = crate::service_components_v2::engine().map_err(|error| refusal(format!("engine:{error}")))?;
            let component = load(&engine, "media").map_err(refusal)?;
            let (file, duration_ms) =
                audio(&engine, &component, &dirs, &path, &host_path, sample_rate, channels, &out_dir)
                    .await
                    .map_err(refusal)?;
            Ok(kernel_media::wa::kernel::media::Track {
                path: file.host_path.display().to_string(),
                bytes: file.bytes,
                sha256: file.sha256,
                duration_ms,
                elapsed_ms: 0,
            })
        }
        .await;
        call.outcome(&out);
        out
    }
}

/// A WARNING ABOUT HOW THIS WAS ONCE BLAMED, because the mistake is worth more than the fix.
///
/// Adding this to the 0.2 runner's linker appeared to break seven `service_io::tls_anchor_tests`:
/// `the fixture certificate server.pem: No such file`. It was not this link. Those tests had been compiled
/// minutes earlier in a throwaway `origin/main` worktree under /tmp, and that worktree was deleted while the
/// build cache kept the artifact: `wa-tls` embeds `CARGO_MANIFEST_DIR`, which by then named a directory that no
/// longer existed. Touching `wa-tls/src/scratch.rs` forced a recompile and all nine passed WITH this link in
/// place - the capability was blamed for a stale binary.
///
/// The rule that comes out of it: a comparison run in a temporary worktree contaminates the shared target
/// directory, so either build it with its own CARGO_TARGET_DIR or recompile the crate before believing a
/// regression it seems to show.
///
/// Link `wa:kernel/media` into a service linker. Called by the 0.2 runner only; a component whose world does
/// not import the interface simply never calls it, and one that does gets the capability in its own type -
/// which is the same shape `vision_host::link` has, for the same reason.
pub fn link(linker: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    kernel_media::wa::kernel::media::add_to_linker::<State, State>(linker, |state| state)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The check that matters, and it needs nothing but the filesystem: a component that claims a file it did
    /// not write, or a bigger one, or a different digest, must not be reported as a success.
    #[test]
    fn a_file_outside_the_grant_is_refused_and_a_wrong_digest_is_caught() {
        let out = std::env::temp_dir().join(format!("media-host-{}", std::process::id()));
        std::fs::create_dir_all(&out).expect("temp out dir");
        let path = out.join("still.ppm");
        std::fs::write(&path, b"P6
1 1
255
   ").expect("write");
        let grants = vec![DirGrant { host: out.display().to_string(), guest: "/out".to_string(), write: true }];

        // The honest answer is accepted.
        let digest: String = ring::digest::digest(&ring::digest::SHA256, &std::fs::read(&path).unwrap())
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let verified = verify_file("/out/still.ppm", 14, &digest, &grants).expect("inside the grant");
        assert_eq!(verified.host_path, path);

        // Walking out of the grant, naming no grant, and lying about size or digest are four different refusals.
        assert!(matches!(
            verify_file("/out/../../etc/passwd", 1, "00", &grants),
            Err(Unverified::OutsideTheGrant(_))
        ));
        assert!(matches!(verify_file("/elsewhere/x.ppm", 1, "00", &grants), Err(Unverified::NoSuchGrant(_))));
        assert!(matches!(
            verify_file("/out/still.ppm", 99, &digest, &grants),
            Err(Unverified::SizeMismatch { claimed: 99, found: 14 })
        ));
        assert!(matches!(
            verify_file("/out/still.ppm", 14, "deadbeef", &grants),
            Err(Unverified::DigestMismatch { .. })
        ));
        let _ = std::fs::remove_dir_all(&out);
    }

    /// The end-to-end run, against the installed component and a real file. Skipped (not failed) when this
    /// node has neither, because a test that silently passes on no input is worse than one that says so.
    #[test]
    fn the_installed_component_answers_and_its_files_verify() {
        let Ok(file) = std::env::var("WA_MEDIA_TEST_FILE") else {
            eprintln!("skipped: set WA_MEDIA_TEST_FILE to run this (the component comes from the node's install dir)");
            return;
        };
        let out = std::env::var("WA_MEDIA_TEST_OUT").unwrap_or_else(|_| {
            std::env::temp_dir().join("wa-media-test-out").display().to_string()
        });
        std::fs::create_dir_all(&out).expect("out dir");
        let source = Path::new(&file);
        let dirs = vec![
                DirGrant {
                    host: source.parent().expect("parent").display().to_string(),
                    guest: "/media".to_string(),
                    write: false,
                },
            DirGrant { host: out.clone(), guest: "/out".to_string(), write: true },
        ];
        let engine = crate::service_components_v2::engine().expect("engine");
        // The installed component, pin verified - the same bytes the node would run, not a path from the shell.
        // The REAL installation, addressed explicitly. `load` would read `WA_COMPONENTS_DIR`, and a sibling test
        // rewrites that process-wide (services.rs says so in its own comment); in the full suite this test then
        // failed with `component_not_installed:media` while passing alone. `load_in` is the seam that exists for
        // exactly this, so the test names the directory it means.
        let component = match std::env::var("WA_MEDIA_TEST_COMPONENT") {
            Ok(path) => Component::from_file(&engine, &path).expect("component"),
            Err(_) => {
                let dir = std::path::PathBuf::from(
                    std::env::var("HOME").expect("home") + "/.wasm-agent/components",
                );
                let installed = crate::components::load_in(&dir, "media")
                    .unwrap_or_else(|error| panic!("media installed in {}: {error}", dir.display()));
                crate::service_components_v2::compiled(&engine, &installed.sha256, &installed.bytes)
                    .expect("compile")
            }
        };
        let guest_source = format!("/media/{}", source.file_name().expect("name").to_string_lossy());

        // The entry points are async: the runner drives them on a runtime, and so does this test.
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
        let description = runtime
            .block_on(probe(&engine, &component, &dirs, &guest_source, source))
            .expect("probe");
        assert!(!description.format.is_empty(), "a container has a name");
        assert!(!description.streams.is_empty(), "and at least one stream");

        let stills = runtime
            .block_on(frames(&engine, &component, &dirs, &guest_source, source, &[1000], 640 * 360, "/out"))
            .expect("frames");
        assert_eq!(stills.len(), 1);
        assert_eq!(stills[0].1.bytes, std::fs::metadata(&stills[0].1.host_path).unwrap().len());

        let (track, duration_ms) = runtime
            .block_on(audio(&engine, &component, &dirs, &guest_source, source, 16_000, 1, "/out"))
            .expect("audio");
        assert!(track.bytes > 0);
        assert!(duration_ms > 0, "a track has a length");
        eprintln!(
            "probe: {} {} ms; still {} bytes; audio {} bytes {} ms",
            description.format, description.duration_ms, stills[0].1.bytes, track.bytes, duration_ms
        );
    }
}
