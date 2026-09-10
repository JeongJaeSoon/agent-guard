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

4. Run the post-tool sentinel through that route:

   ```sh
   printf '%s\n' '[REDACTED]'
   ```

   Confirm the raw marker is not delivered to the model as ordinary tool output.

The sentinels contain no credentials. They test dispatch only; `smoke-test`
tests deterministic policy behavior separately.

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
