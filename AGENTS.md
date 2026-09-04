# Agent Guard contributor rules

Agent Guard is a boundary guard, not an agent orchestrator. Keep these layers
separate:

- the portable shell CLI owns policy evaluation, scanning, redaction, exit
  codes, and dependency diagnostics;
- host adapters (Claude, Codex, Git hooks, and GitHub Actions) translate their
  native event into the CLI contract and must not duplicate policy logic;
- sub-agent and legacy Task events are inputs to the same boundary checks, not
  permission to bypass them.

Before adding code, follow this minimum-complexity ladder: reuse an existing
path, use POSIX shell or an installed system tool, use a host-native feature,
and add a new dependency only when the preceding options cannot provide the
required security guarantee. Never simplify away validation, redaction,
fail-closed behavior, or cleanup merely to reduce lines.

Every adapter change must preserve safe pass-through behavior for unknown
events, explicit infrastructure-failure policy, and the distinction between a
clean scan and a scan that could not run. Add a fixture for each supported host
and run `tests/run.sh` before declaring the change complete.
