# Documentation

Start with the user guides. Contributor workflow, test layers and CI partitions
are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Use and operate Agent Guard

| Task | Guide |
| --- | --- |
| Install or update | [English](installation.md) · [한국어](installation.ko.md) · [日本語](installation.ja.md) |
| Verify the installed setup | [English](verification.md) · [한국어](verification.ko.md) · [日本語](verification.ja.md) |
| Understand host coverage | [Integrations](integrations.md) |
| Configure policy and masking | [Configuration](configuration.md) |
| Deploy or troubleshoot | [Operations](operations.md) |
| Speed up scans with the opt-in warm gitleaks helper | [Warm gitleaks helper](gitleaks-helper.md) (English) |

## Keeping this directory useful

Update the relevant guide instead of creating one document per PR. Do not
commit generated reports, raw measurement output, goal or plan notes: write them
to the ignored `bench/local/` directory, a release asset or a CI artifact.

Standalone releases contain the user guides in the table above except the warm
gitleaks helper guide, which source builds use. This index and CONTRIBUTING.md
are repository documentation.
