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
    fn describe(
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
    fn take(
        _request: exports::wa::media::frames::Request,
    ) -> Result<Vec<exports::wa::media::frames::Still>, wa::media::types::Error> {
        Err(wa::media::types::Error::Again(
            "frames is not implemented in this slice: the stills are PPM until the JPEG encoder question is answered (docs/missions/reports/media-is-a-component.md)".to_string(),
        ))
    }
}

impl exports::wa::media::audio::Guest for Component {
    fn extract(
        _request: exports::wa::media::audio::Request,
    ) -> Result<exports::wa::media::audio::Track, wa::media::types::Error> {
        Err(wa::media::types::Error::Again(
            "audio is not implemented in this slice; its measurement is in the report and it is the next operation to wire".to_string(),
        ))
    }
}

export!(Component);
