//! The media capability's component: ffmpeg's libav* behind `wa:media`.
//!
//! This slice implements `probe` for real - it is the operation the measurement showed costs 8 ms, and the one
//! everything else starts from. `frames` and `audio` answer `again("not implemented in this slice")` instead of
//! pretending: a component that returns a plausible empty answer is worse than one that says it is not done
//! (docs/missions/reports/media-is-a-component.md carries the numbers and the order).
//!
//! The FFI surface is four functions and a handful of accessors in `ffi.rs`; the struct fields are read by the
//! C compiler in `native/ffmpeg_access.c`, so no struct layout is written by eye (ffi.rs says why bindgen could
//! not do it on this node).

#![allow(non_camel_case_types, non_snake_case, dead_code, clippy::all)]

mod ffi;
mod sha256;

wit_bindgen::generate!({
    path: "wit",
    world: "media-service",
});

use std::ffi::{CStr, CString};
use std::time::Instant;

fn failure(code: &str, detail: String) -> wa::media::types::Failure {
    wa::media::types::Failure { code: code.to_string(), detail }
}

/// ffmpeg's negative return codes, as the four-character tag they are made of: `averror(-541478725)` says
/// nothing a person can act on, `averror(EOF)` says the file ended.
fn error_code(value: i32) -> String {
    if value >= 0 {
        return value.to_string();
    }
    let tag = (-value) as u32;
    let bytes = tag.to_be_bytes();
    if bytes.iter().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit()) {
        String::from_utf8_lossy(&bytes).into_owned()
    } else {
        value.to_string()
    }
}

struct Component;

impl exports::wa::media::probe::Guest for Component {
    async fn describe(
        source: wa::media::types::File,
    ) -> Result<exports::wa::media::probe::Description, wa::media::types::Error> {
        let started = Instant::now();
        let path = match CString::new(source.path.clone()) {
            Ok(path) => path,
            Err(_) => {
                return Err(wa::media::types::Error::Failure(failure(
                    "bad_path",
                    "the file path has a NUL in it".to_string(),
                )))
            }
        };
        unsafe {
            let mut context: *mut ffi::AVFormatContext = std::ptr::null_mut();
            let opened = ffi::avformat_open_input(
                &mut context,
                path.as_ptr(),
                std::ptr::null(),
                std::ptr::null_mut(),
            );
            if opened < 0 || context.is_null() {
                return Err(wa::media::types::Error::Failure(failure(
                    "unreadable",
                    format!("the container could not be opened (averror {})", error_code(opened)),
                )));
            }
            let info = ffi::avformat_find_stream_info(context, std::ptr::null_mut());
            if info < 0 {
                ffi::avformat_close_input(&mut context);
                return Err(wa::media::types::Error::Failure(failure(
                    "unreadable",
                    format!("the streams could not be read (averror {})", error_code(info)),
                )));
            }

            let mut streams = Vec::new();
            let mut has_audio = false;
            let count = ffi::wa_stream_count(context) as u32;
            for index in 0..count {
                let kind = match ffi::wa_stream_kind(context, index) {
                    ffi::KIND_VIDEO => "video",
                    ffi::KIND_AUDIO => "audio",
                    ffi::KIND_SUBTITLE => "subtitle",
                    _ => continue,
                };
                if kind == "audio" {
                    has_audio = true;
                }
                let codec = ffi::wa_stream_codec(context, index);
                let codec = if codec.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(codec).to_string_lossy().into_owned()
                };
                streams.push(exports::wa::media::probe::MediaStream {
                    kind: kind.to_string(),
                    codec,
                    width: ffi::wa_stream_width(context, index).max(0) as u32,
                    height: ffi::wa_stream_height(context, index).max(0) as u32,
                    // 0 is "not read", not "zero": these two are only used by `audio`, which is not in this
                    // slice, and a made-up number would be worse than an absent one.
                    sample_rate: 0,
                    channels: 0,
                });
            }

            // The demuxer's own name: `AVInputFormat.name` is a comma list of aliases, and the first is the one
            // a person recognises.
            let name = ffi::wa_format_name(context);
            let format = if name.is_null() {
                String::new()
            } else {
                CStr::from_ptr(name).to_string_lossy().split(',').next().unwrap_or_default().to_string()
            };
            let duration_us = ffi::wa_duration_us(context);
            let duration_ms = if duration_us > 0 { (duration_us / 1000) as u64 } else { 0 };
            ffi::avformat_close_input(&mut context);

            Ok(exports::wa::media::probe::Description {
                duration_ms,
                size_bytes: source.bytes,
                streams,
                format,
                has_audio,
                elapsed_ms: started.elapsed().as_millis() as u64,
            })
        }
    }
}

impl exports::wa::media::frames::Guest for Component {
    async fn take(
        request: exports::wa::media::frames::Request,
    ) -> Result<Vec<exports::wa::media::frames::Still>, wa::media::types::Error> {
        let source = CString::new(request.source.path.clone()).map_err(|_| {
            wa::media::types::Error::Failure(failure(
                "bad_path",
                "the file path has a NUL in it".to_string(),
            ))
        })?;
        // No `out-dir` is not "write somewhere sensible": a component writes where it was granted, and a
        // request that names no grant is answered rather than guessed.
        if request.out_dir.is_empty() {
            return Err(wa::media::types::Error::Failure(failure(
                "no_out_dir",
                "the request names no out-dir; the host grants the directory the stills go in".to_string(),
            )));
        }
        let mut stills = Vec::new();
        for moment in &request.moments {
            let mut out_path = format!(
                "{}/still-{}.ppm",
                request.out_dir.trim_end_matches('/'),
                moment.at_ms
            );
            if request.out_dir == "/" {
                out_path = format!("/still-{}.ppm", moment.at_ms);
            }
            let out = CString::new(out_path.clone()).map_err(|_| {
                wa::media::types::Error::Failure(failure("bad_path", "the destination has a NUL".to_string()))
            })?;
            let status = unsafe {
                ffi::wa_write_frame(
                    source.as_ptr(),
                    moment.at_ms as i64,
                    request.max_pixels as i32,
                    out.as_ptr(),
                )
            };
            if status < 0 {
                return Err(wa::media::types::Error::Failure(failure(
                    "frame_failed",
                    format!(
                        "no frame at {} ms could be written (averror {})",
                        moment.at_ms,
                        error_code(status)
                    ),
                )));
            }
            // The digest and the size are of the file that is actually on disk, not of what was intended:
            // the host recomputes both, and a component that reports its own intention would hide the very
            // disagreement this check exists to catch.
            let bytes = std::fs::read(&out_path).map_err(|error| {
                wa::media::types::Error::Failure(failure(
                    "write_lost",
                    format!("the still was written but cannot be read back: {error}"),
                ))
            })?;
            stills.push(exports::wa::media::frames::Still {
                at_ms: moment.at_ms,
                image: wa::media::types::File {
                    path: out_path,
                    bytes: bytes.len() as u64,
                    sha256: sha256::hex(&bytes),
                    mime: "image/x-portable-pixmap".to_string(),
                },
            });
        }
        Ok(stills)
    }
}

impl exports::wa::media::audio::Guest for Component {
    async fn extract(
        request: exports::wa::media::audio::Request,
    ) -> Result<exports::wa::media::audio::Track, wa::media::types::Error> {
        let started = Instant::now();
        let source = CString::new(request.source.path.clone()).map_err(|_| {
            wa::media::types::Error::Failure(failure(
                "bad_path",
                "the file path has a NUL in it".to_string(),
            ))
        })?;
        if request.out_dir.is_empty() {
            return Err(wa::media::types::Error::Failure(failure(
                "no_out_dir",
                "the request names no out-dir; the host grants the directory the track goes in".to_string(),
            )));
        }
        if request.sample_rate == 0 || request.channels == 0 {
            return Err(wa::media::types::Error::Failure(failure(
                "bad_audio_shape",
                format!(
                    "a track needs a sample rate and a channel count (asked for {} Hz, {} channels)",
                    request.sample_rate, request.channels
                ),
            )));
        }
        let out_path = format!(
            "{}/track-{}Hz-{}ch.wav",
            request.out_dir.trim_end_matches('/'),
            request.sample_rate,
            request.channels
        );
        let out = CString::new(out_path.clone()).map_err(|_| {
            wa::media::types::Error::Failure(failure("bad_path", "the destination has a NUL".to_string()))
        })?;
        let mut samples: i64 = 0;
        let status = unsafe {
            ffi::wa_write_audio(
                source.as_ptr(),
                request.sample_rate as i32,
                request.channels as i32,
                out.as_ptr(),
                &mut samples,
            )
        };
        if status < 0 {
            return Err(wa::media::types::Error::Failure(failure(
                "audio_failed",
                format!("the audio track could not be written (averror {})", error_code(status)),
            )));
        }
        // Read back what is on disk: the size and digest are the host's to check, and reporting an intention
        // instead of the file would hide the disagreement that check exists for.
        let bytes = std::fs::read(&out_path).map_err(|error| {
            wa::media::types::Error::Failure(failure(
                "write_lost",
                format!("the track was written but cannot be read back: {error}"),
            ))
        })?;
        let duration_ms = if request.sample_rate > 0 {
            (samples.max(0) as u64 * 1000) / request.sample_rate as u64
        } else {
            0
        };
        Ok(exports::wa::media::audio::Track {
            audio: wa::media::types::File {
                path: out_path,
                bytes: bytes.len() as u64,
                sha256: sha256::hex(&bytes),
                mime: "audio/wav".to_string(),
            },
            duration_ms,
            elapsed_ms: started.elapsed().as_millis() as u64,
        })
    }
}

export!(Component);
