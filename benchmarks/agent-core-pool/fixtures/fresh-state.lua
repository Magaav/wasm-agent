-- A pooled instance answers many runs. Every run must start with the globals of a fresh process: the
-- second run of this script in the same instance fails if the first one's global survived.
assert(POOL_LEASE_LEAK == nil, "a pooled run saw a global left by the previous run")
POOL_LEASE_LEAK = true
