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
- `open` infrastructure mode continues after a visible one-time warning;
  `closed` blocks. This policy applies to infrastructure failures, while a
  secret detection blocks. Non-empty malformed or non-object PreToolUse and
  Stop input blocks independently of infrastructure mode. PostToolUse first
  recovers a valid host envelope with its independent parser and emits a
  conservative replacement; exit status 2 for a non-empty malformed or
  non-object PostToolUse envelope is a visible diagnostic and cannot retract
  the completed tool result. Empty stdin is the documented exception:
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

Performance experiments need separate accuracy and timing evidence. Compare the
actual public release with the candidate using the same inputs, scanner,
configuration and enforced resource limits, and verify every output against an
independent expectation. Keep CLI startup, CPU, maximum individual child RSS,
sampled process RSS sum and throughput distinct. A faster result caused by
masking extra clean content or weakening a failure boundary is a failed
experiment. Repeated successful checks after an intermittent failure do not
establish its cause; retain the failed fixture, stdout and stderr when available.

When the scanner itself is the experiment, identify that variable explicitly.
Compare the official scanner, a rebuild with the original dependencies, and the
candidate built with the same compiler and flags. Record binary hashes and
dependency versions; an unchanged version string does not establish identical
behavior. Test audit logging off and on, with both cold and warm readiness
caches. A faster experimental scanner is not a supported installation until
its detection, platform, update and recovery checks pass.

Separate one-time installation costs from per-invocation costs. Report download
and installed sizes, verification/unpacking, and source compilation separately;
prebuilt helpers do not require a compiler on the user's machine. Compute a
break-even invocation count only from comparable measurements of the actual
workload. Peak memory cannot be amortized by repeated use. Lower latency and CPU
can coexist with a higher sampled process RSS sum, so report that trade-off too.

The fused output-pipeline candidate remains an explicit experiment, separate
from the default installation path. A measured improvement does not establish
release readiness: preserve compiler-free host setup, fallback behavior, and
the host's existing timeout and locale contracts before adopting it.


```sh
agent-guard doctor
agent-guard smoke-test
agent-guard scan-working-tree
```

For Codex, re-review changed hooks in the hooks UI. For Claude Code, reload the
plugin and restart the session after installation or shell-rc changes.
