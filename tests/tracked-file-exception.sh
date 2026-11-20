#!/usr/bin/env sh
# Synthetic hook inputs only: none of the fixture commands is executed, and
# every file below is written here with placeholder text.
# A file committed to the repository that holds the event workdir is not
# blocked by a deny-read name pattern (the tracked-file exception). Everything
# else keeps its block: an untracked, ignored, only staged or locally changed
# file, a symlink,
# a path that leaves the repository, a directory-anchored location, another
# repository, a command that does not open the path it names from its own
# directory, a git that cannot answer, and the switch set to anything but on.
# Each Bash fixture runs through both hosts' native event shapes; the file
# tool fixtures use the Claude shape, since Codex reads files with the shell.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=${AGENT_GUARD_TEST_FIXTURE:-$ROOT/tests/fixtures/tracked-file-exception.json}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-tracked.XXXXXX") || exit 1
CASE_ROOT=$(CDPATH= cd -P -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export HOME="$CASE_ROOT/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_TRACKED_FILE_EXCEPTION AGENT_GUARD_DENY_READ_MODE
REPO=$CASE_ROOT/repo
OUTSIDE=$CASE_ROOT/outside
OTHER=$CASE_ROOT/other
mkdir -p "$HOME" "$REPO/tests/fixtures" "$REPO/config" "$REPO/.aws" "$OUTSIDE" "$OTHER" "$CASE_ROOT/nogit"

git_quiet() {
  git -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1
}
placeholder() {
  for placeholder_path in "$@"; do
    printf 'name: placeholder\n' >"$placeholder_path" || return 1
  done
}

placeholder "$OUTSIDE/settings.env" "$OTHER/settings.env" "$REPO/README.md" \
  "$REPO/tests/fixtures/secrets.yaml" "$REPO/config/staging.env" \
  "$REPO/tests/credentials.json" "$REPO/tests/app.env.test" \
  "$REPO/settings.env" "$REPO/swapped.env" "$REPO/modified.env" "$REPO/.aws/credentials" \
  "$REPO/local.env" "$REPO/.env" "$REPO/staged.env" || exit 1
printf '.env\n' >"$REPO/.gitignore"
ln -s ../outside/settings.env "$REPO/link.env"
(
  cd "$REPO" && git_quiet init -q . \
    && git_quiet add .gitignore README.md tests config settings.env swapped.env modified.env .aws link.env \
    && git_quiet commit -q -m fixture \
    && git_quiet add staged.env
) || { printf 'not ok - could not build the fixture repository\n'; exit 1; }
(cd "$OTHER" && git_quiet init -q . && git_quiet add settings.env && git_quiet commit -q -m fixture) \
  || { printf 'not ok - could not build the second fixture repository\n'; exit 1; }
ln -s ../outside "$REPO/linkdir"
printf 'name: filled in locally\n' >"$REPO/modified.env"
rm -f "$REPO/swapped.env" && ln -s ../outside/settings.env "$REPO/swapped.env"
# A git that cannot answer: the first PATH entry of the `git: fails` cases.
printf '#!/bin/sh\nexit 1\n' >"$CASE_ROOT/nogit/git" && chmod +x "$CASE_ROOT/nogit/git"

failed=0
checked=0
jq -e 'type == "array" and length > 0' "$FIXTURE" >/dev/null || {
  printf 'not ok - %s is not a non-empty array\n' "$FIXTURE"
  exit 1
}
# Every must-pass case is followed directly by a must-still-block case.
jq -e '. as $all | all(range(0; length); . as $i
         | $all[$i].classification == "must-still-block"
           or ($all[$i].classification == "must-pass"
               and ($all[$i + 1].classification // "") == "must-still-block"))' "$FIXTURE" >/dev/null || {
  printf 'not ok - every must-pass case in %s needs a must-still-block case right after it\n' "$FIXTURE"
  exit 1
}
jq -c --arg repo "$REPO" --arg outside "$OUTSIDE" --arg other "$OTHER" '
  def fill: gsub("@REPO@"; $repo) | gsub("@OUTSIDE@"; $outside) | gsub("@OTHER@"; $other);
  .[] | .workdir = ((if .workdir == null then "@REPO@" else .workdir end) | fill)
      | if .command then .command |= fill else . end
      | if .inner_workdir then .inner_workdir |= fill else . end
      | if .path then .path |= fill else . end' "$FIXTURE" >"$CASE_ROOT/cases" || exit 1
while IFS= read -r row; do
  expected=$(printf '%s' "$row" | jq -r '.expected_status')
  name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
  tool=$(printf '%s' "$row" | jq -r '.tool // "Bash"')
  case_env=$(printf '%s' "$row" | jq -r '.env // "AGENT_GUARD_TEST_UNUSED=1"')
  case_path=$PATH
  [ "$(printf '%s' "$row" | jq -r '.git // ""')" != fails ] || case_path=$CASE_ROOT/nogit:$PATH
  case "$tool" in
    Bash) hosts='claude codex' ;;
    *) hosts=claude ;;
  esac
  for host in $hosts; do
    case "$tool:$host" in
      Bash:codex) shape='{tool_name:"Bash",tool_input:({command:.command} + (if .workdir == "" then {} else {workdir:.workdir} end))}' ;;
      Bash:*) shape='{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:({command:.command} + (if .inner_workdir then {workdir:.inner_workdir} else {} end))} + (if .workdir == "" then {} else {cwd:.workdir} end)' ;;
      Read:*) shape='{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:({file_path:.path} + (if .inner_workdir then {cwd:.inner_workdir} else {} end)),cwd:.workdir}' ;;
      NotebookRead:*) shape='{hook_event_name:"PreToolUse",tool_name:"NotebookRead",tool_input:{notebook_path:.path},cwd:.workdir}' ;;
      Grep:*) shape='{hook_event_name:"PreToolUse",tool_name:"Grep",tool_input:({pattern:"placeholder",path:.path} + (if .glob then {glob:.glob} else {} end)),cwd:.workdir}' ;;
      *) printf 'not ok - %s: unknown tool %s\n' "$name" "$tool"; failed=$((failed + 1)); continue ;;
    esac
    checked=$((checked + 1))
    printf '%s' "$row" | jq -c "$shape" \
      | (cd "$REPO" && env "$case_env" PATH="$case_path" AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool) \
        >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    status=$?
    if [ "$status" -eq "$expected" ]; then
      printf 'ok - [%s] %s\n' "$host" "$name"
    else
      printf 'not ok - [%s] %s: expected %s got %s\n' "$host" "$name" "$expected" "$status"
      sed 's/^/#   /' "$CASE_ROOT/err"
      failed=$((failed + 1))
    fi
  done
done <"$CASE_ROOT/cases"
printf '%s tracked-file exception checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]
