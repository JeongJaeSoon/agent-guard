# Documentation

Start with the user guides. Test layers, CI partitions and the contributor
workflow are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Use and operate Agent Guard

| Task | Guide |
| --- | --- |
| Install or update | [English](installation.md) · [한국어](installation.ko.md) · [日本語](installation.ja.md) |
| Verify the installed setup | [English](verification.md) · [한국어](verification.ko.md) · [日本語](verification.ja.md) |
| Understand host coverage | [Integrations](integrations.md) |
| Configure policy and masking | [Configuration](configuration.md) |
| Deploy or troubleshoot | [Operations](operations.md) |

## Develop and validate

- [Test layers, CI checks and partitions](../CONTRIBUTING.md)
- [Rust helper, platform support and fallback](native-redactor.md)
- [Opt-in warm gitleaks helper: equivalence, failures, memory](gitleaks-helper.md)

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

Standalone releases contain the user guides above. This index, CONTRIBUTING.md
and the developer guides are repository documentation.
