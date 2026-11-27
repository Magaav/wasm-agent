//! The mesh (docs/MESH.md): the direct peer call, and the component's decisions seam. The handlers
//! are in wa_mesh and wa_kernel_runtime::mesh_host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("mesh_call", Network, wa_mesh::host_call::mesh_call, "Call a peer directly by hierarchy, when WA_MESH=1; the roster, grants and direct transport of docs/MESH.md"),
    // The mesh seam (docs/MESH.md, docs/CORE-SPLIT.md "mesh/fleet"): the `mesh` component answers the
    // fleet's *decisions* — the roster's verify, the hierarchy and the grants, the audit line, the
    // attestation's bytes and check, the peer-address rule — over no grant at all (its world imports
    // nothing). `wa-mesh` routes its own call path here when `WA_MESH_COMPONENT=1`; this capability is
    // the same answers for a caller outside that path (a CLI verb, a Lua check, `scripts/test-mesh-component.lua`),
    // and it is inert on a node that never opts in because the artifact is simply not installed.
    plain!("mesh", ReadOnly, wa_kernel_runtime::mesh_host::capability, "One wa:mesh call against the installed mesh component: verify-roster, decide, verb, render-audit, attest-message, verify-ticket or addresses - the fleet's decisions, with the sockets and the node's key left in the kernel"),
];
