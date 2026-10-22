# Status-label classification at the appropriate test layer

This change covers only the status-label value family formerly at
`tests/run.sh` lines 11179–11282 on PR339 (`593b654`). Its 23 CLI calls contain
22 distinct inputs. The `fatal: password: 10:00:00` payload appears twice with
the same exit-0/empty-output expectation; no other variant is treated as a
duplicate.

`sh tests/unit-status-label.sh` checks all 22 unique inputs through the extracted
production `secretish_env_values` function, in JSON record mode. Literal expected
finding bytes or empty output, exit 0 and empty stderr are checked for every row.
The table does not reproduce the classifier. Literal RS/LF framing is sufficient
for these inputs, which contain neither RS nor US; producer/escaping tests remain
in their existing suites. The checked extractor rejects missing/duplicate
functions and shell syntax errors. There is no CLI startup, Git repository,
scanner or host-adapter execution in this direct suite.

| Original inputs / guarantee | Direct table IDs | Retained CLI representative |
| --- | --- | --- |
| Seven label/key/case/nesting/log-prefix combinations detect the full synthetic value | `error-password`, `warning-db`, `uppercase-client`, `fatal-api`, `info-refresh`, `nested-error`, `log-prefix` | `error: password: <value>` masks; raw value absent |
| Six non-credential shapes remain clean | `not-found`, `path`, `timestamp-local`, `clock`, `sentence-case`, `ordinary-word` | `error: secret: not-found` exits 0 with no rewrite |
| Five quoted multi-word messages remain clean | `quoted-length`, `quoted-expiry`, `quoted-profile`, `quoted-rotation`, `quoted-title` | Quoted length message exits 0 with no rewrite |
| Date prefix does not exempt a credential | `date-prefix-secret` | Date-prefixed credential is masked |
| Complete date/time forms remain clean | `date`, `timestamp-z`, `timestamp-offset`, shared `clock` row above | Complete Z timestamp exits 0 with no rewrite |

The five retained CLI cases preserve composition and response behavior while
pure variant classification lives in a readable table. Adjacent status-word
prose, JWT/scanner combination, global recurrence masking, truncation, host
response-shape, scanner failure, and size-boundary integration tests are unchanged.
This does not claim that a direct detector test proves those boundaries.

## Evidence

A temporary comparison harness ran the original 23 CLI cases and confirmed that
their unique input set equals the direct table's 22 inputs. All original cases
passed. The five retained payload/exit-status/output triples were byte-identical
to their parent counterparts. Production code is unchanged.

Three deliberately faulty, temporary production source copies were rejected:

| Selected fault | Direct failures |
| --- | ---: |
| Always classify a status-label value as clean | 8 |
| Always classify it as a credential | 14 |
| Remove the end anchor from the date exemption | 1 |

All 22 direct cases pass on the unchanged source. These selected red controls
establish sensitivity to the moved classification guarantees, not a general
mutation score, new bug fix, or whole-source coverage claim.

The family makes **23 → 5 CLI invocations**, with 22 direct assertions added.
`make test-unit` therefore has **162 direct assertions** (previously 140).
`tests/run.sh` runs the new direct suite once in partition 1 and keeps the five
CLI representatives in partition 4. Outer assertion totals decrease by 17:
18 CLI repetitions leave the full suite and one direct-suite assertion enters.
All 22 unique input classifications remain covered; inner and outer counts must
not be added as a single coverage denominator.

Local paired timing includes the original family versus the new direct suite
plus five CLI cases, using the same mock scanner and real production CLI for
retained integration checks. No passing-result cache, shared mutable fixture,
new framework, workflow, permissions or runner change is involved. Local timing
is not evidence of a hosted CI speedup. The opt-in 40-location Bash observation
remains scoped to its original four suites; it does not silently include this
new suite or expand its denominator.

Three sequential paired local runs on 2026-10-20 (seconds):

| Pair | Original: 23 CLI | Candidate: 22 direct + 5 CLI |
| --- | ---: | ---: |
| 1 | 5.1372 | 1.2312 |
| 2 | 4.6915 | 1.2622 |
| 3 | 4.8814 | 1.1954 |
| Median | 4.8814 | 1.2312 |

The family median decreased by 3.6502 seconds (74.8%) on this local host.
The timing harness did not record per-case payloads or output files; it used
only a shell builtin CLI-call counter. This small sequential sample does not
establish whole-suite, runner-time, or hosted CI savings.
