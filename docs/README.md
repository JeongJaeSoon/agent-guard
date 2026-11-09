# Documentation

Start with the user guides. Developer contracts and historical measurements
have separate homes so that completed investigations do not obscure setup help.

## Use and operate Agent Guard

| Task | Guide |
| --- | --- |
| Install or update | [English](installation.md) · [한국어](installation.ko.md) · [日本語](installation.ja.md) |
| Verify the installed setup | [English](verification.md) · [한국어](verification.ko.md) · [日本語](verification.ja.md) |
| Understand host coverage | [Integrations](integrations.md) |
| Configure policy and masking | [Configuration](configuration.md) |
| Deploy or troubleshoot | [Operations](operations.md) |

## Develop and validate

- [Test layers and current contract inventory](development/testing.md)
- [CI partitions and historical scheduling evidence](development/ci.md)
- [Core contracts](development/unit-tests.md), [framing](development/unit-framing.md),
  [deny-path regex](development/deny-path-regex.md), and
  [status-label classification](development/status-label-tests.md)
- [Exec framing failure regression](development/exec-framing-boundary.md)
- [Scoped Bash source observations](development/coverage-core.md)
- [Rust helper, platform support and fallback](native-redactor.md)

## Measurements

Reproduction instructions for the Rust helper measurements are in
[bench/native](../bench/native/README.md). Earlier reports, experiment goals and
raw measurement runs were removed from the tree; they remain in Git history and
in the release tags (for example `v3.7.1`). Release archives use the packaged
helper with shell fallback; source-only plugins require an explicit prebuilt
override.

## Keeping this directory useful

Update the relevant guide instead of creating one document per PR. Do not
commit generated reports, raw measurement output, goal or plan notes: write them
to the ignored `bench/local/` directory, a release asset or a CI artifact.
Git history retains earlier discussion.

Standalone releases contain the user guides above. This index and the developer
notes are repository documentation.
