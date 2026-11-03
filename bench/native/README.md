# Native redactor experiment

This experiment compares the optimized shell implementation with the opt-in
Rust literal redactor. It does not compare a complete Rust rewrite. Detection,
policy, PII and host envelopes remain in the shell CLI.

## Reproduce

Use Linux/x86_64, Docker, Python 3 and a verified gitleaks 8.30.1 executable.
The image pins Rust 1.85.1, its base digest, jq 1.7.1 and the Cargo lockfile.
APT package versions are recorded in the results rather than pinned forever.
Do not run builds, regression suites or other benchmarks simultaneously.

```sh
sh bench/native/run.sh /absolute/path/to/gitleaks \
  16075762fa528f071f01f9c1998083b30aaca116 \
  "$PWD/bench/results/rust-experiment"
python3 bench/native/report.py --results bench/results/rust-experiment
```

The report generator additionally needs matplotlib. It emits a standalone
Korean HTML file and exportable SVG charts, with no external web dependencies.
The report also reads `verification.json` and `ci.json`; preserve the actual
validation results for the measured CLI SHA-256 rather than borrowing a passing
status from different runtime code.

The runner normally builds the image. `AGENT_GUARD_BENCH_CA_BUNDLE` can select
a build-time proxy CA bundle. To reuse a previously verified image without
building, set `AGENT_GUARD_BENCH_IMAGE` to its immutable image ID. The runner
checks that the image's Rust source, manifest and lockfile match the checkout.

For regression verification, run `bench/native/verify.py` inside the same image
with a read-only checkout, `PYTHONDONTWRITEBYTECODE=1`, an actual passwd entry
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

## Recorded environment limitation

The recorded run requested two CPUs and 1 GiB per Docker container, but the
managed environment's rootless Docker uses the `none` cgroup driver. These
per-container limits were **not enforced**. Both implementations shared the
parent environment's four-CPU quota and 16 GiB memory limit. No other local
test/build job ran during performance sampling; the CPUs were not dedicated.

The visible cgroup memory peak belongs to the parent environment and must not
be plotted as container memory. The report uses sampled process RSS instead.
Raw counters are retained with `cgroup_isolated: false`. A future isolated
runner should enforce and verify cgroup limits before extending these results
to constrained production deployments.

The CLI workloads use synthetic output, cold readiness caches and PII off.
They do not establish model latency, remote PII latency, repository scanning
performance, macOS/ARM performance or production packaging readiness.
