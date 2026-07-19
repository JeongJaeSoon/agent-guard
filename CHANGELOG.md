## v3.0.0 - 2026-07-19

- feat!: simplify managed deployment to settings merge plus developer setup (#122)

## v2.2.0 - 2026-07-18

- feat: add self-contained managed bootstrap (#119)

## v2.1.0 - 2026-07-18

- feat: add managed deployment for Claude Code and Codex (#117)
- docs: pin community submission source (#116)
- docs: prepare Claude marketplace submission review (#115)
- docs: lead quick start with Claude Code and Codex (#54)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.286 to 1.2.484 (#111)
- ci: bump openai/codex-action from 1.9 to 1.11 (#107)

## v2.0.1 - 2026-07-17

- fix(hooks): scan `NotebookEdit` cell content so secrets written to notebook cells are blocked (and PII when `AGENT_GUARD_PII_HOOK_MODE=block`) (#112)

## v2.0.0 - 2026-07-14

- feat(shell)!: make Claude command wrapping stable and default-on, with `--no-command-wrapping` and `AGENT_GUARD_COMMAND_WRAPPING=off` opt-outs
- feat(install): enable command wrapping from direct bootstrap and add `/agent-guard:setup-shell` for plugin installs
- docs: add the 1.x to 2.x migration guide and move GitHub Action examples to the preserved `v2` release line
- ci(release): verify publishing `v2` does not move the existing `v1` compatibility tag

## v1.10.1 - 2026-07-14

- fix(codex): verify the plugin-local binary, hook trust, and live host dispatch during guided setup
- fix(codex): use harmless dedicated sentinels for live PreToolUse and PostToolUse probes
- docs(codex): document wrapping-tool boundaries and require pre/post live probes
- fix(shell): mask bare `printenv NAME` values with their variable-name context

## v1.10.0 - 2026-07-13

- feat(codex): add guided dependency setup and host-native hook responses
- feat(shell): graduate the Claude bang-command guard to a supported opt-in

## v1.9.0 - 2026-07-07

- feat(plugin): warn on version drift between plugin hooks and the shell-integration CLI (#104)
- feat(bench): per-channel leak-prevention benchmark (#90)

## v1.8.0 - 2026-07-06

- feat(detection): catch low-entropy vendor-prefixed tokens by shape alone (#101)
- feat(detection): allow dotenv-style template files via suffix rule (#100)

## v1.7.1 - 2026-07-03

- fix(shell): make setup-shell rc line self-healing when the CLI leaves $PATH (#96)

## v1.7.0 - 2026-07-02

- feat(shell): resolve agent-guard without a PATH install for the bang guard (#94)

## v1.6.0 - 2026-07-02

- feat(shell): experimental opt-in bang-command guard (#92)

## v1.5.0 - 2026-07-01

- feat(shell): mask ! shell-escape output via agent-guard exec + shell-init (#86)
- feat(detection): broaden output secret recall (JWT, bearer, more env keys) (#85)

## v1.4.0 - 2026-07-01

- test: harden tests/run.sh temp files with mktemp (CWE-377) (#82)
- chore(changelog): drop stale Unreleased block ahead of v1.4.0 (#81)
- ci: bump actions/github-script from 7.1.0 to 9.0.0 (#71)
- ci: bump actions/checkout from 5.0.1 to 7.0.0 (#74)
- ci: bump openai/codex-action from 1.8 to 1.9 (#76)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#75)
- docs: document shell-escape hook-bypass blind spot (#80)
- feat(agent-guard): mask PII in tool output via mask mode (#78)
- feat(agent-guard): mask secret-like values in tool output (#77)
- docs(readme): lead with a Claude Code quick start to lift install conversion (#73)
- feat(plugin): add Codex composer icon for Agent Guard (#72)
- ci: add HOL plugin scanner self-scan and harden CI workflows (#68)

## v1.3.8 - 2026-06-16

- docs: separate demo steps with blank lines for readability (#66)
- docs: render README badges in a single row (#65)

## v1.3.7 - 2026-06-16

- feat(agent-guard): rename Action to a unique GitHub Marketplace name (#63)

## v1.3.6 - 2026-06-16

- feat(agent-guard): unify positioning + Action branding for Marketplace publish (#61)
- fix(agent-guard): close fail-open gaps in hook input handling and deny-read Bash scan (#60)
- fix(agent-guard): calibrate secret-detection patterns (#59)

## v1.3.5 - 2026-05-24

- Merge pull request #57 from JeongJaeSoon/codex/plugin-layout-validation-ci
- Normalize plugin validation workflow names
- Tighten plugin root variable validation
- Split plugin layout validation steps
- Add plugin layout validation CI
- Merge pull request #56 from JeongJaeSoon/codex/codex-claude-plugin-hooks
- Align Codex hooks with plugin layout
- Use host-specific plugin hooks
- Improve Codex and Claude plugin hook compatibility
- feat: add PII filtering provider adapters (#51)
- [codex] Harden agent tool input scanning (#49)
- [codex] Add Codex code review workflow (#55)
- fix install hook quoting and docs

## v1.3.4 - 2026-05-09

- docs: clarify codex plugin hook setup (#46)
- ci: use checkout v5 (#45)

## v1.3.3 - 2026-05-09

- fix: include install script in release tarball (#43)

## v1.3.2 - 2026-05-09

- Fix real user install and verification flows
- simplify: narrow PostToolUse matcher, dedupe deny-read path, guard gitleaks version drift (#40)
- docs: fix v1 raw URL for gitleaks-checksum.sh after plugin restructure (#39)

## v1.2.1 - 2026-05-08

- fix(cli): follow symlinks when resolving SCRIPT_DIR (#34)

## v1.2.0 - 2026-05-08

- docs: restructure README around user task flow (#32)
- feat: add gitleaks-checksum helper (script + subcommand + slash command) (#31)
- refactor: simplify bin/agent-guard helper functions (#30)

## v1.1.2 - 2026-05-07

- feat(plugin): add /agent-guard:verify slash command (#26)
- chore(release): make release.yml idempotent on re-dispatch (#25)
- fix(release): bump VERSION constant in bin/agent-guard on release (#24)

## v1.1.1 - 2026-05-07

- Revert "chore(release): v1.1.1 (#20)" (#22)
- fix(release): build tarball outside the directory being archived (#21)

## v1.1.0 - 2026-05-07

- Revert "chore(release): v1.1.0 (#15)" (#17)
- fix(release): exclude tarball self-reference from tar input (#16)

## v1.0.2 - 2026-05-07

- fix(release): pick latest semver tag, ignore moving major tag (#10)
- chore(release): also bump marketplace.json plugin version (#9)
- docs: add Quickstart section with plugin install paths (#8)

## v1.0.1 - 2026-05-07

- chore(release): add automated release workflow (#5)
- simplify: remove scan_text_hook, fix sub-shell exit, drop make doctor, optimize deny-pattern checks (#4)
- chore: usability and robustness pass (#3)
- [codex] Add CI and clean public-readiness scan noise (#2)
- Harden against Bash/path bypass, Codex patch parsing, symlink, and action injection (#1)
