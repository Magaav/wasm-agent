# Release notes - the operator's word on a release

`wa release cut` takes the next PATCH number by itself (0.1.0, 0.1.1, 0.1.2 ...). Minor and major numbers never
move on their own: `--minor` / `--major` are refused unless **Victor's quoted instruction** naming the release
that bump produces is written below, between quotes, on a line that also says `Victor` and `minor` or `major`:

    Victor: "0.2.0 is a minor release: ..."

A flag alone never moves it. This file is checked into the tree, so the instruction is reviewed like code.

## Quoted instructions

(none yet)
