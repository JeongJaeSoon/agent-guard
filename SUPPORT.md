# Support

## Getting help

- Usage questions, bug reports, and feature requests:
  [GitHub Issues](https://github.com/JeongJaeSoon/agent-guard/issues)
- Maintainer contact and project ownership:
  [JeongJaeSoon on GitHub](https://github.com/JeongJaeSoon)
- Sensitive security reports: follow the private process in
  [SECURITY.md](SECURITY.md). Do not disclose a vulnerability in a public issue.

When reporting a problem, include the Agent Guard version, host (Claude Code,
Codex, CLI, Git hook, or GitHub Actions), operating system and architecture,
the command or hook event involved, and sanitized output. Never include live
credentials, private keys, or unredacted personal data.

## Supported environments

Agent Guard supports macOS and Linux on x64 and arm64. Runtime hooks require
`sh`, `awk`, `git`, `jq`, and gitleaks. Windows is not currently supported.
Host support and known coverage boundaries are documented in the main README.

The latest 3.x release is the actively supported line. The 2.x moving tag
receives security fixes only. General support is best effort; security reports
are acknowledged on the timeline stated in `SECURITY.md`.
