const fs=require('fs');
let block=fs.readFileSync('.cap-evidence/block.txt','utf8');
block=block.replace('; One line per capability, . Hand-maintained', '; One line per capability: name, then effect class. Hand-maintained');
const prose=`## The capability inventory

What this node can do is **data**, not prose. The live registry is
\`rust/wa-host/src/capabilities.rs\`, and the interpreter is booted from it: a \`host.*\` function
that is not in that list cannot be called, and one that is in it is a row below. Each entry
carries a name, a one-line description and an effect class (\`read-only\`, \`writes files\`,
\`runs a process\`, \`network\`, \`device\`), stably ordered by name so two nodes can be diffed.

Four surfaces read the same registry, which is why none of them can disagree with what is
actually registered:

| surface | what it answers |
| --- | --- |
| \`wa capabilities [--json]\` | the whole list, with descriptions; \`--json\` is the exact text whose sha256 \`/health\` publishes |
| \`GET /health\` -> \`capabilities\` | \`{count, names, sha256}\` - names and the digest of the list, never the descriptions, because that endpoint is polled |
| sandbox \`capabilities()\` | the same array, inside a codemode workflow |
| sandbox \`describe("exec")\` | one entry by exact name |

That digest is what makes drift visible from outside the process: two nodes agree iff their
\`sha256\` agrees, and a watcher that already polls \`/health\` learns that the inventory changed
without downloading it.

The table below is hand-maintained **on purpose**: a test makes it agree with the registry, so a
capability that is registered but undocumented, documented but absent, or documented with the
wrong effect class fails \`cargo test -p wa-host capabilities\` with the exact names. A generated
block would only prove that the generator ran.

Adding a capability is two edits: one entry in the registry, one row here.

`;
fs.writeFileSync('.cap-evidence/section.txt', prose+block);
console.log('section bytes', prose.length+block.length);
