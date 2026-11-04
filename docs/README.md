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

## Performance and ongoing work

- **Packaged Rust rollout:** [qualification and measurements (한국어)](rust-packaged-validation.ko.md),
  [goal and v4 design review (한국어)](rust-experiment-goal.ko.md).
- **Earlier opt-in Rust experiment:** [한국어 graph report](rust-performance.ko.html),
  [goal and completion status](rust-experiment-goal.ko.md),
  [reproduction instructions](../bench/native/README.md),
  [raw measurements](../bench/results/rust-experiment/).
- **Earlier shell work:** [runtime review and tool compatibility fixes
  (한국어)](reports/runtime-review.ko.md) and
  [PR #360 masking measurements (한국어)](reports/masking-performance.ko.md).

Measurements describe their recorded source and environment; they are not a
claim that the current branch passed every platform gate. Release archives use
the packaged helper with shell fallback; source-only plugins require an explicit
prebuilt override. Consult the goal document for outstanding work.

## Keeping this directory useful

Update the relevant guide or report instead of creating one document per PR.
Merge short completed fix notes into their parent report. Remove superseded
plans when their unique decisions are preserved in the implementation guide or
final report; Git history retains the earlier discussion. Keep raw evidence in
`bench/results/`, and retain unresolved goals until their checks finish.

Standalone releases contain the user guides above. This index, developer notes,
experiment goals and reports are repository documentation.
