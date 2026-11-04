# syntax=docker/dockerfile:1
FROM rust:1.85.1-slim-bookworm@sha256:9f841bbe9e7d8e37ceb96ed907265a3a0df7f44e3737d0b100e7907a679acb36
# Keep layers few: the managed rootless daemon may use full-copy VFS snapshots.
RUN --mount=type=secret,id=proxy_ca,required=true \
    apt-get -o Acquire::https::CaInfo=/run/secrets/proxy_ca update && \
    apt-get -o Acquire::https::CaInfo=/run/secrets/proxy_ca install -y --no-install-recommends \
      curl gawk make jq git procps time strace && \
    rm -rf /var/lib/apt/lists/* && \
    curl --cacert /run/secrets/proxy_ca -fL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /usr/local/bin/jq && \
    echo '5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5  /usr/local/bin/jq' | sha256sum -c - && \
    chmod +x /usr/local/bin/jq && \
    SSL_CERT_FILE=/run/secrets/proxy_ca rustup component add rustfmt clippy && \
    useradd --uid 1000 --create-home --shell /bin/bash agent
WORKDIR /repo
COPY --chown=1000:1000 . .
RUN --mount=type=secret,id=proxy_ca,required=true \
    for crate in redaction-core devtools; do \
      CARGO_HTTP_CAINFO=/run/secrets/proxy_ca cargo build --release --locked --manifest-path "native/$crate/Cargo.toml" && \
      cargo fmt --manifest-path "native/$crate/Cargo.toml" --check && \
      cargo clippy --manifest-path "native/$crate/Cargo.toml" --locked --offline --all-targets -- -D warnings && \
      cargo test --manifest-path "native/$crate/Cargo.toml" --locked --offline || exit 1; \
    done && \
    mkdir -p /build/target/release /devtools && \
    cp native/redaction-core/Cargo.toml native/redaction-core/Cargo.lock /build/ && \
    cp -R native/redaction-core/src /build/ && \
    cp native/redaction-core/target/release/agent-guard-redact /build/target/release/ && \
    cp native/devtools/Cargo.toml native/devtools/Cargo.lock /devtools/ && \
    cp -R native/devtools/src /devtools/ && \
    cp native/devtools/target/release/agent-guard-devtools /usr/local/bin/ && \
    chmod -R a+rX /build /devtools && \
    rm -rf native/redaction-core/target native/devtools/target /usr/local/cargo/registry && \
    ! command -v python3 && ! command -v python
USER agent
