#!/bin/sh
# A workflow_dispatch run (the release gate dispatches CI at the release SHA)
# must never share a cancellable concurrency group; only PR and main-push runs
# may be replaced by a newer run.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
checked=0
for wf in "$ROOT"/.github/workflows/*.yml; do
  name=$(basename "$wf")
  block=$(awk '/^concurrency:/ { on = 1; next } on && /^[^ ]/ { exit } on' "$wf")
  [ -n "$block" ] || continue
  group=$(printf '%s\n' "$block" | sed -n 's/^  group: //p')
  cancel=$(printf '%s\n' "$block" | sed -n 's/^  cancel-in-progress: //p')
  [ -n "$group" ] && [ -n "$cancel" ] || fail "$name: concurrency needs group and cancel-in-progress"
  case "$cancel" in false) checked=$((checked + 1)); continue ;; true) fail "$name: cancel-in-progress is unconditional" ;; esac
  # Every event the cancel expression names must be a replaceable one.
  events=$(printf '%s\n' "$cancel" | grep -o "github[.]event_name == '[a-z_]*'" | sed "s/.*== '//; s/'//")
  [ -n "$events" ] || fail "$name: cancel-in-progress expression names no event"
  if printf '%s\n' "$events" | grep -Evxq 'pull_request|push'; then
    fail "$name: cancel-in-progress covers a non-PR, non-push event"
  fi
  # A manual run keeps a unique group.
  if grep -q '^  workflow_dispatch:' "$wf"; then
    case "$group" in *github.run_id*) ;; *) fail "$name: group lacks the github.run_id fallback for manual runs" ;; esac
  fi
  case "$group" in
    *github.ref*)
      case "$group" in *"github.event_name == 'push' && github.ref"*) ;; *) fail "$name: github.ref in group is not guarded by the push event" ;; esac
      case "$group" in *github.event_name*) ;; *) fail "$name: group must include the event name" ;; esac ;;
  esac
  checked=$((checked + 1))
done
[ "$checked" -ge 10 ] || fail "only $checked workflows checked"

# The macOS workflows that run on main pushes must replace superseded pushes.
for name in ci native-platforms native-redaction; do
  wf="$ROOT/.github/workflows/$name.yml"
  grep -Fq "github.event_name == 'push' && github.ref" "$wf" || fail "$name.yml: main push runs are not grouped by ref"
  grep -Fq 'cancel-in-progress: ${{ github.event_name == '"'pull_request'"' || github.event_name == '"'push'"' }}' "$wf" || fail "$name.yml: main push runs do not cancel superseded runs"
done
printf 'ok - dispatch runs never share a cancellable group (%s workflows)\n' "$checked"
