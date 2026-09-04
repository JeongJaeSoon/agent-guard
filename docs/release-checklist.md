# Release verification checklist

Run these checks from a clean checkout before publishing a release. Do not
replace the local checks with a green status badge.

## Local, read-only checks

```sh
make check
tests/run.sh
scripts/validate-plugin-layout.sh
scripts/validate-submission-readiness.sh
```

Confirm that the CLI, both plugin manifests, marketplace metadata, managed
settings, and `CHANGELOG.md` carry the same semver. Generate the formula only
from the SHA-256 of the exact release tarball:

```sh
make formula VERSION=X.Y.Z SHA=<sha256>
```

## External release checks

After publishing, verify the release contains the tarball, its `.sha256` file,
`agent-guard.rb`, `bootstrap.sh`, and `install.sh`. From a disposable machine,
run the bootstrap installer, then `agent-guard doctor`, `agent-guard check`, and
`agent-guard smoke-test`. Do not delete a previous install until the new binary
and its policy files are complete.

## Host checks

- Claude Code: reload the plugin, trust every changed hook, and verify a live
  PreToolUse block plus PostToolUse redaction.
- Codex: review and trust changed hooks, then verify Agent and legacy Task
  inputs plus the current shell execution route.
- GitHub Actions: run the pinned scanner job and confirm the real-gitleaks
  integration assertions are present in the log.
- Homebrew: add the generated formula to a tap, install it through the tap, and
  confirm `agent-guard version` reports the release version without wrapper
  recursion.

If any host check is unavailable, report it as unverified rather than inferring
success from plugin layout or unit tests.
