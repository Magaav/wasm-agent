// Fixture subprocesses inherit OS launch essentials and unchanged safety/provenance
// markers, never arbitrary caller credentials/configuration. HOME/data are private.
export function isolatedEnvironment(home,extra={}) {
  const allowed=new Set(['PATH','PATHEXT','SYSTEMROOT','WINDIR','COMSPEC','TEMP','TMP','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS','LANG','WASM_AGENT_PROVENANCE','WASM_AGENT_IN_TURN','WASM_AGENT_RUN_ID','WASM_AGENT_SESSION_ID','WA_RUN_ID','WA_SESSION_ID','WA_TOOL_INVOCATION']);
  const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>allowed.has(k.toUpperCase())));
  const protectedMarkers=Object.fromEntries(Object.entries(env).filter(([k])=>/^(WASM_AGENT_(?:PROVENANCE|IN_TURN|RUN_ID|SESSION_ID)|WA_(?:RUN_ID|SESSION_ID|TOOL_INVOCATION))$/i.test(k)));
  return {...env,HOME:home,USERPROFILE:home,WASM_AGENT_HOME:home,...extra,...protectedMarkers};
}
