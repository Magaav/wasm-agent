//! The ffmpeg surface this component calls.
//!
//! WHY THESE ARE WRITTEN BY HAND. The declarations were to be generated from the vendored headers, and on this
//! node they cannot be: bindgen 0.70.1 with the wasi-sdk's libclang 23 emits the AV* types and no extern
//! functions at all (measured on a two-line header), and its ABI assertion fires with 4 != 8 because that
//! libclang defaults to a wasm target while the build host is 64-bit. No other libclang is installed.
//!
//! What that costs is a hand-written list of FOUR functions and a handful of accessors - all of them checked by
//! the LINKER (a misspelt or missing symbol fails the build), and none of them requiring a struct layout. The
//! struct fields are read in `native/ffmpeg_access.c`, by the C compiler that already knows them: this module
//! only ever holds an opaque pointer. That is the part a hand-written binding usually gets wrong, and here it
//! is not written at all.

use std::os::raw::{c_char, c_int, c_uint};

/// Opaque: the component never dereferences these, it passes them back to ffmpeg and to the accessors below.
#[repr(C)]
pub struct AVFormatContext {
    _private: [u8; 0],
}

pub const AVERROR_EOF: c_int = -541_478_725; // "EOF" as fourcc, ffmpeg's own value for end of file

/// The kinds the contract carries, as `native/ffmpeg_access.h` reports them.
pub const KIND_VIDEO: c_int = 0;
pub const KIND_AUDIO: c_int = 1;
pub const KIND_SUBTITLE: c_int = 3;
pub const KIND_OTHER: c_int = 4;

extern "C" {
    pub fn avformat_open_input(
        context: *mut *mut AVFormatContext,
        url: *const c_char,
        format: *const std::ffi::c_void,
        options: *mut *mut std::ffi::c_void,
    ) -> c_int;
    pub fn avformat_find_stream_info(
        context: *mut AVFormatContext,
        options: *mut *mut std::ffi::c_void,
    ) -> c_int;
    pub fn avformat_close_input(context: *mut *mut AVFormatContext);

    pub fn wa_stream_count(context: *mut AVFormatContext) -> c_uint;
    pub fn wa_stream_kind(context: *mut AVFormatContext, index: c_uint) -> c_int;
    pub fn wa_stream_codec(context: *mut AVFormatContext, index: c_uint) -> *const c_char;
    pub fn wa_stream_width(context: *mut AVFormatContext, index: c_uint) -> c_int;
    pub fn wa_stream_height(context: *mut AVFormatContext, index: c_uint) -> c_int;
    pub fn wa_format_name(context: *mut AVFormatContext) -> *const c_char;
    pub fn wa_duration_us(context: *mut AVFormatContext) -> i64;

    /// Seek, decode, scale and encode ONE still to `out_path` (native/ffmpeg_frames.c).
    pub fn wa_write_frame(
        path: *const c_char,
        moment_ms: i64,
        max_pixels: c_int,
        out_path: *const c_char,
    ) -> c_int;

    /// Decode the audio track and write it as WAV at `sample_rate`/`channels`
    /// (native/ffmpeg_audio.c); `samples_out` receives the frames written.
    pub fn wa_write_audio(
        path: *const c_char,
        sample_rate: c_int,
        channels: c_int,
        out_path: *const c_char,
        samples_out: *mut i64,
    ) -> c_int;
}
