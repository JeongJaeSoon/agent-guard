# Agent Guard — make targets for the test suite, CI and marketplace submission.
# Each target is a thin pass-through to an existing script or the CLI.

.PHONY: help test test-unit test-pleno-integration smoke-test submission-check submission-artifact

help:
	@printf 'Agent Guard — make targets\n'
	@printf '\n'
	@printf '  make help          Show this list (default).\n'
	@printf '  make test          Run the test suite (mock gitleaks; rule suites need a real one).\n'
	@printf '  make test-unit     Run fast direct contracts (suite inventory: CONTRIBUTING.md).\n'
	@printf '  make test-pleno-integration  Run opt-in tests against a real pleno endpoint.\n'
	@printf '  make smoke-test    Run real git/jq/gitleaks end-to-end checks.\n'
	@printf '  make submission-check  Validate plugin disclosures and marketplace metadata.\n'
	@printf '  make submission-artifact SHA=<merged-main-sha>  Render an optional SHA-pinned marketplace entry.\n'

test:
	@tests/run.sh
	@sh tests/real-gitleaks-rules.sh

test-unit:
	@sh tests/unit-core.sh
	@sh tests/unit-framing.sh
	@sh tests/unit-deny-path.sh
	@sh tests/unit-probe.sh
	@sh tests/unit-watchdog.sh
	@sh tests/unit-audit-retention.sh
	@sh tests/unit-status-label.sh
	@sh tests/redaction-plan.sh
	@sh tests/unit-nul-redaction.sh
	@sh tests/unit-quoted-words.sh

test-pleno-integration:
	@tests/run-pleno-integration.sh

smoke-test:
	@plugins/agent-guard/bin/agent-guard smoke-test

submission-check:
	@scripts/validate-submission-readiness.sh

submission-artifact:
	@AGENT_GUARD_SUBMISSION_SHA="$(SHA)" scripts/render-submission-entry.sh
