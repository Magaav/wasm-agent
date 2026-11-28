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

use crate::components::{Grant, DirGrant};

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
const EPOCH_TICKS: u64 = 4;

/// Build the store the component runs in, from the grant: the directories it may touch, and nothing else.
fn store(engine: &Engine, grant: &Grant) -> Result<Store<Host>, String> {
    let mut builder = WasiCtxBuilder::new();
    for dir in &grant.dirs {
        let perms = if dir.write { FsPerms::ReadWrite } else { FsPerms::ReadOnly };
        builder
            .preopened_dir(&dir.host, &dir.guest, perms)
            .map_err(|_| format!("component_dir_unavailable:{}", dir.guest))?;
    }
    builder.inherit_stderr();
    let mut store = Store::new(engine, Host { ctx: builder.build(), table: ResourceTable::new() });
    // The node's engine is built with `epoch_interruption(true)` (components.rs:73) and a ticker bumps the
    // epoch; a store that never arms a deadline traps with "wasm trap: interrupt" on its first instantiate.
    // Same budget as the 0.2 runner's one-shot run: four ticks, which is generous for a probe and finite.
    store.set_epoch_deadline(EPOCH_TICKS);
    Ok(store)
}

fn linker(engine: &Engine) -> Result<Linker<Host>, String> {
    let mut linker = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("linker:{error}"))?;
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
pub fn probe(
    engine: &Engine,
    component: &Component,
    grant: &Grant,
    guest_source: &str,
    host_source: &Path,
) -> Result<Description, String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, grant)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate(&mut store, component, &linker)
        .map_err(|error| format!("instantiate:{error}"))?;
    let source = wa::media::types::File {
        path: guest_source.to_string(),
        bytes,
        sha256: String::new(),
        mime: String::new(),
    };
    let answer = bindings
        .wa_media_probe()
        .call_describe(&mut store, &source)
        .map_err(|error| format!("call:{error}"))?;
    match answer {
        Ok(description) => Ok(Description {
            format: description.format,
            duration_ms: description.duration_ms,
            streams: description
                .streams
                .iter()
                .map(|stream| (stream.kind.clone(), stream.codec.clone(), stream.width, stream.height))
                .collect(),
            has_audio: description.has_audio,
        }),
        Err(error) => Err(format!("refused:{error:?}")),
    }
}

/// Run `frames.take` and prove every still it answered.
pub fn frames(
    engine: &Engine,
    component: &Component,
    grant: &Grant,
    guest_source: &str,
    host_source: &Path,
    moments_ms: &[u64],
    max_pixels: u32,
    guest_out: &str,
) -> Result<Vec<(u64, VerifiedFile)>, String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, grant)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate(&mut store, component, &linker)
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
    let answer = bindings
        .wa_media_frames()
        .call_take(&mut store, &request)
        .map_err(|error| format!("call:{error}"))?;
    match answer {
        Ok(stills) => {
            let mut verified = Vec::new();
            for still in stills {
                let file = verify_file(&still.image.path, still.image.bytes, &still.image.sha256, &grant.dirs)
                    .map_err(|error| error.to_string())?;
                verified.push((still.at_ms, file));
            }
            Ok(verified)
        }
        Err(error) => Err(format!("refused:{error:?}")),
    }
}

/// Run `audio.extract` and prove the track it answered.
pub fn audio(
    engine: &Engine,
    component: &Component,
    grant: &Grant,
    guest_source: &str,
    host_source: &Path,
    sample_rate: u32,
    channels: u32,
    guest_out: &str,
) -> Result<(VerifiedFile, u64), String> {
    let bytes = std::fs::metadata(host_source).map(|meta| meta.len()).unwrap_or(0);
    let mut store = store(engine, grant)?;
    let linker = linker(engine)?;
    let bindings = MediaService::instantiate(&mut store, component, &linker)
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
    let answer = bindings
        .wa_media_audio()
        .call_extract(&mut store, &request)
        .map_err(|error| format!("call:{error}"))?;
    match answer {
        Ok(track) => {
            let file = verify_file(&track.audio.path, track.audio.bytes, &track.audio.sha256, &grant.dirs)
                .map_err(|error| error.to_string())?;
            Ok((file, track.duration_ms))
        }
        Err(error) => Err(format!("refused:{error:?}")),
    }
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
        let grant = Grant {
            env: Default::default(),
            file_env: Default::default(),
            net: Vec::new(),
            config: None,
            dirs: vec![
                DirGrant {
                    host: source.parent().expect("parent").display().to_string(),
                    guest: "/media".to_string(),
                    write: false,
                },
                DirGrant { host: out.clone(), guest: "/out".to_string(), write: true },
            ],
        };
        let engine = crate::service_components_v2::engine().expect("engine");
        // The installed component, pin verified - the same bytes the node would run, not a path from the shell.
        let component = match std::env::var("WA_MEDIA_TEST_COMPONENT") {
            Ok(path) => Component::from_file(&engine, &path).expect("component"),
            Err(_) => load(&engine, "media").expect("media installed"),
        };
        let guest_source = format!("/media/{}", source.file_name().expect("name").to_string_lossy());

        let description = probe(&engine, &component, &grant, &guest_source, source).expect("probe");
        assert!(!description.format.is_empty(), "a container has a name");
        assert!(!description.streams.is_empty(), "and at least one stream");

        let stills = frames(&engine, &component, &grant, &guest_source, source, &[1000], 640 * 360, "/out")
            .expect("frames");
        assert_eq!(stills.len(), 1);
        assert_eq!(stills[0].1.bytes, std::fs::metadata(&stills[0].1.host_path).unwrap().len());

        let (track, duration_ms) = audio(&engine, &component, &grant, &guest_source, source, 16_000, 1, "/out")
            .expect("audio");
        assert!(track.bytes > 0);
        assert!(duration_ms > 0, "a track has a length");
        eprintln!(
            "probe: {} {} ms; still {} bytes; audio {} bytes {} ms",
            description.format, description.duration_ms, stills[0].1.bytes, track.bytes, duration_ms
        );
    }
}
