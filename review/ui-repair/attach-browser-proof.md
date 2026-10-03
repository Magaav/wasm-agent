# Narrow production browser attachment proof

Normal test-ui harness invokes actual refreshAgentPane and syncLiveRun, authenticated fetch transport fixture for same conversation/exact key 9007199254740993 (legacy rounded run_id deliberately present). Two saved rows, durable reasoning/delta/tool events. Both actual renderers show live delta and saved answer; outgoing run-events preserves exact key and conversation. Pane ledger supplier is injected; this is browser production-render/transport proof, not real listener history paging proof.

Positive normal ui-browser op-1791028638426537-15512-247 exit0, log Temp/wa-checks-Ujut3D/ui-browser.log. One-effect rollback disables only child replay event application: op-1791028656643108-15512-259 exit1 at intended 'shared attach: child must render durable high-ID live tail', log Temp/wa-checks-3as31s/ui-browser.log. Production bytes restored before final runs.

Not proven here: real reload/drop, advancing checkpoint/cursors, multi-pane concurrent exact-once ordering, terminal fallback, epoch switch negatives. Existing main restore remains separate controller sharing journal transport, not an identical attach controller. Those remain original acceptance work; do not treat this narrow result as completed shared continuity.
