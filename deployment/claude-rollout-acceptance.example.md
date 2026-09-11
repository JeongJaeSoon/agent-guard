# Managed Claude Code rollout acceptance record

Copy this table into the approved change ticket for each cohort. Keep one row
per enrolled device. Use an internal inventory ID rather than a user name, and
do not paste prompts, transcripts, paths, stderr, environment values, or secret
material into this record.

## Rollout control

| Field | Value |
| --- | --- |
| Rollout owner | |
| Rollback owner | |
| Approved Agent Guard tag | |
| Previous reviewed tag | |
| Cohort target | 2–3 / 10 / 20 / 50 / 100 |
| Cohort start time and time zone | |
| Minimum observation end | |
| Change ticket | |

## Device acceptance

| Inventory ID | OS/arch | Claude version | Guard version | Managed source/tag verified | Setup/check/smoke | LIVE pre `blocked` | LIVE post `masked` | Normal command `pass` | Log storage ready | Safe export has 3 outcomes | Accepted at | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | | | |

Use `pass`, `fail`, or `unverified` for every evidence cell. A blank or
`unverified` cell does not pass. The three outcome columns refer to the
metadata-only JSONL export, not to raw host output. Use only synthetic probe
markers from the setup skill.

## Cohort decision

- Expand only when every target device has `pass` for all required evidence,
  the minimum observation period has elapsed, and no unresolved `DEGRADED`, raw
  marker exposure, unexpected block, missing log, or version/source drift
  remains.
- Otherwise stop expansion, assign an owner and sanitized issue reference, and
  use the recorded previous tag for rollback if the rollout owner decides it is
  necessary.
- Run Codex acceptance in a separate record. Replace the managed source/tag
  column with per-user hook trust for the exact installed hook definitions.
