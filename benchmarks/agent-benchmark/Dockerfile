FROM rust:1.98-bookworm AS wa-build
WORKDIR /source
COPY . .
RUN cargo build --release --locked --manifest-path rust/Cargo.toml -p wa-host

FROM node:22-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends git ripgrep python3 ca-certificates chromium \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.87.1
COPY --from=wa-build /source/rust/target/release/wa /usr/local/bin/wa
COPY scripts/agent-benchmark-ui-observe.mjs /usr/local/bin/wa-ui-observe
COPY scripts/ui-contract-audit.mjs /usr/local/bin/wa-ui-contracts
RUN chmod +x /usr/local/bin/wa-ui-observe /usr/local/bin/wa-ui-contracts
WORKDIR /work
