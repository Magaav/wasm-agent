//! Fixture for `wa:kernel/media@0.2.0` - the ffmpeg capability.
//!
//! WHAT IT PROVES, in its own log (a test reads these lines; it does not trust a return value):
//!   * `media probe=<format> <duration>ms streams=<n>` - the capability reached ffmpeg through the kernel, on a
//!     path the grant allowed, and answered with what the container actually is.
//!   * `media stills=<n> bytes=<sum>` - the stills were written into the granted out-dir and the sizes the guest
//!     was told are the sizes the kernel recomputed from disk.
//!   * `media audio bytes=<n> ms=<n>` - the track exists and has a length.
//!   * `media refused=<reason>` - a path that walks out of the grant is refused rather than resolved, which is
//!     the half of the contract a green happy path says nothing about.
//!
//! The guest never sees media bytes: every answer is a path, a size and a digest.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-media", generate_all });

use wa::kernel::{lifecycle, log, media};

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "svc-media", text);
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(_config: String) -> Result<(), String> {
        // The runner grants this fixture two directories: `/in` (read-only, holding the clip) and `/out`
        // (writable, where the stills and the track go). The names are the test's, not the component's.
        match media::probe("/in/clip.mp4".to_string()).await {
            Ok(description) => {
                line(&format!(
                    "media probe={} {}ms streams={}",
                    description.format,
                    description.duration_ms,
                    description.streams.len()
                ));
                match media::frames("/in/clip.mp4".to_string(), vec![1000, 5000], 640 * 360, "/out".to_string()).await {
                    Ok(stills) => {
                        let bytes: u64 = stills.iter().map(|still| still.bytes).sum();
                        line(&format!("media stills={} bytes={bytes}", stills.len()));
                    }
                    Err(error) => line(&format!("media stills-error={error:?}")),
                }
                match media::audio("/in/clip.mp4".to_string(), 16_000, 1, "/out".to_string()).await {
                    Ok(track) => line(&format!("media audio bytes={} ms={}", track.bytes, track.duration_ms)),
                    Err(error) => line(&format!("media audio-error={error:?}")),
                }
            }
            Err(error) => line(&format!("media probe-error={error:?}")),
        }

        // The refusal: a path that walks out of the grant must not be resolved.
        match media::probe("/in/../../../etc/passwd".to_string()).await {
            Ok(_) => line("media refused=NOT-REFUSED"),
            Err(error) => line(&format!("media refused={error:?}")),
        }

        lifecycle::report(lifecycle::Health::Ready, None);
        Ok(())
    }
}

export!(Service);
