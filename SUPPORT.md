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

When the installed version provides `--output`, create one private support file
instead of attaching raw diagnostic output:

```sh
agent-guard logs export --output agent-guard-support.jsonl
```

The parent directory must already exist. This creates a new mode-0600 file and
refuses to replace an existing file or symlink. The local support log is metadata
only. Plugin-only installations may not have `agent-guard` on PATH: use the
absolute plugin-local executable printed by the host setup skill in place of
`agent-guard`. This also avoids exporting logs through an unrelated standalone
version. If export cannot run, send only the listed metadata and a manually
sanitized error summary; never substitute raw stderr or a host transcript.

The log records a random local `run_id`, version, command/event
category, host, start and finish time, exit status, and one of `pass`, `blocked`, `masked`,
`warned`, `degraded`, `error`, or `interrupted`. `pass` means the invocation returned
without blocking; it does not establish a clean scan or coverage of another
host route. The log does not record inspected content, paths, environment
variables, host session IDs, or arbitrary tool names.

## Supported environments

Agent Guard supports macOS and Linux on x64 and arm64. Runtime hooks require
`sh`, `awk`, `git`, `jq`, and gitleaks. Windows is not currently supported.
Host support and known coverage boundaries are documented in the main README.

The latest 3.x release is the actively supported line. The 2.x moving tag
receives security fixes only. General support is best effort; security reports
are acknowledged on the timeline stated in `SECURITY.md`.
