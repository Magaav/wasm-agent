//! The watchdog: the process outside the kernel (docs/KERNEL.md, "three layers").
//!
//! It starts the kernel, restarts it on a crash with exponential backoff, and replaces the kernel binary only
//! after the new bytes have answered `/health` - keeping the previous binary on disk so a rollback is a path
//! change and a restart, never a rebuild.
//!
//! The crate has zero dependencies, deliberately: a supervisor that shares a dependency graph with the thing
//! it supervises can be broken by that thing's build. The modules below are what that costs - a SHA-256, a
//! loopback HTTP GET, and a JSON writer/field reader - and it is a cost paid once.

pub mod backoff;
pub mod config;
pub mod hash;
pub mod health;
pub mod json;
pub mod paths;
pub mod proc;
pub mod selftest;
pub mod state;
pub mod supervisor;
pub mod swap;
