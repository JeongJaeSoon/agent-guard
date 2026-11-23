# Verification

English · [한국어](verification.ko.md) · [日本語](verification.ja.md)

Use separate evidence for dependencies, deterministic behavior, and live host
dispatch. A passing earlier layer does not prove a later one.

The exact matchers, per-host replacement contracts, and timeout budgets are
summarized in [Output masking coverage](integrations.md#output-masking-coverage).
After a plugin update, a hook trust change, or a host upgrade, rerun the live
probes below on every route you rely on.

| Evidence | Command or action | What it establishes | What it does not establish |
| --- | --- | --- | --- |
| Dependency check | `agent-guard check` or `agent-guard doctor` | Required local commands and policy files are available | That a host dispatches hooks |
| Synthetic check | `agent-guard smoke-test` | Bundled deny, scanner, and redaction paths work together | That an installed plugin or current route uses them |
| Local repository scan | `scan-staged`, `scan-working-tree`, or `scan-path` | The selected current repository/path was scanned | Future tool calls or ignored paths outside its scope |
| Live host probe | Harmless probe through the normal host route | That exact route dispatched the expected hook | Other tools, wrappers, or hosts |

## Plugin acceptance

1. Run the host’s guided setup or plugin-local `check` and `smoke-test`.
2. Confirm hooks are enabled and trusted after every plugin update.
3. Run the pre-tool sentinel through the same route users will use:

   ```sh
   printf '%s\n' 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE'
   ```

   The guard should block it before the sentinel appears.

4. Run the post-tool probe through that same route. The command reads the
   sentinel out of the binary under test, so it is self-contained and this file
   carries no second copy of the sentinel to fall out of step:

   ```sh
   GUARD=$(command -v agent-guard)   # or the plugin-local bin/agent-guard path
   printf '%s\n' "$(sed -n 's/^LIVE_POST_TOOL_PROBE=//p' "$GUARD" | head -1)"
   ```

   The raw sentinel must not reach the model. Expect a replacement that keeps
   `[REDACTED]` and, while local diagnostic logging is on, names the hook
   invocation that produced it:

   ```text
   [REDACTED] agent-guard live probe run_id=<run id>
   ```

   Never type a literal `[REDACTED]` into the command. That tests neither
   redaction nor dispatch.

5. Look the reported run id up in the diagnostic log yourself, in a terminal:

   ```sh
   agent-guard logs export \
     | jq -c 'select(.run_id == "<run id>" and .command == "hook-post-tool")'
   ```

   A `finished` record with `"outcome":"masked"` shows that this install rewrote
   the sentinel at that moment. It is the only part of the probe that does not
   rest on what the agent reported, so treat a run id that resolves to no record
   as a failed probe. The log is metadata only and names no tool, so the record
   establishes the PostToolUse rewrite, not which tool route carried it; read it
   together with the route you actually ran. Under `AGENT_GUARD_LOG_MODE=off`
   there is no record to cite and the replacement stays the bare `[REDACTED]`.

The sentinels contain no credentials. They test dispatch only; `smoke-test`
tests deterministic policy behavior separately.

Reading a file that contains a sentinel is itself a tool call the guard covers,
so the setup skill's own probe line comes back already replaced. That is the
hook working, not a placeholder committed to the repository. Compare the line's
byte length with the placeholder's if you need to confirm it.

## Claude Code Code Mode

In Code Mode Claude writes JavaScript that makes several tool calls in one
step. Each call the code makes passes `PreToolUse` and `PostToolUse` under the
tool's own name, so the probes above cover it. What the code returns reaches
the model on two more routes that those probes do not exercise: `REPL` when
the code ends or throws, and `Poll` when its output is delivered. Checked on
Claude Code 2.1.330.

1. Ask Claude to run the post-tool probe as code, through a call that fails.
   The host lets no hook rewrite a failed call's output, so the code receives
   the raw sentinel and only the `REPL` or `Poll` hook can keep it from the
   model:

   ```js
   const guard = '/absolute/path/to/bin/agent-guard';
   const probe = await $`sed -n 's/^LIVE_POST_TOOL_PROBE=//p' ${guard} | head -1; exit 3`.nothrow();
   probe.stdout
   ```

   Expect the same replacement as in step 4 above. A raw sentinel means neither
   hook ran: check that the installed `PostToolUse` matcher lists `REPL` and
   `Poll`.

2. Run the same command without `.nothrow()`, so the code throws. The error
   Claude reads, including the failed call the host appends to it, must carry
   the replacement.

3. Look each reported run id up as in step 5 above.

When you compare what the code received with a file on disk, compute the
expected size or hash with a command the shell integration does not wrap, such
as `wc -c < file` or `shasum < file`. Inside Claude Code `cat` and `head`
return the masked view, and two masked views always agree.

These probes show that a returned value is masked. They do not change two host
limits: the code itself receives a failed call's output, and the part of a
successful output past about 30,000 characters, without masking. A value the
code keeps is checked again only when the code returns it or passes it to
another tool call.

## Read results correctly

- A successful JSON-tool exit does not always mean its serialized output is
  complete. If intermediate PostToolUse output cannot be safely rewritten,
  the guard attempts conservative recovery from the retained original event.
  This preserves nested response shape when the independent parser succeeds;
  it does not treat a failed scan as clean.
- A detected secret is a block/finding, not a scanner error.
- A `DEGRADED` message or unavailable scanner is not a clean scan. Repair the
  dependency or choose the documented infrastructure policy.
  When available, `Scanner readiness: timeout.` identifies a bounded version
  probe that timed out; other fixed readiness codes distinguish an unsupported
  version or a failed probe. These diagnostics include no scanner output or
  input paths. A timeout code identifies the failed stage, not why it was slow.
  Every hook except SessionStart retries a timed-out version probe once, so
  there the code means that two probes in a row timed out.
- `open` infrastructure mode continues after a visible one-time warning;
  `closed` blocks. This policy applies to infrastructure failures, while a
  secret detection blocks. Non-empty malformed or non-object PreToolUse and
  Stop input blocks independently of infrastructure mode. PostToolUse first
  recovers a valid host envelope with its independent parser and emits a
  conservative replacement; exit status 2 for a non-empty malformed or
  non-object PostToolUse envelope is a visible diagnostic and cannot retract
  the completed tool result. Under `closed`, a Claude PostToolUse hook that
  could not check an output also replaces every non-empty string in it and
  keeps its shape, because exit status 2 alone leaves the output with the
  model. Empty stdin is the documented exception:
  PreToolUse, PostToolUse, and Stop return status 0 with no response. Every
  rejected event is reported.
- A host that kills a hook at its timeout can prevent that hook from deciding.
  Claude Code 2.1.295 and later blocks the tool call when the `PreToolUse` hook
  times out or crashes; other events and hosts do not. Keep Git and CI
  backstops enabled.

The direct scan commands (`scan-staged`, `scan-working-tree`, `scan-path`)
return their status to the caller instead of applying the infrastructure
policy:

| Exit | Meaning |
| --- | --- |
| `0` | Nothing was detected in the scanned input. |
| `1` | A secret-like value was detected. Findings are redacted, so the message names the scanned input, not the value. |
| `2` | Usage error, such as a missing `scan-path` argument or path, or a gitleaks error during `scan-staged` or `scan-path`. |
| `3` | The scan could not run: no gitleaks, no gitleaks config, not a Git repository, a failed `git diff`, or input over the scan budget. |

Treat `2` and `3` as "not scanned", never as clean.

## Routine checks

The warm gitleaks helper is checked against the official gitleaks release it
links. The release workflow runs its failure-path, host and differential
suites from each platform's release archive and publishes an archive only when
its two binaries match the SHA-256 values in
`plugins/agent-guard/config/gitleaks-helper.sha256`, the values
`agent-guard setup --install-gitleaks-helper` requires. The build is
reproducible: `sh scripts/build-gitleaks-helper.sh --print-pins` in a source
checkout prints those lines. To check an installed helper yourself, compare it
with its recorded sums, and from a source checkout run the suites with the
official release binary (not a Homebrew or `go install` build, which the
helper refuses by design):

```sh
(cd "$HOME/.agent-guard/bin/gitleaks-helper" && shasum -a 256 -c SHA256SUMS)
AGENT_GUARD_TEST_HELPER_DIR="$HOME/.agent-guard/bin/gitleaks-helper" \
AGENT_GUARD_TEST_REAL_GITLEAKS="$(command -v gitleaks)" sh tests/gitleaks-helper.sh
AGENT_GUARD_TEST_HELPER_DIR="$HOME/.agent-guard/bin/gitleaks-helper" \
AGENT_GUARD_TEST_REAL_GITLEAKS="$(command -v gitleaks)" sh tests/gitleaks-helper-corpus.sh
```

`agent-guard setup` prints the helper's state. While it is in use, a running
helper appears as one `agent-guard-gitleaks-helper
serve` process with a socket under `$XDG_STATE_HOME/agent-guard/gitleaks-helper`
(or `~/.local/state/...`). Its absence only means scans run the real gitleaks.

```sh
agent-guard doctor
agent-guard smoke-test
agent-guard scan-working-tree
```

For Codex, re-review changed hooks in the hooks UI. For Claude Code, reload the
plugin and restart the session after installation or shell-rc changes.
