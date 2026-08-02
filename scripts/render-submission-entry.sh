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

main_ref=refs/remotes/origin/main
if ! git -C "$ROOT" rev-parse --verify "$main_ref^{commit}" >/dev/null 2>&1; then
  printf 'error: cannot resolve origin/main in this checkout\n' >&2
  printf 'Fetch origin/main before rendering a submission entry.\n' >&2
  exit 1
fi

main_sha=$(git -C "$ROOT" rev-parse "$main_ref^{commit}")
if [ "$submission_sha" != "$main_sha" ]; then
  printf 'error: submission SHA %s must equal fetched remote main %s at %s\n' \
    "$submission_sha" "$main_sha" "$main_ref" >&2
  exit 1
fi

if ! "$ROOT/scripts/validate-submission-readiness.sh" >/dev/null; then
  printf 'error: submission template or stable metadata validation failed\n' >&2
  exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]; then
  printf 'error: working tree has uncommitted changes relative to %s\n' "$submission_sha" >&2
  exit 1
fi

if [ -n "$output" ]; then
  output_dir=$(dirname -- "$output")
  if [ ! -d "$output_dir" ]; then
    printf 'error: output directory does not exist: %s\n' "$output_dir" >&2
    exit 1
  fi

  output_dir_abs=$(CDPATH= cd -- "$output_dir" && pwd -P)
  output_abs="$output_dir_abs/$(basename -- "$output")"
  if [ "$output_abs" = "$ENTRY" ]; then
    printf 'error: output must not overwrite the tracked submission template\n' >&2
    exit 1
  fi

  if ! tmp_output=$(mktemp "$output_dir_abs/.agent-guard-submission.XXXXXX"); then
    printf 'error: could not create a secure temporary file in %s\n' "$output_dir_abs" >&2
    exit 1
  fi
  trap 'rm -f "$tmp_output"' EXIT HUP INT TERM
  jq --arg sha "$submission_sha" '.source.sha = $sha' "$ENTRY" >"$tmp_output"
  mv "$tmp_output" "$output"
  trap - EXIT HUP INT TERM
  printf 'submission entry written to %s for %s\n' "$output" "$submission_sha"
else
  jq --arg sha "$submission_sha" '.source.sha = $sha' "$ENTRY"
fi
