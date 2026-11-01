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

## Documentation languages

- Keep public English documentation in English. `README.md` and unsuffixed
  documents in `docs/` are the canonical English sources; do not replace
  their existing English prose with a different language while fixing content.
- Korean and Japanese translations add `.ko` or `.ja` before `.md`,
  such as `README.ko.md` and `docs/installation.ja.md`. Add language navigation to every document in a translated set. Link to the reader's
  language when a translation exists and identify English-only references.
- Update existing translations in the same PR as their English source.
  Preserve commands, code comments, identifiers, logs, error messages,
  exit codes, security boundaries, and verification limits in every language.
  Keep code examples identical to the English source.
- Each translation starts with a `translated-from` comment naming the source
  and its `source-blob` Git object ID. After reviewing a translation against
  an edited source, refresh that ID with `git hash-object <source-path>`.
  The ID identifies the reviewed source; it is not proof of translation quality.
- Translation coverage starts with the README, installation, and verification
  guides. Other documents remain in their current language until a reviewed
  translation is added. Keep release notes, security policies, and skill
  instructions on their existing paths; this policy adds no runtime locale.
- Write tickets, PR titles/descriptions, and internal working notes in Korean.
