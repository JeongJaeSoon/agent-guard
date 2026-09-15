# Verification

Use separate evidence for dependencies, deterministic behavior, and live host
dispatch. A passing earlier layer does not prove a later one.

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

- A detected secret is a block/finding, not a scanner error.
- A `DEGRADED` message or unavailable scanner is not a clean scan. Repair the
  dependency or choose the documented infrastructure policy.
- `open` infrastructure mode continues after a visible one-time warning;
  `closed` blocks. This policy applies to infrastructure failures, while a
  secret detection blocks.
- A host that kills a hook at its timeout can prevent that hook from deciding.
  Keep Git and CI backstops enabled.

## Routine checks

```sh
agent-guard doctor
agent-guard smoke-test
agent-guard scan-working-tree
```

For Codex, re-review changed hooks in the hooks UI. For Claude Code, reload the
plugin and restart the session after installation or shell-rc changes.
