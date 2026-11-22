# Native redactor experiment

This experiment compares the optimized shell implementation with the opt-in
Rust literal redactor. It does not compare a complete Rust rewrite. Detection,
policy, PII and host envelopes remain in the shell CLI.

## Reproduce

Use Linux/x86_64, Docker and a verified gitleaks 8.30.1 executable.
The image pins Rust 1.85.1, its base digest, jq 1.7.1 and the Cargo lockfile.
APT package versions are recorded in the results rather than pinned forever.
Do not run builds, regression suites or other benchmarks simultaneously.

```sh
sh bench/native/run.sh /absolute/path/to/gitleaks \
  16075762fa528f071f01f9c1998083b30aaca116 \
  "$PWD/bench/local/rust-experiment"
```

The recorded v3.6.14 comparison and the report generator that rendered it are
no longer tracked; they remain available at the `v3.6.14` tag.

The runner normally builds the image. `AGENT_GUARD_BENCH_CA_BUNDLE` can select
a build-time proxy CA bundle. To reuse a previously verified image without
building, set `AGENT_GUARD_BENCH_IMAGE` to its immutable image ID. The runner
checks that the image's Rust source, manifest and lockfile match the checkout.

For regression verification, run `agent-guard-devtools verify` inside the same image
with a read-only checkout, an actual passwd entry
for the selected UID, and gitleaks on PATH. Its default runs all five existing
shell partitions plus the Rust output partition. `--shards 4` runs only the
shell/Rust output partitions; that narrower result must not be described as a
complete suite. The native CI also runs the independent audit suite.

## Interpretation

- `kernel.json`: 15 paired one-shot trials per workload, including executable
  startup and JSON I/O, without the scanner or shell pipeline.
- `cli-claude.json`: 21 complete CLI workloads, nine alternating pairs each.
  Child CPU and maximum individual child RSS are collected alongside latency.
  Separate strace invocations measure process creation attempts, not timing.
- `cli-codex.json`: three representative workloads with Codex envelopes.
- `cli-shell-control.json`: the candidate with native mode disabled, separating
  dispatch overhead from the Rust implementation's effect.
- `cli-clean-followup.json`: 21 additional pairs for the clean workload whose
  initial samples varied substantially; original samples are retained.
- `load-*.json`: eight requests at concurrency one or four, three fresh-container
  trials per backend. A 10 ms sampler sums RSS of processes in the private PID
  namespace. Shared pages can be counted repeatedly; short peaks can be missed.
  This includes the driver/init and excludes page cache and Docker/build memory.
  Sampling overhead is included for both backends; driver CPU is recorded.

Every measured output is verified, including negative controls. An output
mismatch stops the measurement. CPU is user plus system time, not utilization
percentage. Individual maximum child RSS is not aggregate process-tree memory. On Linux,
pre-exec forked memory can give Python-launched small programs an approximately
11 MiB RSS floor here. Kernel RSS is therefore not used to claim a native-core
memory saving; the full CLI scanner peak is above that floor.

`run.sh` records `cgroup_isolated` in the `load-*.json` results: a rootless Docker with the `none` cgroup
driver does not enforce the requested per-container CPU and memory limits, so
the parent environment's cgroup memory peak is not container memory. Use
sampled process RSS instead, and use `run-packaged.sh`, which refuses to
measure without enforced limits, for constrained-deployment claims.

The CLI workloads use synthetic output, cold readiness caches and PII off.
They do not establish model latency, remote PII latency, repository scanning
performance, macOS/ARM performance or production packaging readiness.

## Artifact policy

Measurement results are not tracked. Use ignored `bench/local/` for new runs,
or keep them in a release asset or CI artifact.
Cargo build directories, local caches and generated release archives are ignored;
Cargo lockfiles remain tracked. `.dockerignore`
keeps these local artifacts out of the benchmark image build context.

## Developer tool migration

`native/devtools` replaces the former Python verification and measurement
scripts. Use `sh scripts/devtools.sh <command> [options]` locally; it builds
the locked release binary before running. The Docker image provides the same
`agent-guard-devtools` executable without Python or matplotlib. The installed
shell CLI does not invoke Cargo or the developer binary.

`agent-guard-devtools --help` lists the commands, and `<command> --help` lists
each command's options. Options retain the former scripts' meanings. Run
regression partitions with `verify --out /absolute/results --native-core /build/target/release/agent-guard-redact`.

The 1,013 valid differential inputs are frozen in
`tests/fixtures/native-contracts.json` from Python seed 60261104. Eleven malformed
inputs are checked separately. Fixture hashes preserve all 21 masking/boundary
inputs and full expected values. `tests/devtools.sh`
checks option parsing, child resource exit status, the source-location
observation and failed-partition reporting without a Python interpreter.
