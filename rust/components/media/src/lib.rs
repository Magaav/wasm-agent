//! The media capability's component: ffmpeg's libav* behind `wa:media`.
//!
//! This slice implements `probe` for real - it is the operation the measurement showed costs 8 ms, and the
//! one everything else starts from. `frames` and `audio` answer `again("not implemented in this slice")`
//! instead of pretending: a component that returns a plausible empty answer is worse than one that says it
//! is not done (docs/missions/reports/media-is-a-component.md carries the numbers and the order).
//!
//! The bindings are GENERATED from the vendored headers by `build.rs` (bindgen + the wasi-sdk's libclang),
//! so no FFI struct here is written by eye.

#![allow(non_camel_case_types, non_snake_case, dead_code, clippy::all)]

mod ffi {
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

wit_bindgen::generate!({
    path: "wit",
    world: "media-service",
});

use std::ffi::{CStr, CString};
use std::time::Instant;

struct Component;

fn failure(code: &str, detail: String) -> exports::wa::media::types::Failure {
    exports::wa::media::types::Failure { code: code.to_string(), detail }
}

fn error_code(code: &str) -> i32 {
    // `AVERROR_*` are negative errno-style codes; the message is the library's own.
    code & 0x7fff_ffff
}

impl exports::wa::media::probe::Guest for Component {
    fn describe(
        source: exports::wa::media::types::File,
    ) -> Result<exports::wa::media::probe::Description, exports::wa::media::types::Error> {
        let started = Instant::now();
        let path = match CString::new(source.path.clone()) {
            Ok(path) => path,
            Err(_) => {
                return Err(exports::wa::media::types::Error::Failure(failure(
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
                return Err(exports::wa::media::types::Error::Failure(failure(
                    "unreadable",
                    format!("the container could not be opened (averror {})", error_code(opened)),
                )));
            }
            let info = ffi::avformat_find_stream_info(context, std::ptr::null_mut());
            if info < 0 {
                ffi::avformat_close_input(&mut context);
                return Err(exports::wa::media::types::Error::Failure(failure(
                    "unreadable",
                    format!("the streams could not be read (averror {})", error_code(info)),
                )));
            }

            let mut streams = Vec::new();
            let mut has_audio = false;
            let count = (*context).nb_streams as usize;
            for index in 0..count {
                let stream = *(*context).streams.add(index);
                if stream.is_null() {
                    continue;
                }
                let params = (*stream).codecpar;
                if params.is_null() {
                    continue;
                }
                let kind = match (*params).codec_type {
                    ffi::AVMediaType_AVMEDIA_TYPE_VIDEO => "video",
                    ffi::AVMediaType_AVMEDIA_TYPE_AUDIO => "audio",
                    ffi::AVMediaType_AVMEDIA_TYPE_SUBTITLE => "subtitle",
                    _ => continue,
                };
                if kind == "audio" {
                    has_audio = true;
                }
                let codec = ffi::avcodec_get_name((*params).codec_id);
                let codec = if codec.is_null() { String::new() } else { CStr::from_ptr(codec).to_string_lossy().into_owned() };
                streams.push(exports::wa::media::probe::Stream {
                    kind: kind.to_string(),
                    codec,
                    width: (*params).width.max(0) as u32,
                    height: (*params).height.max(0) as u32,
                    sample_rate: (*params).sample_rate.max(0) as u32,
                    channels: (*params).ch_layout.nb_channels.max(0) as u32,
                });
            }

            // The format's own name, when the demuxer has one: `AVInputFormat.name` is a comma list of its
            // aliases and the first is the one a person recognises.
            let format = if (*context).iformat.is_null() {
                String::new()
            } else {
                let name = (*(*context).iformat).name;
                if name.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(name).to_string_lossy().split(',').next().unwrap_or_default().to_string()
                }
            };
            let duration_ms = if (*context).duration > 0 {
                ((*context).duration / 1000) as u64
            } else {
                0
            };
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
    ) -> Result<Vec<exports::wa::media::frames::Still>, exports::wa::media::types::Error> {
        Err(exports::wa::media::types::Error::Again(
            "frames is not implemented in this slice: the stills are PPM until the JPEG encoder question is answered (docs/missions/reports/media-is-a-component.md)".to_string(),
        ))
    }
}

impl exports::wa::media::audio::Guest for Component {
    fn extract(
        _request: exports::wa::media::audio::Request,
    ) -> Result<exports::wa::media::audio::Track, exports::wa::media::types::Error> {
        Err(exports::wa::media::types::Error::Again(
            "audio is not implemented in this slice; its measurement is in the report and it is the next operation to wire".to_string(),
        ))
    }
}

export!(Component with: exports::wa::media::probe, exports::wa::media::frames, exports::wa::media::audio);
