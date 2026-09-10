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
the command or hook-event category, outcome, and a manually sanitized error
summary. Never include live credentials, private keys, prompts, transcripts,
raw stderr, full hook payloads, paths, environment variables, session IDs, or
unredacted personal data.

If your installed version provides it, attach the output of
`agent-guard logs export` instead of raw diagnostic output. The local support
log is metadata only: it records version, command/event category, host, start
and finish time, exit status, and one of `pass`, `blocked`, `masked`,
`degraded`, `error`, or `interrupted`. `pass` means the invocation returned
without blocking; it does not establish a clean scan or coverage of another
host route. The log does not record inspected content, paths, environment
variables, session IDs, or arbitrary tool names.

## Supported environments

Agent Guard supports macOS and Linux on x64 and arm64. Runtime hooks require
`sh`, `awk`, `git`, `jq`, and gitleaks. Windows is not currently supported.
Host support and known coverage boundaries are documented in the main README.

The latest 3.x release is the actively supported line. The 2.x moving tag
receives security fixes only. General support is best effort; security reports
are acknowledged on the timeline stated in `SECURITY.md`.
