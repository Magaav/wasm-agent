FROM rust:1.98-bookworm AS wa-build
WORKDIR /source
COPY . .
RUN cargo build --release --locked --manifest-path rust/Cargo.toml -p wa-host

FROM node:22-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends git ripgrep python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.87.1
COPY --from=wa-build /source/rust/target/release/wa /usr/local/bin/wa
WORKDIR /work
