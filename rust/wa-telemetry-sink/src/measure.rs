//! Resident-set measurement without a dependency, for the optimization check the job asks for.
//!
//! This is a *measurement* module, not a policy: nothing in the sink's runtime path calls it. It
//! exists so "the sink costs this much memory" is a number taken from the process rather than a
//! number a comment claims. Windows uses `K32GetProcessMemoryInfo`, Linux reads `/proc/self/statm`,
//! and any other platform answers `None` instead of inventing a figure.
#![allow(unused_variables)]

/// Resident bytes of this process, or `None` where it cannot be read.
#[cfg(windows)]
pub fn rss_bytes() -> Option<u64> {
    use std::ffi::c_void;
    // PROCESS_MEMORY_COUNTERS from psapi.h, in declaration order.
    #[repr(C)]
    #[derive(Default)]
    struct ProcessMemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn K32GetProcessMemoryInfo(
            process: *mut c_void,
            counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> i32;
    }

    let mut counters = ProcessMemoryCounters {
        cb: std::mem::size_of::<ProcessMemoryCounters>() as u32,
        ..ProcessMemoryCounters::default()
    };
    // SAFETY: the handle is the current process and the struct is sized in `cb`, which is the whole
    // contract of K32GetProcessMemoryInfo.
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) };
    if ok == 0 {
        None
    } else {
        Some(counters.working_set_size as u64)
    }
}

#[cfg(target_os = "linux")]
pub fn rss_bytes() -> Option<u64> {
    // statm: size resident shared text lib data dt (pages). Field 2 is resident pages.
    let text = std::fs::read_to_string("/proc/self/statm").ok()?;
    let resident = text.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(resident * 4096)
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn rss_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rss_is_readable_here_and_grows_with_an_allocation() {
        let Some(before) = rss_bytes() else {
            // A platform without a reader: report that it was skipped rather than pretend.
            eprintln!("rss unavailable on this platform: measurement skipped");
            return;
        };
        assert!(before > 0);
        let ballast = vec![0u8; 64 << 20];
        let after = rss_bytes().expect("rss");
        assert!(after >= before, "rss went backwards: {before} -> {after}");
        std::hint::black_box(&ballast);
        drop(ballast);
    }
}
