#!/bin/sh
# A Codex session or a review session stays out of containers it does not own
# (docker, podman, nerdctl and their compose forms): no command that names a
# stack listed in protected-containers.txt, no database client through a
# container exec, and no container exec whose target cannot be read from the
# command text. A plain Claude session keeps every one of these commands.
#
# Ground truth: each row also runs for real against a stub runtime that only
# records its arguments, standard input, directory and compose project. What
# the stub was asked to do must be what the row declares, so a blocked row is a
# live shape and an allowed row reaches neither a protected stack nor a
# database client. No real container runtime is started.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-container.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
# The session that runs this suite may carry these itself.
unset AGENT_GUARD_SESSION_ROLE AGENT_GUARD_HOOK_HOST COMPOSE_PROJECT_NAME

STACK=verify-demo-20260101-000000-12345
CLIENTS='psql|pg_dump|pg_dumpall|pg_restore|mysql|mysqldump|mariadb|mariadb-dump|mongosh|mongo|mongodump|mongoexport|redis-cli|valkey-cli|sqlite3|clickhouse-client|clickhouse|cqlsh|sqlcmd'
W="$CASE/w"
STUB="$CASE/stub"
mkdir -p "$W/bin" "$STUB" "$CASE/run-home" "$CASE/stacks/$STACK"

# The policy homes: the stack listed, the same list after a commented-out name
# and a blank line, padded and with CRLF line ends, no list at all, and a list
# that is not a readable file.
LISTED="$CASE/home"
PADDED="$CASE/home-padded"
UNLISTED="$CASE/home-unlisted"
BROKEN="$CASE/home-broken"
mkdir -p "$LISTED/.config/agent-guard" "$PADDED/.config/agent-guard" \
  "$UNLISTED/.config/agent-guard" "$BROKEN/.config/agent-guard/protected-containers.txt"
printf '%s\n' "$STACK" >"$LISTED/.config/agent-guard/protected-containers.txt"
printf '#other-app-1\r\n\r\n  %s \r\n' "$STACK" \
  >"$PADDED/.config/agent-guard/protected-containers.txt"
POLICY_HOME=$LISTED

cat >"$STUB/docker" <<'EOF'
#!/bin/sh
{
  printf 'call %s cwd=%s project=%s\n' "${0##*/}" "$PWD" "${COMPOSE_PROJECT_NAME-}"
  for a in "$@"; do printf 'arg %s\n' "$a"; done
  [ -t 0 ] || sed 's/^/stdin /'
} >>"$STUB_LOG"
case " $* " in *' ps '*) printf '%s\n' "$STUB_PS" ;; esac
exit 0
EOF
chmod +x "$STUB/docker"
for name in podman nerdctl docker-compose; do cp "$STUB/docker" "$STUB/$name"; done
cp "$STUB/docker" "$W/bin/docker"

pass=0 fail=0 n=0 reached=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

hook() { # $1 session kind, $2 command, $3 directory; sets status, stderr in $CASE/err
  h_host=claude h_role= h_agent= h_project=
  case $1 in
    codex) h_host=codex ;;
    codex-project) h_host=codex h_project=$STACK ;;
    review-env) h_role=review ;;
    review-agent) h_agent=code-reviewer ;;
    plain) ;;
    plain-agent) h_agent=Explore ;;
    plain-role) h_role=build ;;
    *) printf 'unknown session kind %s\n' "$1" >&2; exit 1 ;;
  esac
  jq -nc --arg c "$2" --arg d "$3" --arg a "$h_agent" --arg h "$h_host" '
    {session_id: "container-rows", hook_event_name: "PreToolUse", tool_name: "Bash",
     tool_input: {command: $c}, cwd: $d}
    + (if $h == "codex" then {turn_id: "turn-1", tool_use_id: "call-1"} else {} end)
    + (if $a == "" then {} else {agent_id: "agent-1", agent_type: $a} end)' \
    | env HOME="$POLICY_HOME" AGENT_GUARD_HOOK_HOST="$h_host" \
        ${h_role:+AGENT_GUARD_SESSION_ROLE="$h_role"} ${h_project:+COMPOSE_PROJECT_NAME="$h_project"} \
        "$BIN" hook-pre-tool >/dev/null 2>"$CASE/err"
  status=$?
}

reach() { # $1 command, $2 directory, $3 session compose project: stack, db or none
  : >"$CASE/log"
  (cd "$2" && env -i PATH="$STUB:/usr/bin:/bin" HOME="$CASE/run-home" STUB_LOG="$CASE/log" \
      STUB_PS="$STACK-db-1" TARGET="$STACK-db-1" PROJECT="$STACK" ${3:+COMPOSE_PROJECT_NAME="$3"} \
      sh -c "$1" </dev/null >/dev/null 2>&1)
  if grep -Fq -e "$STACK" "$CASE/log"; then
    echo stack
  elif grep -Eq -e "^(arg|stdin) (.*[^[:alnum:]_-])?($CLIENTS)([^[:alnum:]_-]|\$)" "$CASE/log"; then
    echo db
  else
    echo none
  fi
}

truth() { # $1 declared reach (skip: not run), $2 command, $3 directory, $4 session kind
  [ "$1" != skip ] || return 0
  t_project=
  [ "$4" != codex-project ] || t_project=$STACK
  t_got=$(reach "$2" "$3" "$t_project")
  [ "$t_got" = none ] || reached=$((reached + 1))
  if [ "$t_got" = "$1" ]; then
    ok "row $n: run for real it reaches $1"
  else
    bad "row $n: run for real it reaches $t_got, declared $1: $2"
    sed 's/^/  stub: /' "$CASE/log"
  fi
}

held() { # $1 session kind, $2 reason, $3 reach, $4 command, [$5 directory]
  n=$((n + 1))
  h_dir=${5:-$W}
  hook "$1" "$4" "$h_dir"
  if [ "$status" -eq 2 ] && [ "$(grep -c '' "$CASE/err")" -eq 1 ] \
     && grep -Fq "reason=$2;" "$CASE/err" && ! grep -Fq "$STACK" "$CASE/err"; then
    ok "row $n: a $1 session is held for $2"
  else
    bad "row $n: a $1 session should be held for $2, got status $status: $4"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
  hook plain "$4" "$h_dir"
  if [ "$status" -eq 0 ]; then
    ok "row $n: a plain Claude session keeps it"
  else
    bad "row $n: a plain Claude session lost it (status $status): $4"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
  truth "$3" "$4" "$h_dir" "$1"
}

free() { # $1 session kind, $2 reach, $3 command, [$4 directory]
  n=$((n + 1))
  f_dir=${4:-$W}
  hook "$1" "$3" "$f_dir"
  if [ "$status" -eq 0 ]; then
    ok "row $n: a $1 session keeps it"
  else
    bad "row $n: a $1 session lost it (status $status): $3"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
  truth "$2" "$3" "$f_dir" "$1"
}

DB="$STACK-db-1"
NL='
'

# A command that names a listed stack, from each kind of restricted session.
for kind in codex review-env review-agent; do
  held "$kind" bash_container_protected_stack stack "docker exec $DB ls /"
  held "$kind" bash_container_protected_stack stack "docker compose -p $STACK exec db ls"
done
held codex bash_container_protected_stack stack "docker exec -it $DB sh -c 'ls /'"
held codex bash_container_protected_stack stack "docker container exec $DB ls"
held codex bash_container_protected_stack stack "docker compose --project-name=$STACK exec -T db ls"
held codex bash_container_protected_stack stack "COMPOSE_PROJECT_NAME=$STACK docker compose exec db ls"
held codex bash_container_protected_stack stack "export COMPOSE_PROJECT_NAME=$STACK${NL}docker compose exec db ls"
held codex bash_container_protected_stack stack "docker-compose -p $STACK exec db ls"
held codex bash_container_protected_stack stack "podman exec $DB ls"
held codex bash_container_protected_stack stack "nerdctl exec $DB ls"
held codex bash_container_protected_stack stack "./bin/docker exec $DB ls"
held codex bash_container_protected_stack stack "sh -c 'docker exec $DB ls'"
held codex bash_container_protected_stack stack "docker exec \"$DB\" ls"
held codex bash_container_protected_stack stack "'docker' exec $DB ls"
# Not only exec: any verb of the runtime.
held codex bash_container_protected_stack stack "docker logs --tail 50 $DB"
held codex bash_container_protected_stack stack "docker inspect $DB"
held codex bash_container_protected_stack stack "docker cp $DB:/etc/hostname ."
held codex bash_container_protected_stack stack "docker ps --filter name=$STACK"
# The compose project comes from the directory or from the session.
held codex bash_container_protected_stack stack "docker compose exec db ls" "$CASE/stacks/$STACK"
held codex bash_container_protected_stack stack "cd $CASE/stacks/$STACK && docker compose exec db ls"
held codex-project bash_container_protected_stack stack "docker compose exec db ls"
# The list is read with comments, blank lines, padding and CRLF line ends.
POLICY_HOME=$PADDED
held codex bash_container_protected_stack stack "docker exec $DB ls /"
free codex none 'docker logs other-app-1 #other-app-1'
POLICY_HOME=$LISTED

# A database client through a container exec, whatever the container.
for kind in codex review-env review-agent; do
  held "$kind" bash_container_db_client db "docker exec other-db-1 psql -U app -c 'select 1'"
done
for client in $(printf '%s' "$CLIENTS" | tr '|' ' '); do
  held codex bash_container_db_client db "docker exec other-db-1 $client --version"
done
held codex bash_container_db_client db "docker compose exec -T db mysql -e 'show tables'"
held codex bash_container_db_client db "docker compose -p other exec db pg_dump app"
held codex bash_container_db_client db "docker container exec other-db-1 psql -l"
held codex bash_container_db_client db "docker-compose exec db psql -l"
held codex bash_container_db_client db "podman exec other-db-1 psql -l"
held codex bash_container_db_client db "nerdctl exec other-db-1 psql -l"
held codex bash_container_db_client db "docker --context default exec other-db-1 psql -l"
held codex bash_container_db_client db "docker -H unix:///var/run/docker.sock exec other-db-1 psql -l"
held codex bash_container_db_client db "docker exec -u postgres -w /tmp other-db-1 psql -l"
held codex bash_container_db_client db "docker exec other-db-1 /usr/bin/psql -l"
held codex bash_container_db_client db "docker exec other-db-1 sh -c 'psql -c \"select 1\"'"
held codex bash_container_db_client db "docker exec -i other-db-1 sh <<'EOF'${NL}psql -c 'select 1'${NL}EOF"
held codex bash_container_db_client db "docker \\${NL}  exec other-db-1 psql -l"
held codex bash_container_db_client db "d\"o\"cker exec other-db-1 psql -l"
held codex bash_container_db_client db "docker exec other-db-1 p\"sq\"l -l"
held codex bash_container_db_client db "sh -c 'docker exec other-db-1 psql -l'"
# The list does not have to exist for this.
POLICY_HOME=$UNLISTED
held codex bash_container_db_client db "docker exec other-db-1 psql -l"
POLICY_HOME=$LISTED

# A target the command text does not name. The stub's environment holds the
# listed stack in TARGET and PROJECT and prints it for ps, so these rows reach
# it when they run.
held codex bash_container_unresolved_target stack 'docker exec $TARGET ls'
held review-env bash_container_unresolved_target stack 'docker exec $TARGET ls'
held review-agent bash_container_unresolved_target stack 'docker exec $TARGET ls'
held codex bash_container_unresolved_target stack 'docker exec "${TARGET}" ls'
held codex bash_container_unresolved_target stack "docker exec \"\$(docker ps --format '{{.Names}}' | head -1)\" ls"
held codex bash_container_unresolved_target stack 'docker exec `docker ps -q` ls'
held codex bash_container_unresolved_target stack 'docker compose -p "$PROJECT" exec db ls'
held codex bash_container_unresolved_target stack 'COMPOSE_PROJECT_NAME=$PROJECT docker compose exec db ls'
held codex bash_container_unresolved_target stack 'podman exec $TARGET ls'
# A container ID names no stack; which one it is cannot be read from the text.
held codex bash_container_unresolved_target none 'docker exec 0123456789ab ls'
held codex bash_container_unresolved_target none 'docker exec -it 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef sh'

# A list that cannot be read holds every runtime command of a restricted
# session, and no other command.
POLICY_HOME=$BROKEN
held codex bash_container_policy_unreadable none 'docker ps'
held review-env bash_container_policy_unreadable skip "docker exec $DB ls"
free codex none 'ls -la'
POLICY_HOME=$LISTED

# What a restricted session keeps.
for kind in codex review-env review-agent; do
  free "$kind" none 'docker ps'
  free "$kind" none 'docker exec other-app-1 ls /app'
done
free codex none "docker ps -a --format '{{.Names}}'"
free codex none 'docker logs --tail 20 other-app-1'
free codex none "docker exec -it other-app-1 sh -c 'ls /app'"
free codex none 'docker compose -p other exec app pytest -q'
free codex none 'docker compose exec -T app npm test'
# A client name inside a longer word is not a client.
free codex none 'docker exec other-app-1 ls /srv/app-mysql/'
free codex none 'docker exec other-app-1 pytest mysql_client_test.py'
# An expansion on another line, or a hex word that is not the container.
free codex none "T=\$HOME${NL}docker exec other-app-1 ls /app"
free codex none 'docker exec other-app-1 git show 0123456789abcdef'
free codex none 'podman exec other-app-1 ls'
free codex none "docker run --rm alpine sh -c 'echo \$HOME'"
free codex none 'docker run --rm -v "$PWD":/w alpine bundle exec rake'
free codex none 'docker compose run --rm app bundle exec rspec'
free codex none 'ls -la'
free codex none 'echo psql'
# A report that quotes a blocked command is only text.
free codex skip "git commit -m 'docker exec $DB psql was held in the review session'"
# Without a list nothing names a stack.
POLICY_HOME=$UNLISTED
free codex skip "docker exec $DB ls /"
POLICY_HOME=$LISTED

# Session kinds that are not restricted: another agent type, another role.
for kind in plain-agent plain-role; do
  free "$kind" stack "docker exec $DB ls /"
  free "$kind" db "docker exec other-db-1 psql -U app -c 'select 1'"
  free "$kind" stack 'docker exec $TARGET ls'
done
POLICY_HOME=$BROKEN
free plain skip 'docker ps'
POLICY_HOME=$LISTED

# The stub must have seen the rows: a harness that runs nothing would agree
# with every "none".
if [ "$reached" -ge 60 ]; then
  ok "the stub runtime recorded $reached rows that reach a listed stack or a database client"
else
  bad "the stub runtime recorded only $reached reaching rows"
fi

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
