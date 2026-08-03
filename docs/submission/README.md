# Claude Marketplace Submission Sequence

## Routine development

Run `make submission-check` with the normal plugin layout and test suite. It
validates stable manifest, disclosure, policy-document parity, and template
metadata. It deliberately does not require a concrete `.source.sha`, so normal
payload PRs do not create documentation-only re-pin commits or need full Git
history in CI.

The community form draft and neutral marketplace-entry template keep stable
repository and plugin-path information only. Do not replace the template's
placeholder with the current branch SHA.

## Actual submission or curator handoff

1. Merge the reviewed payload into `main`, fetch `origin/main`, then check out
   that exact remote-reachable commit in a clean worktree.
2. Run `make test`, `make smoke-test`, `scripts/validate-plugin-layout.sh --all`,
   `make submission-check`, `claude plugin validate ./plugins/agent-guard`, and
   `claude plugin validate .`.
3. Prefer the public community submission form. Anthropic's catalog owns the
   immutable source pin and subsequent automated pin updates.
4. If a form or an Anthropic curator explicitly requests a concrete marketplace
   JSON entry, run `make submission-artifact SHA=<merged-main-sha>`. The command
   rejects a malformed, stale, non-HEAD, non-`origin/main`, or dirty worktree and
   renders JSON to standard output. It also revalidates the stable template and
   will not overwrite it. Treat the result as a handoff artifact; do not commit
   the generated entry back to this repository.
5. For `claude-plugins-official`, proceed only if Anthropic explicitly invites
   the plugin or provides a curator path. Resolve the broad-hook policy question
   before requesting a catalog change.

No fork, push, issue, submission, or pull request against an Anthropic
repository is performed by these repository checks.
