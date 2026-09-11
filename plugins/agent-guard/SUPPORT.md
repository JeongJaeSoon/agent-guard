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

In v3.4.0 and later, attach the output of `agent-guard logs export` instead of
raw diagnostic output. The local support log is metadata only. After Claude's
`/agent-guard:setup-shell` completes and a bash or zsh terminal is restarted,
the plugin-local CLI is available as `agent-guard`. Before that restart, when
shell setup failed, or from fish, use the plugin-local executable path printed
by the setup skill in place of `agent-guard`. This also avoids exporting logs
through an unrelated standalone version.

If export reports that `jq` is missing, storage is unavailable, the file is
empty after reproducing the event, or only a start record exists, rerun the host
setup skill and approve the dependency or storage repair it proposes. Until a
safe export succeeds, report only the version, host, OS/architecture, time and
time zone, coarse outcome, and a manually sanitized error summary. Do not send
raw stderr, a transcript, environment output, or the original input as a
substitute.

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
