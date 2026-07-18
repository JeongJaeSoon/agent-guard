# Claude Marketplace Readiness Review

Review date: 2026-07-18

## Decision

**Official marketplace feasibility: conditional, but not currently
submittable.** Agent Guard's packaging, documentation, local validation,
license, support, and supply-chain disclosure can be made review-ready. Two
external blockers remain:

1. Anthropic's current Claude Code documentation says there is **no application
   process** for `claude-plugins-official`; inclusion is at Anthropic's
   discretion. The public submission forms feed `claude-plugins-community`, not
   the official marketplace.
2. The official repository's policy scanner fails an external plugin when any
   ungated `PreToolUse` or `PostToolUse` hook runs broadly. Agent Guard
   intentionally registers both across every enabled coding session. Changing
   that behavior would require a product decision (for example, a per-project
   enable marker), not a documentation-only submission patch.

Do not open a pull request against `anthropics/claude-plugins-official` unless an
Anthropic maintainer explicitly supplies a path. The repository automatically
closes normal external PRs; its narrow exception only permits additions from a
source repository that already backs a live marketplace entry.

## Verified source snapshot

- Agent Guard baseline: `origin/main` at `d0ad75415a36992a8e502eaaf48757f7f13074ff`,
  which includes merged PR
  [#54](https://github.com/JeongJaeSoon/agent-guard/pull/54) and its shared
  Claude Code/Codex Quick Start.
- Official repository: `anthropics/claude-plugins-official` at
  `f9cb226d81172f53a1787cc3ba90dc9ab51aa169`.
- The official repository has no root `CONTRIBUTING.md` or `SECURITY.md` at that
  snapshot. Its README, CI workflows, policy prompt, and Claude Code
  documentation are the operative public sources.

## Policy and repository findings

| Area | Current official behavior | Agent Guard fit |
|---|---|---|
| Registration path | The repository README still links a plugin submission form, but current Claude Code docs clarify that the form targets the community marketplace and that official inclusion has no application process. | **Blocker outside the repo.** Prepare artifacts, but seek curator contact or use the community route. |
| External PRs | Non-member PRs are closed unless they only add marketplace entries from a repository that already has a live entry. | **Blocker.** `JeongJaeSoon/agent-guard` is not already listed. |
| Source pinning | External sources use `url` or `git-subdir` and a full commit SHA. Automated jobs later bump the SHA and re-scan. | **Ready after push.** Use `git-subdir` with `path: plugins/agent-guard`; fill the template SHA only after the prepared commit is reachable on GitHub. |
| Name | Marketplace names are immutable kebab-case slugs. | **Ready.** `agent-guard` is stable and kebab-case. |
| Manifest | Plugin root contains `.claude-plugin/plugin.json`; components stay at plugin root. New work prefers `skills/`, while `commands/` remains supported as legacy. | **Ready with legacy note.** Manifest is valid; Claude commands remain legacy-compatible and the Codex setup workflow is a skill. |
| Hook review | External scan enumerates every hook and fails ungated `PreToolUse` or `PostToolUse` hooks. Descriptions must disclose hook scope and data access. | **Blocker.** Agent Guard's broad hooks are core behavior. Descriptions and privacy docs now disclose the scope, but disclosure does not override the scanner's broad-hook failure rule. |
| Network and telemetry | Undisclosed non-MCP outbound calls or default-on telemetry fail review. Downloads must be visible to the reviewer. | **Ready with declared flags.** Normal hooks are local and there is no telemetry. Checksum/install calls go only to GitHub Releases; the optional HTTP PII provider is off by default and fully disclosed. Expected scan flags: `may_make_external_network_calls=true`, `may_download_additional_software=true`. |
| Data and PII | Collect only data necessary for the function; remote data processing requires an accessible privacy policy. | **Ready for local mode.** Hook input/output and work-tree scope, ephemeral handling, remote PII behavior, and controls are documented in the shipped plugin payload. |
| Binary bootstrap | Review covers every shipped script. Remote software and trust boundaries must match the install description. | **Recommended improvement remains.** gitleaks install is approval-gated, versioned, and SHA-256 verified. Agent Guard release bootstrap verifies an archive checksum published beside the archive; neither path currently verifies an independent signature or provenance attestation. |
| Permissions | Workflows and integrations should use the least permissions needed. | **Ready.** Runtime hooks use local process/file access only. CI workflows declare read-only defaults except narrowly scoped release/comment jobs; third-party actions are pinned to full SHAs. |
| Platforms | Platform limitations must be disclosed. | **Ready.** macOS/Linux x64 and arm64 are supported; Windows is explicitly unsupported. |
| Tests and CI | Validate manifest/layout and behavior; official entries also receive CLI validation and policy scanning. | **Ready locally.** Deterministic tests, real gitleaks smoke tests, layout validation, marketplace validation, and a submission-readiness check are available. Broad-hook policy still fails independently. |
| License and notices | The official repo requires Apache-2.0 for vendored Anthropic plugins, while external entries retain their own linked licenses. | **Ready.** Agent Guard is MIT. Aikido demonstrates an MIT-licensed external listing. The shipped plugin now includes LICENSE and third-party notices; gitleaks/jq are not vendored. |
| Security and support | Directory policy requires verified contact, support channels, maintenance, documentation, troubleshooting, and private security reporting. | **Ready.** Maintainer URL, GitHub Issues, private vulnerability reporting, supported versions, and platform/dependency information are shipped with the plugin. |
| Listing copy | Install description must match hooks, data access, network behavior, and delivered functionality. | **Ready.** The template is concise enough for the catalog and explicitly says the hooks are broad, local by default, and no-telemetry. |

## Comparison with listed plugins

All marketplace observations below are from the pinned entries in the official
catalog, not from an unpinned upstream branch.

| Plugin | Official source form | Components and trust model | Comparison with Agent Guard |
|---|---|---|---|
| [SonarQube](https://github.com/SonarSource/sonarqube-agent-plugins) | `url`, full repository, SHA pinned | Shipped plugin hook is an unconditional `SessionStart` diagnostic. The Sonar CLI performs auth and installs project/global analysis hooks after an explicit integration step; README discloses CLI, container, MCP, and keychain requirements. | Closest hook/security peer. Its marketplace payload avoids shipped broad `PreToolUse`/`PostToolUse`; Agent Guard ships those directly, creating the main policy mismatch. |
| [Aikido](https://github.com/AikidoSec/aikido-claude-plugin) | `url`, full repository, SHA pinned | Manifest + `.mcp.json`; no hooks. Runs a version-pinned npm MCP package and connects to Aikido. MIT license and concise setup documentation. | Confirms MIT is acceptable for an external entry. Agent Guard has a larger local hook/data surface but no required account or remote service. |
| [42Crunch API Security Testing](https://github.com/42Crunch-AI/claude-plugins/tree/main/plugins/api-security-testing) | `git-subdir`, SHA pinned | Skills and documentation; no shipped lifecycle hooks. Setup downloads and verifies an external `42c-ast` binary and stores service credentials with restricted permissions. Apache-2.0. | Confirms `git-subdir` is the correct form and verified binary bootstrap is reviewable when disclosed. Agent Guard's installer is more approval-gated, but its broad hooks remain the difference. |

## Classification

### Blockers

- No public application or direct PR path to `claude-plugins-official`.
- Current official policy scan treats Agent Guard's ungated `PreToolUse` and
  `PostToolUse` hooks as a failure.
- The catalog SHA cannot be finalized until this preparation commit is pushed
  to a public ref. Do not pin an unreachable local commit.

### Recommended before any review request

- Merge and release the manifest/documentation payload, then replace the SHA
  placeholder in the entry template with the reachable 40-character commit.
- Ask Anthropic whether an always-on local security guard can receive an
  explicit policy exception or whether a per-project activation gate is
  required. Do not silently weaken the product to satisfy the scanner.
- Add independent GitHub artifact attestations or signing for Agent Guard
  release archives. Current same-release checksum verification is useful but
  does not protect against a compromised release publisher.
- Obtain at least one external macOS and one Linux plugin-install verification
  and retain sanitized results for a reviewer.

### Optional

- Add native Windows support.
- Migrate legacy Claude `commands/*.md` to user-invoked `skills/` in a separate,
  compatibility-tested release.
- Publish an SBOM for release archives.

## Submission artifacts

- Official curator entry template:
  `docs/submission/claude-plugins-official/marketplace-entry.template.json`
- Curator PR/changeset description draft:
  `docs/submission/claude-plugins-official/curator-change-description.md`
- Community form draft and realistic alternative:
  `docs/submission/claude-community/form-draft.md`
- Submission sequence: `docs/submission/README.md`

## Official sources

- [Official marketplace README](https://github.com/anthropics/claude-plugins-official)
- [External PR auto-close policy](https://github.com/anthropics/claude-plugins-official/blob/main/.github/workflows/close-external-prs.yml)
- [External PR scope logic](https://github.com/anthropics/claude-plugins-official/blob/main/.github/scripts/external-pr-scope.js)
- [Official policy scanner prompt](https://github.com/anthropics/claude-plugins-official/blob/main/.github/policy/prompt.md)
- [Official validation workflow](https://github.com/anthropics/claude-plugins-official/blob/main/.github/workflows/validate-plugins.yml)
- [Claude Code plugin submission guidance](https://code.claude.com/docs/en/plugins#submit-your-plugin-to-the-community-marketplace)
- [Plugin marketplace source and strict-mode reference](https://code.claude.com/docs/en/plugin-marketplaces)
- [Anthropic Software Directory Policy](https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy)
- [Community marketplace mirror](https://github.com/anthropics/claude-plugins-community)
