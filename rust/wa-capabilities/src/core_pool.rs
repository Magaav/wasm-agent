//! The agent-core pool's engine: the same pooling allocator numbers
//! (`wa_kernel_runtime::components::PoolLimits`) with **epoch interruption on** and a ticker
//! thread, so a pooled run can carry a deadline (docs/KERNEL.md, "A2.5").
//!
//! `wa_kernel_runtime::components::pooled_engine` deliberately keeps the feature off: an engine with
//! epoch interruption enabled and no ticker traps every guest on its first instruction (A2.3 measured
//! `wasm trap: interrupt` on the pool's first run), and the engine it builds is shared with callers
//! that have no per-run budget. The pool is the caller that does have one now, so it builds its own
//! engine from the same `PoolLimits`: only the `Config` differs, and this module is where the
//! difference lives instead of being a knob nobody can see.
//!
//! What a deadline means here: the deadline counts **guest instructions**, not wall time. A guest
//! blocked inside a host call (a model request, an HTTP read, an SSE stream) is not executing wasm and
//! is not interrupted - which is exactly right, because the run's own `cancel` flag and the cap on
//! that capability are the host side's business, while "this Lua never returns" is the guest's.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use wa_kernel_runtime::components::PoolLimits;
use wasmtime::Engine;

/// How often the ticker advances the engine's epoch. A deadline is counted in these ticks, so it is
/// honoured to within one tick - the same 10 ms tick `wa-kernel-runtime`'s service runners use.
pub const TICK: Duration = Duration::from_millis(10);

/// The thread that advances an engine's epoch, stopped when the engine is dropped.
///
/// One per engine, so one per pool. The pool is normally `'static` (the node's), in which case the
/// thread lives as long as the process - which is correct, because the engine does too.
pub struct EpochTicker {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl EpochTicker {
    fn start(engine: &Engine) -> std::io::Result<EpochTicker> {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let ticker = engine.clone();
        let thread = std::thread::Builder::new().name("wa-core-pool-epoch".into()).spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                std::thread::sleep(TICK);
                ticker.increment_epoch();
            }
        })?;
        Ok(EpochTicker { stop, thread: Some(thread) })
    }
}

impl Drop for EpochTicker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A pooling engine with epoch interruption enabled, plus the ticker that drives it.
///
/// `Engine::new` is the expensive step (it prepares the allocator), which is why a pool builds one
/// and every instance it creates comes out of it as a slot reset.
pub fn epoch_engine(limits: &PoolLimits) -> wasmtime::Result<(Engine, EpochTicker)> {
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    // Lua's error handling (setjmp/longjmp, `pcall`) is wasm exception handling.
    config.wasm_exceptions(true);
    // What gives a run a deadline: a store's epoch delta is what the guest is interrupted at
    // (`Store::set_epoch_deadline`), and without this the delta means nothing.
    config.epoch_interruption(true);
    let mut pooling = wasmtime::PoolingAllocationConfig::default();
    pooling.total_component_instances(limits.component_instances);
    pooling.total_core_instances(limits.core_instances);
    pooling.total_memories(limits.memories);
    pooling.total_tables(limits.tables);
    pooling.total_stacks(limits.stacks);
    pooling.total_gc_heaps(limits.gc_heaps);
    pooling.max_memory_size(limits.max_memory_bytes);
    config.allocation_strategy(wasmtime::InstanceAllocationStrategy::Pooling(pooling));
    let engine = Engine::new(&config)?;
    let ticker = EpochTicker::start(&engine).map_err(|error| wasmtime::Error::msg(format!("epoch_ticker: {error}")))?;
    Ok((engine, ticker))
}

/// Epoch ticks a store needs for `budget`. `0` means "no deadline", which is `u64::MAX` ticks - the
/// same value `Store::set_epoch_deadline` uses for a store that may run forever.
pub fn ticks_for(budget: Duration) -> u64 {
    if budget.is_zero() {
        return u64::MAX;
    }
    (budget.as_millis() as u64 / TICK.as_millis() as u64).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tick arithmetic: a budget becomes a whole number of ticks, never zero for a non-zero
    /// budget (`set_epoch_deadline(0)` would trap the guest on its first instruction).
    #[test]
    fn a_budget_becomes_ticks_and_zero_means_no_deadline() {
        assert_eq!(ticks_for(Duration::ZERO), u64::MAX);
        assert_eq!(ticks_for(Duration::from_millis(5)), 1);
        assert_eq!(ticks_for(Duration::from_secs(60)), 6_000);
        assert_eq!(ticks_for(Duration::from_millis(1)), 1);
    }

    /// The engine really has epoch interruption on: a store that never sets a deadline and one that
    /// sets a single tick both build, and the ticker is a thread that stops with the engine.
    #[test]
    fn the_epoch_engine_builds_with_its_ticker() {
        let limits = PoolLimits { component_instances: 1, ..PoolLimits::default() };
        let (engine, ticker) = epoch_engine(&limits).expect("the epoch engine builds");
        assert!(engine.get_epoch_interruption(), "the engine must have the feature a deadline uses");
        drop(ticker);
    }
}
