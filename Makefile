# Agent Guard — discoverability layer for the existing scripts.
# Each target is a thin pass-through to install.sh or plugins/agent-guard/bin/agent-guard.

.PHONY: help check install test smoke-test bench scan scan-staged checksum submission-check

help:
	@printf 'Agent Guard — make targets\n'
	@printf '\n'
	@printf '  make help          Show this list (default).\n'
	@printf '  make check         Verify deps and print installed gitleaks version.\n'
	@printf '  make install       Configure the native git pre-commit hook.\n'
	@printf '  make test          Run the test suite (uses a mock gitleaks).\n'
	@printf '  make smoke-test    Run real git/jq/gitleaks end-to-end checks.\n'
	@printf '  make bench         Run the leak-prevention channel-coverage benchmark (real gitleaks).\n'
	@printf '  make scan          Scan the working tree for secrets.\n'
	@printf '  make scan-staged   Scan staged changes only.\n'
	@printf '  make checksum [VERSION=X.Y.Z]   Fetch gitleaks-checksum for every supported OS/arch (CI typically picks linux/x64).\n'
	@printf '  make submission-check  Validate marketplace submission documentation and metadata.\n'

check:
	@./install.sh check

install:
	@./install.sh git-hooks

test:
	@tests/run.sh

smoke-test:
	@plugins/agent-guard/bin/agent-guard smoke-test

bench:
	@sh bench/run.sh

scan:
	@plugins/agent-guard/bin/agent-guard scan-working-tree

scan-staged:
	@plugins/agent-guard/bin/agent-guard scan-staged

checksum:
	@sh plugins/agent-guard/scripts/gitleaks-checksum.sh $(VERSION)

submission-check:
	@scripts/validate-submission-readiness.sh
