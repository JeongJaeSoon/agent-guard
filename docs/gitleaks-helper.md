# Warm gitleaks helper

English only. This guide is not translated yet; the
[installation guide](installation.md#optional-warm-gitleaks-helper) has the
short version in English, [한국어](installation.ko.md#optional-warm-gitleaks-helper)
and [日本語](installation.ja.md#optional-warm-gitleaks-helper).

Every Agent Guard scan starts a new gitleaks process. Almost all of its time
(about 570 ms on a 4-vCPU Linux VM) is start-up: the regular-expression
engine's WebAssembly runtime and the compilation of 224 rules. The scan itself
takes under a millisecond for a 2 KB input. The warm helper pays the
start-up once and keeps one compiled gitleaks detector in memory; hooks reach
it through a small client. On that VM, hooks that took about 0.5 to 1.6
seconds took about 0.05 to 0.2 seconds with a warm helper.
[Measured cost](#measured-cost) has the macOS numbers.

The helper is a separate release asset for Linux x64/arm64 and macOS arm64. It
is not part of the release archive, Homebrew formula or plugin, and no hook
downloads it. Once you install it, scans use it by default.

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

## Install it

`agent-guard setup --install` installs the helper together with gitleaks when
the gitleaks in use is the one that command puts in the private directory, at
the version the helper links; rerun it to get the helper for a gitleaks it
installed earlier. A helper that cannot be downloaded or does not match is
only a warning there, with any other gitleaks the command prints why it
installed no helper, and `AGENT_GUARD_GITLEAKS_HELPER=off` skips it. The
[installation guide](installation.md#optional-warm-gitleaks-helper) lists the
cases. To install only the helper:

```sh
agent-guard setup --install-gitleaks-helper
```

The command works the same for a plugin, Homebrew or standalone install. It
downloads `agent-guard-gitleaks-helper-<target>.tar.gz` from the GitHub
release of the running Agent Guard version, takes the two binaries out of it,
and installs them only when both match the SHA-256 values that version
carries in `config/gitleaks-helper.sha256`. A release asset that was replaced
after publication is therefore refused, and so is one for another version.
Nothing is installed on any failure, and an earlier installed helper is left
as it was.

The files go to `gitleaks-helper` in the private gitleaks directory
(`AGENT_GUARD_GITLEAKS_BIN_DIR`, else `~/.agent-guard/bin`; the deprecated
`AGENT_GUARD_BIN_DIR` counts only while a gitleaks or helper is already in it), with the two sums
recorded in `SHA256SUMS`. From then on every scan uses the helper: no
variable is needed and a running host uses it from its next scan. The CLI
runs an installed helper only when its recorded sums are the ones the CLI
pins, so after an Agent Guard update the old helper is not used until you run
the command again. The CLI does not hash the binaries again for each scan;
they have the trust of the gitleaks binary in the same directory.

`agent-guard setup` (and `doctor`) prints one line on the helper:
`not installed`, `installed`, `selected` (your own client), `off`, or
`not used` with the reason (installed for another version,
`AGENT_GUARD_GITLEAKS_BIN`, logging off). The line is read from files and
variables. It does not run the client or start a helper, so it does not tell
whether the helper answers for your gitleaks: with a build other than the
official release, `installed` still means every scan runs the real gitleaks.

The helper links the gitleaks 8.30.1 library; with any other selected
gitleaks version every request runs the real gitleaks.

## Turn it off

```sh
export AGENT_GUARD_GITLEAKS_HELPER=off
```

Set it in the environment that launches Claude Code or Codex. Any value that
is not an absolute path keeps the helper unused; a running helper exits by
itself after its idle time. Removing the `gitleaks-helper` directory has the
same effect.

## Build it yourself

Requirements: Go (the version in `native/gitleaks-helper/go.mod`, fetched
automatically by a newer Go), and the normal runtime dependencies, including
gitleaks 8.30.1.

```sh
sh scripts/build-gitleaks-helper.sh "$HOME/.agent-guard/gitleaks-helper"
export AGENT_GUARD_GITLEAKS_HELPER="$HOME/.agent-guard/gitleaks-helper/agent-guard-scan"
```

The build fails if any module the helper links differs from the official
gitleaks 8.30.1 release (`native/gitleaks-helper/release-modules.txt`). It
writes `build.txt` (toolchain and build information), `SHA256SUMS` and
`THIRD_PARTY_LICENSES.txt`: the license and license text of every module
linked into the two binaries, which each released archive carries. The build
fails when a linked module has no license recorded in
`native/gitleaks-helper/module-licenses.txt`. Keep
`agent-guard-scan` and `agent-guard-gitleaks-helper` in the same directory.
An absolute path in the variable selects that client instead of an installed
helper and is not compared with the pins: it is your own build. The released
binaries are this build, so `sh scripts/build-gitleaks-helper.sh --print-pins`
prints the pinned sums for every platform.

`AGENT_GUARD_GITLEAKS_CONFIG` works as without the helper: the custom file's
bytes get their own helper (the default config's helper keeps running until
it is idle).

The helper is not used when:

- none is installed, or the installed one was recorded for another Agent
  Guard version;
- `AGENT_GUARD_GITLEAKS_HELPER` is `off`;
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
| No helper installed, one installed for another Agent Guard version, the variable `off`, or a path that is not an executable file | Real gitleaks; no client is started | `tests/gitleaks-helper-routing.sh`, `tests/gitleaks-helper-install.sh` |
| Downloaded helper differs from the pinned checksums, holds a link instead of a file, or the download fails | Nothing is installed; scans run the real gitleaks | `tests/gitleaks-helper-install.sh` |
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
  client append fixed words to that file, one per line: usually one per scan
  (`helper` or `real:<reason>`). A scan that starts a helper writes two,
  `spawned` and then `real:cold`. `no-spawn` comes before `real:cold` when the
  client cannot keep its open descriptors out of a new helper, so starts none;
  a start that is skipped (a recent or running one) or that fails leaves only
  `real:cold`. The file is for tests and diagnosis and never records content,
  paths or arguments.
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

## Measured cost

macOS 27 on an Apple M5 Max (18 cores), official gitleaks 8.30.1, synthetic
inputs under a temporary home directory. Other work kept the machine loaded
for every run (load average 40 to 44 during the latency run), so wall-clock
times are above what an idle machine gives; an idle-machine run is still
missing.

Hook latency, 30 iterations for each hook. Each iteration ran the hook with
the helper off, as a first call (no helper running) and warm, one after the
other, and the order alternated, so the three modes share the same load.
Wall-clock milliseconds, median / 95th percentile:

| Hook | Off | First call | Warm |
| --- | ---: | ---: | ---: |
| Bash PreToolUse | 695 / 1093 | 731 / 995 | 407 / 637 |
| Edit PreToolUse | 515 / 654 | 530 / 676 | 236 / 353 |
| UserPromptSubmit | 586 / 725 | 628 / 818 | 269 / 481 |
| PostToolUse Read (clean tree) | 811 / 1090 | 889 / 1336 | 517 / 931 |
| PostToolUse Bash (changed tree) | 1886 / 2871 | 1217 / 1684 | 925 / 1195 |
| PostToolUse Edit (changed tree) | 2869 / 5014 | 1724 / 2801 | 1150 / 1649 |
| Write PreToolUse (synthetic secret) | 652 / 1268 | 724 / 1286 | 264 / 461 |

The difference to off inside the same iteration (median, milliseconds), and
in how many of the 30 iterations the mode was slower than off:

| Hook | First call | Slower | Warm | Slower |
| --- | ---: | ---: | ---: | ---: |
| Bash PreToolUse | -5 | 14 | -309 | 0 |
| Edit PreToolUse | +19 | 19 | -278 | 0 |
| UserPromptSubmit | +15 | 18 | -281 | 0 |
| PostToolUse Read (clean tree) | +71 | 21 | -297 | 2 |
| PostToolUse Bash (changed tree) | -668 | 1 | -980 | 0 |
| PostToolUse Edit (changed tree) | -1050 | 1 | -1821 | 0 |
| Write PreToolUse (synthetic secret) | +4 | 15 | -397 | 0 |

- A first call scans with the real gitleaks and starts the helper in the
  background; the hook does not wait for it. In a hook with one scan the
  first call was 5 ms faster to 71 ms slower than off at the median, with
  single iterations several hundred milliseconds either way. In a changed
  tree the hook's later scans are answered by the helper it just started, so
  the first call was already faster than off.
- Starting a helper costs about one gitleaks start-up of CPU time in the
  background, once per idle period. It is not in the hook's time.
- CPU time of the hook and every process it waited for (the helper is not
  one), median: a warm hook used about 250 ms less than off for each scan
  (112 to 231 ms instead of 359 to 479 ms with one scan, 384 to 455 ms instead
  of 1125 to 1240 ms in a changed tree). A first call with one scan used the
  same as off, within 7 ms.
- Exit codes were the same in all three modes. Every warm run was answered by
  the helper, and every first call ran the real gitleaks and started exactly
  one helper (the client's trace words); no run was left out.
- An earlier run under heavier load (load average 26 to 54, first calls in a
  block of their own) had off medians of 1.3 to 8.9 s. Warm was below off
  there too, at the median and the 95th percentile of every hook.

Memory, one helper process (from the earlier run):

| State | Resident | Footprint |
| --- | ---: | ---: |
| Idle after its first scans | 56.4 MiB | 59.3 MiB |
| After 50 small scans | 44.7 MiB | 59.3 MiB |
| After five clean 1 MiB inputs | 42.4 MiB | 41.6 MiB |
| After three 300 KB inputs dense with findings | 62.6 MiB | 56.1 MiB (peak 71.9 MiB) |
| While 16 sessions scan at once | 52.4 MiB | 67.4 MiB |

- Without the helper each scan is a gitleaks process that peaks at
  57.6 to 78.4 MiB and exits. With it each scan is a client that peaks at
  5.9 MiB, plus the one resident helper.
- Four sessions and sixteen sessions shared one helper, and sixteen scans that
  all found no helper at the same moment started exactly one.
- The helper scans one request at a time. One scan through the warm client
  took a median of 34.3 ms alone (95th percentile 79 ms), 44.1 ms (191.2 ms) with four
  sessions scanning without pause and 147.2 ms (588.7 ms) with sixteen, on the
  loaded machine.
- With a two-second idle time the helper ended by itself and left no socket,
  lock or marker.

A Homebrew gitleaks 8.30.1, built with Go's `regexp`, is never answered by
the helper. With it and an installed helper no helper process was started, and
hook CPU time was the same as without one within the noise of 15 runs (medians
20 ms lower to 47 ms higher). A hook with one scan used 210 to 280 ms less
CPU with that build than with the official build and no helper, so that build
has little start-up for a helper to save. This is CPU time only, and its runs did not
alternate with the official build's.

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
- Hook latency on an idle macOS machine, and latency and memory on Linux
  arm64 and WSL.
- Intel macOS: no helper is released for it.
