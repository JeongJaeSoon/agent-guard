#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ENTRY="$ROOT/docs/submission/marketplace-entry.template.json"
submission_sha=${AGENT_GUARD_SUBMISSION_SHA:-}
output=${AGENT_GUARD_SUBMISSION_OUTPUT:-}

if ! printf '%s\n' "$submission_sha" | grep -Eq '^[0-9a-f]{40}$'; then
  printf 'error: AGENT_GUARD_SUBMISSION_SHA must be a full 40-character commit SHA\n' >&2
  exit 1
fi

if ! git -C "$ROOT" rev-parse "$submission_sha^{commit}" >/dev/null 2>&1; then
  printf 'error: submission commit %s is not present in this checkout\n' "$submission_sha" >&2
  exit 1
fi

head_sha=$(git -C "$ROOT" rev-parse HEAD)
if [ "$submission_sha" != "$head_sha" ]; then
  printf 'error: submission SHA %s must match checked-out HEAD %s\n' "$submission_sha" "$head_sha" >&2
  printf 'Generate the artifact from the merged main commit, not a pre-merge or stale payload.\n' >&2
  exit 1
fi

main_ref=
for candidate in refs/remotes/origin/main refs/heads/main; do
  if git -C "$ROOT" rev-parse --verify "$candidate^{commit}" >/dev/null 2>&1; then
    main_ref=$candidate
    break
  fi
done
if [ -z "$main_ref" ]; then
  printf 'error: cannot resolve origin/main or local main in this checkout\n' >&2
  printf 'Fetch or check out the merged main commit before rendering a submission entry.\n' >&2
  exit 1
fi

main_sha=$(git -C "$ROOT" rev-parse "$main_ref^{commit}")
if [ "$submission_sha" != "$main_sha" ]; then
  printf 'error: submission SHA %s must equal merged main %s at %s\n' \
    "$submission_sha" "$main_sha" "$main_ref" >&2
  exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all -- plugins/agent-guard)" ]; then
  printf 'error: plugins/agent-guard has uncommitted changes relative to %s\n' "$submission_sha" >&2
  exit 1
fi

if [ -n "$output" ]; then
  output_dir=$(dirname -- "$output")
  if [ ! -d "$output_dir" ]; then
    printf 'error: output directory does not exist: %s\n' "$output_dir" >&2
    exit 1
  fi
  tmp_output="$output.tmp.$$"
  trap 'rm -f "$tmp_output"' EXIT HUP INT TERM
  jq --arg sha "$submission_sha" '.source.sha = $sha' "$ENTRY" >"$tmp_output"
  mv "$tmp_output" "$output"
  trap - EXIT HUP INT TERM
  printf 'submission entry written to %s for %s\n' "$output" "$submission_sha"
else
  jq --arg sha "$submission_sha" '.source.sha = $sha' "$ENTRY"
fi
