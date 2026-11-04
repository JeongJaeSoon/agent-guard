# syntax=docker/dockerfile:1
FROM rust:1.85.1-slim-bookworm@sha256:9f841bbe9e7d8e37ceb96ed907265a3a0df7f44e3737d0b100e7907a679acb36
# Shared runtime: identical jq, shell and scanner for both candidates.
RUN --mount=type=secret,id=proxy_ca,required=true \
    apt-get -o Acquire::https::CaInfo=/run/secrets/proxy_ca update && \
    apt-get -o Acquire::https::CaInfo=/run/secrets/proxy_ca install -y --no-install-recommends \
      curl gawk make jq git procps time strace && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=proxy_ca,required=true \
    curl --cacert /run/secrets/proxy_ca -fL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /usr/local/bin/jq && \
    echo "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5  /usr/local/bin/jq" | sha256sum -c - && chmod +x /usr/local/bin/jq
WORKDIR /build
COPY native/redaction-core/Cargo.toml native/redaction-core/Cargo.lock ./
COPY native/redaction-core/src/ ./src/
RUN --mount=type=secret,id=proxy_ca,required=true \
    CARGO_HTTP_CAINFO=/run/secrets/proxy_ca cargo build --release --locked
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca rustup component add rustfmt clippy
RUN cargo fmt --check && cargo clippy --offline -- -D warnings
WORKDIR /devtools
COPY native/devtools/Cargo.toml native/devtools/Cargo.lock ./
COPY native/devtools/src/ ./src/
COPY tests/fixtures/python-bootstrap-draws.json tests/fixtures/masking-fixture-hashes.json tests/fixtures/report-statistics.json /tests/fixtures/
COPY bench/results/rust-experiment/cli-claude.json bench/results/rust-experiment/cli-codex.json bench/results/rust-experiment/cli-clean-followup.json /bench/results/rust-experiment/
RUN --mount=type=secret,id=proxy_ca,required=true \
    CARGO_HTTP_CAINFO=/run/secrets/proxy_ca cargo build --release --locked
RUN cargo fmt --check && cargo clippy --locked --offline --all-targets -- -D warnings && \
    cargo test --locked --offline && \
    cp target/release/agent-guard-devtools /usr/local/bin/agent-guard-devtools && \
    ! command -v python3 && ! command -v python
RUN useradd --uid 1000 --create-home --shell /bin/bash agent
WORKDIR /repo
