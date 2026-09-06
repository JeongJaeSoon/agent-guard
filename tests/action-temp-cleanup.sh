#!/usr/bin/env sh
# Execute the actual composite Action installer block with an offline download
# fixture. Only the download is mocked; archive and checksum checks are real.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-action-cleanup.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
BASH_BIN=$(command -v bash) || exit 1

mkdir "$CASE_ROOT/bin" "$CASE_ROOT/payload"
# GNU tar resolves the gzip program through PATH for -z; keep this isolated
# fixture faithful on Linux as well as on BSD tar hosts.
for dep in uname tr mktemp shasum tar gzip mkdir mv chmod rm cp; do
  dep_path=$(command -v "$dep") || exit 1
  ln -s "$dep_path" "$CASE_ROOT/bin/$dep"
done

awk '
  /^    - name: Install gitleaks if missing$/ { selected=1; next }
  selected && /^      run: \|$/ { script=1; next }
  script && /^    - name:/ { exit }
  script && /^        / { print substr($0,9) }
' "$ROOT/action.yml" >"$CASE_ROOT/install.sh"
[ -s "$CASE_ROOT/install.sh" ] || exit 1

printf '#!/bin/sh\nprintf "offline scanner fixture\\n"\n' >"$CASE_ROOT/payload/gitleaks"
printf 'archive documentation\n' >"$CASE_ROOT/payload/README"
printf 'archive license\n' >"$CASE_ROOT/payload/LICENSE"
tar -czf "$CASE_ROOT/archive.tar.gz" -C "$CASE_ROOT/payload" gitleaks README LICENSE || exit 1
checksum=$(shasum -a 256 "$CASE_ROOT/archive.tar.gz" | awk '{print $1}')

cat >"$CASE_ROOT/bin/curl" <<'MOCK'
#!/bin/sh
case "$ACTION_DOWNLOAD_MODE" in
  failure) exit 22 ;;
  term) kill -TERM "$PPID"; exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    cp "$ACTION_ARCHIVE" "$1"
    exit $?
  fi
  shift
done
exit 2
MOCK
chmod +x "$CASE_ROOT/bin/curl"

failed=0
checked=0
run_case() {
  label=$1
  expected=$2
  supplied_checksum=$3
  mode=$4
  case_dir="$CASE_ROOT/$label"
  mkdir "$case_dir" "$case_dir/downloads" "$case_dir/runner"
  : >"$case_dir/github-path"
  env PATH="$CASE_ROOT/bin" TMPDIR="$case_dir/downloads" \
    RUNNER_TEMP="$case_dir/runner" GITHUB_PATH="$case_dir/github-path" \
    AGENT_GUARD_GITLEAKS_VERSION=8.30.1 AGENT_GUARD_REQUIRE_CHECKSUM=true \
    AGENT_GUARD_GITLEAKS_CHECKSUM="$supplied_checksum" \
    ACTION_DOWNLOAD_MODE="$mode" ACTION_ARCHIVE="$CASE_ROOT/archive.tar.gz" \
    "$BASH_BIN" "$CASE_ROOT/install.sh" >"$case_dir/out" 2>"$case_dir/err"
  actual=$?
  checked=$((checked + 1))
  if [ "$actual" -eq "$expected" ] && [ -z "$(ls -A "$case_dir/downloads")" ]; then
    printf 'ok - %s preserves exit %s and removes download workspace\n' "$label" "$expected"
  else
    printf 'not ok - %s (exit %s expected %s, remaining download entries: %s)\n' \
      "$label" "$actual" "$expected" "$(ls -A "$case_dir/downloads")"
    sed 's/^/  stderr: /' "$case_dir/err"
    failed=$((failed + 1))
  fi
  checked=$((checked + 1))
  if [ "$expected" -eq 0 ]; then
    if [ -x "$case_dir/runner/agent-guard-bin/gitleaks" ] \
       && [ "$(cat "$case_dir/github-path")" = "$case_dir/runner/agent-guard-bin" ] \
       && [ "$("$case_dir/runner/agent-guard-bin/gitleaks")" = 'offline scanner fixture' ]; then
      printf 'ok - success retains executable and publishes its installation path\n'
    else
      printf 'not ok - success lost the installed executable or path\n'
      failed=$((failed + 1))
    fi
  elif [ ! -e "$case_dir/runner/agent-guard-bin/gitleaks" ] && [ ! -s "$case_dir/github-path" ]; then
    printf 'ok - %s publishes no incomplete installation\n' "$label"
  else
    printf 'not ok - %s published an incomplete installation\n' "$label"
    failed=$((failed + 1))
  fi
}

run_case success 0 "$checksum" success
run_case checksum-mismatch 1 0000000000000000000000000000000000000000000000000000000000000000 success
run_case download-failure 22 "$checksum" failure
run_case terminated-download 143 "$checksum" term

printf '%s Action cleanup checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]
