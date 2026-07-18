# Claude Marketplace Submission Sequence

1. Run `make test`, `make smoke-test`, `scripts/validate-plugin-layout.sh --all`,
   `make submission-check`, `claude plugin validate ./plugins/agent-guard`, and
   `claude plugin validate .`.
2. Commit the preparation changes in Agent Guard. Push and merge them only in
   the Agent Guard repository, then publish a release if the manifest version
   changed.
3. Resolve the reachable 40-character GitHub commit SHA that contains the exact
   plugin payload under `plugins/agent-guard`. The prepared submission pins
   `bdf51638652db846e1b19aa28f99cfa2d3f337e3`, merged through Agent Guard
   [PR #115](https://github.com/JeongJaeSoon/agent-guard/pull/115).
4. Re-run `make submission-check` with
   `AGENT_GUARD_SUBMISSION_SHA=bdf51638652db846e1b19aa28f99cfa2d3f337e3`.
   If the plugin payload changes, replace the pinned SHA in both submission
   drafts and validate the new reachable commit before submitting.
5. For the public community route, submit the form draft through the Console
   form (available to individual authors) or the claude.ai Team/Enterprise form.
   Do not open a PR against the community mirror.
6. For `claude-plugins-official`, proceed only if Anthropic explicitly invites
   the plugin or provides a curator path. Send the entry and change-description
   drafts, and resolve the broad-hook policy question before requesting a
   catalog change.

No fork, push, issue, submission, or pull request against an Anthropic
repository is part of this preparation bundle.
