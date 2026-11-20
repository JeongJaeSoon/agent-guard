# Warm gitleaks helper (opt-in)

English only. This guide is not translated yet; the
[installation guide](installation.md#optional-warm-gitleaks-helper) has the
short version in English, [한국어](installation.ko.md#optional-warm-gitleaks-helper)
and [日本語](installation.ja.md#optional-warm-gitleaks-helper).

Every Agent Guard scan starts a new gitleaks process. Almost all of its time
(about 570 ms on a 4-vCPU Linux VM) is start-up: the regular-expression
engine's WebAssembly runtime and the compilation of 224 rules. The scan itself
takes under a millisecond for a 2 KB input. The opt-in warm helper pays the
start-up once and keeps one compiled gitleaks detector in memory; hooks reach
it through a small client.

It is off by default and not included in any release archive, Homebrew
formula or plugin. You build it from source and turn it on with one
environment variable.

## What changes and what does not

The CLI still decides everything: policy, masking, exit codes and the
`AGENT_GUARD_INFRA_FAILURE_MODE` policy. The helper is only the scan engine.
Host adapters are unchanged.

Where the CLI would run `gitleaks stdin` (command, prompt, edit, staged and
working-tree scans, and the output detector's JSON report), it runs the client
`agent-guard-scan` instead, with the same arguments. The client:

- answers from the warm helper only for the two `gitleaks stdin` argument
  shapes the CLI uses, and only when the helper links the same gitleaks
  version the CLI probed and was loaded from the same config bytes;
- otherwise replaces itself with the real gitleaks (`exec`), with the same
  arguments and the same standard input.

`gitleaks dir` (`scan-path`, the GitHub Action) and every other gitleaks call
keep running the real gitleaks.

## Turn it on

Requirements: Go (the version in `native/gitleaks-helper/go.mod`, fetched
automatically by a newer Go), and the normal runtime dependencies, including
gitleaks 8.30.1. The helper links the gitleaks 8.30.1 library; with any other
installed gitleaks version every request runs the real gitleaks.

```sh
sh scripts/build-gitleaks-helper.sh "$HOME/.agent-guard/gitleaks-helper"
export AGENT_GUARD_GITLEAKS_HELPER="$HOME/.agent-guard/gitleaks-helper/agent-guard-scan"
```

The build fails if any module the helper links differs from the official
gitleaks 8.30.1 release (`native/gitleaks-helper/release-modules.txt`). It
writes `build.txt` (toolchain and build information) and `SHA256SUMS`. Keep
`agent-guard-scan` and `agent-guard-gitleaks-helper` in the same directory.

Set the variable in the environment that launches Claude Code or Codex and
restart the host. The variable must be an absolute path to an executable file.
To turn it off, unset it; a running helper exits by itself after its idle
time.

`AGENT_GUARD_GITLEAKS_CONFIG` works as without the helper: the custom file's
bytes get their own helper (the default config's helper keeps running until
it is idle).

The helper is not used when:

- `AGENT_GUARD_GITLEAKS_BIN` is set (you chose a specific scanner);
- `AGENT_GUARD_LOG_MODE=off`, even with `AGENT_GUARD_SCAN_CACHE=on` keeping
  the state directory for the caches (log-off mode keeps the helper off for
  now);
- the socket path would exceed 103 bytes (`$XDG_STATE_HOME`, or
  `~/.local/state`, is very deep);
- the gitleaks the CLI selected is not built like the official release: the
  client reads its embedded Go build information and the helper compares the
  toolchain, the `gore2regex` tag (go-re2 instead of Go's `regexp`) and every
  linked module version with its own. A gitleaks 8.30.1 built with Go's
  `regexp`, such as a Homebrew or `go install` build, is therefore always run
  for real. A patched build with the same version, tag and modules is not
  detected; `AGENT_GUARD_GITLEAKS_BIN` keeps such a scanner on its own.

Two advanced settings are read when a helper starts:
`AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS` (default `600`, 1 to 86400) and
`AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB` (default `160`, 96 to 4096; a
started helper alone uses about 60 MiB, so a lower cap would only restart it
after every scan).

## Same scanner

- The helper is built from the gitleaks 8.30.1 module with the `gore2regex`
  tag, so it uses the same regular-expression engine (go-re2 1.9.0 on wazero
  1.9.0) and the same module versions as the official release binary. The
  build checks this; it refuses to run if the linked module and the stamped
  version differ.
- It loads the config with the same code path as `gitleaks --config PATH` and
  only when the bytes it parsed hash to the SHA-256 the client sent. Every
  request carries that hash and the probed gitleaks version; a mismatch is
  answered "fallback". The client also reads the version and build of the
  helper binary and of the selected gitleaks first: when they cannot match it
  neither connects nor starts a helper. Only an answer resets a helper's idle
  clock.
- A config with `[extend] path` (another file the hash does not cover), or one
  that makes gitleaks print warnings, is marked unsupported; the client then
  always runs the real gitleaks for it.
- A `.gitleaksignore` in the scan directory sends the request to the real
  gitleaks.
- Any log event the gitleaks library emits during a scan (the real gitleaks
  would print it), a scan error, or a scan over 2.5 s is answered "fallback".
- Standard input from a regular file is read in fixed 100 KB chunks by the
  real gitleaks and by the helper alike. From a pipe, the real gitleaks makes
  a chunk of each `read()`, which depends on how the writer wrote. The client
  sends piped input to the helper only when one `read()` returned all of it
  (then end of file), which is at most one pipe buffer (64 KiB): that is the
  single chunk the real gitleaks reads in the same situation. Input that
  arrives in pieces, and regular files over 1 MiB, go to the real gitleaks.
- A report larger than 16 MiB (a large input dense with findings) is answered
  "fallback".

The real gitleaks reports findings in rule-map order, which changes from run
to run, and logs a clock time and a duration. Apart from those, the helper's
exit code, stdout, stderr and report are the real gitleaks's for every input
it answers.

## Failure is never "clean"

| Situation | What happens | Test |
| --- | --- | --- |
| Variable unset, relative, missing or not executable | Existing path; no client | `tests/gitleaks-helper-routing.sh` |
| Client present, helper binary missing | Real gitleaks | `tests/gitleaks-helper.sh` |
| No helper running (first call, or after idle exit) | Real gitleaks; one helper starts in the background (at most one start per minute per key) | same |
| Stale socket file from a killed helper | Connection refused: real gitleaks; the next helper removes the file | same |
| Helper closes, sends a short, corrupt or unexpected answer | Real gitleaks | same, with a fake helper |
| Helper does not answer within 3 s | Real gitleaks | same |
| Helper answers "fallback" (version, regex engine, config, log event, scan error, timeout) | Real gitleaks | same, with a fake helper; the helper's own refusals in `go test` |
| Selected gitleaks has no Go build information or another regex engine | Real gitleaks | same |
| Socket served by another user | Not trusted, even if the answer looks clean: real gitleaks | same (needs root or sudo) |
| Private directory missing, wrong mode or owner, or a symlink | Real gitleaks; nothing is repaired | same |
| Unwritable report path | Real gitleaks, which reports its own error | same |
| Input over the size limits, piped input that arrives in pieces, a report over 16 MiB, unknown flags, `.gitleaksignore` | Real gitleaks | same |
| The hook's other descriptors cannot be listed or marked close-on-exec | No helper is started; the scan runs the real gitleaks | not tested (needs a system without `/dev/fd`) |
| Real gitleaks cannot run either | Client exits 2: the CLI's existing "could not scan" path (`open` warns, `closed` blocks); never cached as clean | `tests/gitleaks-helper-routing.sh` |
| Sandbox without Unix sockets or background processes | The helper cannot start; every call runs the real gitleaks at today's speed | not measured |

## One helper, bounded memory, bounded life

- One helper per user, helper binary and config bytes. Sessions share it; a
  file lock makes racing starts end with one process.
- It exits after `AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS` without a request,
  checked every 15 s or every idle period if shorter (default 600 s, the same ten minutes as the CLI's readiness and clean-scan
  caches: a user who returns later pays one ordinary scan).
- After each request it checks its peak resident memory (Linux and macOS
  alike) and exits once that is over `AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB`;
  the next request starts a fresh one. The check is not a hard limit during a
  scan: a 1 MiB input dense with findings peaked at 115 MiB. The Go heap gets a soft limit
  of half the cap, freed memory is returned to the system after inputs over
  256 KiB, at most four requests are read at a time, and one is scanned at a
  time.
- It runs in its own session with no environment variables and `/dev/null`
  for standard streams, and the client marks the hook's other inherited
  descriptors close-on-exec before starting it (and starts none if it cannot),
  so it holds no session's variables or pipes. It removes its socket and lock when it exits; files left
  by a killed helper are removed by the next one.
- The helper starts as a child of the client, which then becomes the real
  gitleaks for that scan; when that gitleaks exits the helper is reparented
  to the system's init, which reaps it when it ends. In a container whose
  PID 1 does not reap orphans, an exited helper stays a zombie (no memory,
  only a process-table entry) until the container ends.

## Security

- Unix domain socket only, in `$XDG_STATE_HOME/agent-guard/gitleaks-helper`
  (or `~/.local/state/...`), a directory both sides require to be a real
  directory owned by the user with mode 0700. The socket is created 0600.
- Both sides check the other's uid through the kernel (`SO_PEERCRED` on
  Linux, `LOCAL_PEERCRED` on macOS).
- Every frame has a bounded header and payload (1 MiB); a short frame is an
  error.
- The helper writes no scanned content to disk or logs; the client writes the
  report into the file the CLI created, through one handle, so the file keeps
  its private mode and is never removed and recreated. (The real gitleaks
  removes and recreates the report path with the umask's mode; the CLI's
  report file normally sits in its private run directory.)
- Another process of the same user can serve the socket path. The peer
  check keeps other users out; it cannot tell two processes of the same user
  apart, which is the trust the CLI's clean-scan cache in the same directory
  already relies on.
- `AGENT_GUARD_GITLEAKS_HELPER_TRACE`, if it is an absolute path, makes the
  client append one fixed word per scan (`helper`, `spawned` or
  `real:<reason>`) to that file. It is for tests and diagnosis and never
  records content, paths or arguments.
- `AGENT_GUARD_GITLEAKS_HELPER` is a trusted executable path, like
  `AGENT_GUARD_RUST_CORE_BIN`. Point it only at a build you made or verified.

## Privacy

Scanned text passes through the helper's memory, which lives longer than one
hook. The helper overwrites its request buffer after each scan, but gitleaks
keeps copies as Go strings that the collector frees without overwriting, so
scanned bytes can remain in the helper's memory until it is reused or the
helper exits (about the idle time after the last scan; the idle check runs
every 15 seconds). Nothing is written
to disk or sent over the network. See [PRIVACY.md](../PRIVACY.md).

## Why a compiled helper

Agent Guard adds code only when reuse, POSIX tools and host features cannot
give the required guarantee (see `AGENTS.md`). Here:

- gitleaks has no server mode, and its start-up cost is in its own process;
  no option or POSIX tool keeps a compiled detector alive between hooks.
- A shell cannot talk to a Unix socket portably (`nc -U` and `socat` are not
  on every macOS and Linux system) and cannot check the peer's uid.
- Another scanner or a rewritten engine would not be the same detector. The
  helper links gitleaks itself, so detection is the official release's.

The only new dependency is the gitleaks module and its own dependencies, at
the versions of the official release. The client uses the Go standard library
and `golang.org/x/sys`.

## Measurements

One 4-vCPU Linux VM, official gitleaks 8.30.1, medians of 9 runs of each hook
with synthetic inputs (`bench/gitleaks-helper/measure.py`). "Cold" is the hook
that finds no helper running: its scans run the real gitleaks and it starts
the helper, which can already answer the later scans of a PostToolUse hook.

| Hook (ms) | Off | On, cold | On, warm |
| --- | ---: | ---: | ---: |
| Bash PreToolUse (new command) | 551 | 546 | 110 |
| Edit PreToolUse | 487 | 496 | 54 |
| UserPromptSubmit | 506 | 498 | 61 |
| PostToolUse Read (clean tree) | 572 | 588 | 128 |
| PostToolUse Bash (changed tree) | 1,573 | 656 | 200 |
| PostToolUse Edit (changed tree) | 1,602 | 651 | 215 |

Memory: each real gitleaks run peaks at 58 to 77 MiB resident and a
PostToolUse hook with a changed tree runs three in a row. The helper holds
59 MiB right after starting, 64 MiB after 50 small scans, 40 to 42 MiB
after inputs of 1 MiB and dense 300 KB secrets (its peak was 77 MiB), and
65 MiB while four sessions scanned through it at once, still one process. The
client peaks at 3.4 MiB (7.7 MiB for a 1 MiB input) for a few milliseconds.
Off, nothing changes: across 128 runs (14 hook fixtures, `scan-staged` and
`scan-path`; Claude and Codex; log on and off; the variable unset and pointing
at a missing client) exit codes, output, the number
of programs executed and the number of processes forked equal main
(`bench/gitleaks-helper/compare-off.sh`, also run in CI).

Large inputs copy no more than v3.7.0 did. With 300 KiB and 1 MiB clean
inputs through a Write PreToolUse and a Bash PostToolUse, the bytes every
process read and wrote were within 3% of the published v3.7.0 release with the
helper off and with it warm (for example 19.8, 20.0 and 20.1 MiB for a 1 MiB
Write), and no case was slower (`bench/gitleaks-helper/large-v370.sh`, Linux;
`bench/fused-output/run-constrained.sh` needs Docker with enforced cgroup
limits and was not run). A pipe that already holds as much as the helper can
take goes to the real gitleaks before the client reads a byte, so a large
piped input is not copied once more through a replay.

## Known limits

- A helper that is alive but stopped (for example by SIGSTOP) keeps its
  socket: every scan then waits for the three-second deadline before running
  the real gitleaks, until the helper is resumed or killed.
- The helper's own peer-uid refusal is not tested; only the client's is.

- A helper killed within a minute of starting leaves its start marker, so
  scans for that key run the real gitleaks until the marker is a minute old.
- The state directory must be a plain path: a `$XDG_STATE_HOME` ending in `/`
  makes the CLI skip its private state directory, and with it the helper.

- A helper inherits the resource limits of the hook that started it (for
  example the output detector's 64 KiB file-size limit); it writes no files
  besides its empty markers, so this changes nothing it does.

- The client connects to the helper before it reads standard input, so a
  cold call can still `exec` the real gitleaks without copying piped input. A
  producer that is slow to write therefore holds one of the helper's four
  connection slots for up to three seconds; other clients then wait, and after
  three seconds run the real gitleaks. The verdict is unaffected.

## Not verified

- Behavior inside Claude Code and Codex sandboxes and hosts that kill every
  descendant of a hook (the helper would start and end with each hook).
- Intel macOS and Linux arm64.
