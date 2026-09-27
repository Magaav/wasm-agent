//! Small, dependency-free host resource sample for the fabric heartbeat.
//!
//! Values are capacities, not promises: admission still belongs to the scheduler.

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

fn percent(used: u64, total: u64) -> Option<f64> {
    (total > 0).then(|| ((used as f64 / total as f64) * 1000.0).round() / 10.0)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn cpu_ticks() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    let fields: Vec<u64> = text.lines().next()?.split_whitespace().skip(1)
        .filter_map(|value| value.parse().ok()).collect();
    if fields.len() < 4 { return None; }
    let total = fields.iter().sum();
    let idle = fields[3] + fields.get(4).copied().unwrap_or(0);
    Some((idle, total))
}

#[cfg(windows)]
fn cpu_ticks() -> Option<(u64, u64)> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetSystemTimes;
    fn value(v: FILETIME) -> u64 { ((v.dwHighDateTime as u64) << 32) | v.dwLowDateTime as u64 }
    unsafe {
        let (mut idle, mut kernel, mut user) = (std::mem::zeroed(), std::mem::zeroed(), std::mem::zeroed());
        if GetSystemTimes(&mut idle, &mut kernel, &mut user) == 0 { return None; }
        Some((value(idle), value(kernel) + value(user)))
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", windows)))]
fn cpu_ticks() -> Option<(u64, u64)> { None }

fn cpu_percent() -> Option<f64> {
    let first = cpu_ticks()?;
    std::thread::sleep(Duration::from_millis(120));
    let second = cpu_ticks()?;
    let total = second.1.saturating_sub(first.1);
    let idle = second.0.saturating_sub(first.0);
    percent(total.saturating_sub(idle), total)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn memory() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let mut total = None;
    let mut available = None;
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        match parts.next()? {
            "MemTotal:" => total = parts.next()?.parse::<u64>().ok().map(|value| value * 1024),
            "MemAvailable:" => available = parts.next()?.parse::<u64>().ok().map(|value| value * 1024),
            _ => {}
        }
    }
    Some((available?, total?))
}

#[cfg(windows)]
fn memory() -> Option<(u64, u64)> {
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    unsafe {
        let mut status: MEMORYSTATUSEX = std::mem::zeroed();
        status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(&mut status) == 0 { return None; }
        Some((status.ullAvailPhys, status.ullTotalPhys))
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", windows)))]
fn memory() -> Option<(u64, u64)> { None }

#[cfg(unix)]
fn disk(path: &Path) -> Option<(u64, u64)> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(path.as_ptr(), &mut stat) != 0 { return None; }
        let unit = stat.f_frsize as u64;
        Some(((stat.f_bavail as u64).saturating_mul(unit), (stat.f_blocks as u64).saturating_mul(unit)))
    }
}

#[cfg(windows)]
fn disk(path: &Path) -> Option<(u64, u64)> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        let (mut available, mut total, mut free) = (0u64, 0u64, 0u64);
        if GetDiskFreeSpaceExW(wide.as_ptr(), &mut available, &mut total, &mut free) == 0 { return None; }
        Some((available, total))
    }
}

pub fn sample() -> Value {
    let memory = memory();
    let disk = std::env::current_dir().ok().and_then(|path| disk(&path));
    json!({
        "sampled_at": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs()).unwrap_or(0),
        "cpu": { "used_percent": cpu_percent(), "logical_cores": std::thread::available_parallelism().ok().map(|value| value.get()) },
        "memory": memory.map(|(available, total)| json!({
            "available_bytes": available, "total_bytes": total,
            "used_percent": percent(total.saturating_sub(available), total),
        })),
        "disk": disk.map(|(available, total)| json!({
            "available_bytes": available, "total_bytes": total,
            "used_percent": percent(total.saturating_sub(available), total),
        })),
    })
}
