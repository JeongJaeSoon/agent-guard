#!/usr/bin/env sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BIN:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
MOCK_GITLEAKS="$ROOT/tests/fixtures/mock-gitleaks"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-mask-rules.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'chmod -R u+rwx "$CASE" 2>/dev/null; rm -rf "$CASE"' 0
export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_GITLEAKS_BIN="$MOCK_GITLEAKS"
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export HOME="$CASE/home"
unset AI_AGENT AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_MASK_DENY_VALUES
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
hex() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
show() {
  sed 's/^/  stdout: /' "$CASE/out"
  sed 's/^/  stderr: /' "$CASE/err"
}

# Fake organization token formats: no scanner rule knows them, so only the
# deny-value rules can mask them.
ORG1=ORGTOK-$(hex); ORG2=ORGTOK-$(hex); ORG3=ORGTOK-$(hex)
ZETA1=ZETA-$(hex)
V1=$(hex); V2=$(hex)
HIDDEN="$ORG1 $ORG2 $ORG3 $V1 $V2"
USER_RULE='ORGTOK-[0-9a-f]{24}'
ENV_RULE='ZETA-[0-9a-f]{24}'

USER_DIR="$HOME/.config/agent-guard"
USER_FILE="$USER_DIR/mask-deny-values.txt"
mkdir -p "$USER_DIR" "$CASE/work"
W="$CASE/work"
DOT=".en""v"
printf '# rotated %s last week\n  # old %s and %s%s retired\nDB_PASSWORD=%s\nAPI=%s\n' \
  "$ORG1" "$ZETA1" "$ORG2" "$ORG3" "$V1" "$V2" >"$W/$DOT"
user_rules() { { printf '# organization tokens\n\n'; printf '%s\n' "$@"; } >"$USER_FILE"; }
env_rules() { printf '%s\n' "$@" >"$CASE/env-rules"; }
user_rules "$USER_RULE"
env_rules "# repository rules" "$ENV_RULE"

HEAD="agent-guard: blocked sensitive file access:"
HEADER="agent-guard: masked view follows (values replaced with [MASKED]; the file itself was not read by the tool)"

hook() {
  hook_host=$1 hook_json=$2
  shift 2
  printf '%s' "$hook_json" | env AGENT_GUARD_HOOK_HOST="$hook_host" \
    AGENT_GUARD_DENY_READ_MODE="${MODE-mask}" "$@" "$GUARD" hook-pre-tool \
    >"$CASE/out" 2>"$CASE/err"
  status=$?
}
read_json() { jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p},session_id:"mask-rules"}'; }
bash_json() { jq -nc --arg c "cat $1" --arg d "$W" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d},session_id:"mask-rules"}'; }

# None of $HIDDEN, and no rule text, may reach stdout or stderr.
clean() {
  for v in $HIDDEN; do
    grep -Fq -- "$v" "$CASE/out" "$CASE/err" && return 1
  done
  for r in "$@"; do
    grep -Fq -- "$r" "$CASE/out" "$CASE/err" && return 1
  done
  return 0
}

# expect NAME EXPECTED_STDERR FILE [VAR=VALUE...]: Read and cat of FILE on
# both hosts block with exactly EXPECTED_STDERR and nothing hidden.
expect() {
  ex_name=$1 ex_err=$2 ex_file=$3
  shift 3
  for host in claude codex; do
    for form in read cat; do
      case $form in
        read) hook "$host" "$(read_json "$ex_file")" "$@" ;;
        cat) hook "$host" "$(bash_json "$ex_file")" "$@" ;;
      esac
      if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] \
         && printf '%s\n' "$ex_err" | cmp -s - "$CASE/err" && clean $RULES; then
        ok "$host $form: $ex_name"
      else
        bad "$host $form: $ex_name (status $status)"
        show
      fi
    done
  done
}
RULES="$USER_RULE $ENV_RULE"
view() { printf '%s %s\n%s\n%s' "$HEAD" "$1" "$HEADER" "$2"; }
refused() { printf '%s %s\nagent-guard: no masked view: %s\n' "$HEAD" "$1" "$2"; }

# MUST-PASS: both rule files apply, comments included.
expect "the user file and the env file are both applied" "$(view "$W/$DOT" "# rotated [MASKED] last week
  # old [MASKED] and [MASKED] retired
DB_PASSWORD=[MASKED]
API=[MASKED]
")" "$W/$DOT" AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-rules"

: >"$CASE/empty-rules"
expect "an empty env file does not replace the user file" "$(view "$W/$DOT" "# rotated [MASKED] last week
  # old $ZETA1 and [MASKED] retired
DB_PASSWORD=[MASKED]
API=[MASKED]
")" "$W/$DOT" AGENT_GUARD_MASK_DENY_VALUES="$CASE/empty-rules"

printf '%s\r\n' "$USER_RULE" >"$USER_FILE"
expect "a rule file with CRLF line ends still applies" "$(view "$W/$DOT" "# rotated [MASKED] last week
  # old $ZETA1 and [MASKED] retired
DB_PASSWORD=[MASKED]
API=[MASKED]
")" "$W/$DOT"

rm -f "$USER_FILE"
HIDDEN_ALL=$HIDDEN
HIDDEN="$V1 $V2"
expect "with no user file the env file alone applies" "$(view "$W/$DOT" "# rotated $ORG1 last week
  # old [MASKED] and $ORG2$ORG3 retired
DB_PASSWORD=[MASKED]
API=[MASKED]
")" "$W/$DOT" AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-rules"

expect "with no rules at all the view is unchanged" "$(view "$W/$DOT" "# rotated $ORG1 last week
  # old $ZETA1 and $ORG2$ORG3 retired
DB_PASSWORD=[MASKED]
API=[MASKED]
")" "$W/$DOT"
HIDDEN=$HIDDEN_ALL
user_rules "$USER_RULE"

mkdir "$CASE/fmt"
printf '# token %s\ndb:\n  # inner %s\n  password: %s\n' "$ORG1" "$ORG2" "$V1" >"$CASE/fmt/secrets.yaml"
expect "yaml comments are masked" "$(view "$CASE/fmt/secrets.yaml" "# token [MASKED]
db:
  # inner [MASKED]
  password: [MASKED]
")" "$CASE/fmt/secrets.yaml"
printf '; token %s\n# also %s\nregistry=%s\n' "$ORG1" "$ORG2" "$V1" >"$CASE/fmt/.npmrc"
expect "ini ; and # comments are masked" "$(view "$CASE/fmt/.npmrc" "; token [MASKED]
# also [MASKED]
registry=[MASKED]
")" "$CASE/fmt/.npmrc"
printf '{"user": "%s"}\n' "$ORG1" >"$CASE/fmt/secrets.json"
expect "a json value matching a rule is masked as a value" "$(view "$CASE/fmt/secrets.json" '{
  "user": "[MASKED]"
}
')" "$CASE/fmt/secrets.json"

# MUST-FAIL: a rule that would rewrite a key blocks without a view.
KEY_RULE='DB_PASS[A-Z]+'
RULES="$KEY_RULE"
user_rules "$USER_RULE" "$KEY_RULE"
expect "a rule matching a dotenv key blocks" "$(refused "$W/$DOT" \
  "mask-deny-values.txt line 4: the rule matches a key or other text outside values and comments")" "$W/$DOT"
user_rules "$USER_RULE"
printf '{"%s": "x"}\n' "$ORG1" >"$CASE/fmt/secrets.json"
RULES=
expect "a rule matching a json key blocks" "$(refused "$CASE/fmt/secrets.json" \
  "mask-deny-values.txt line 3: the rule matches a key or other text outside values and comments")" "$CASE/fmt/secrets.json"
user_rules 'SECRET.*TOKEN'
RULES='SECRET.*TOKEN'
printf '{"SECRET[MASKED]TOKEN": "x"}\n' >"$CASE/fmt/secrets.json"
expect "a key holding literal [MASKED] text is still checked whole" "$(refused "$CASE/fmt/secrets.json" \
  "mask-deny-values.txt line 3: the rule matches a key or other text outside values and comments")" "$CASE/fmt/secrets.json"
printf 'SECRET_[MASKED]_TOKEN: x\n' >"$CASE/fmt/secrets.yaml"
expect "a yaml key holding literal [MASKED] text is still checked whole" "$(refused "$CASE/fmt/secrets.yaml" \
  "mask-deny-values.txt line 3: the rule matches a key or other text outside values and comments")" "$CASE/fmt/secrets.yaml"
user_rules "$USER_RULE"
RULES=
printf '%s:\n  password: x\n' "$ORG1" >"$CASE/fmt/secrets.yaml"
expect "a rule matching a yaml key blocks" "$(refused "$CASE/fmt/secrets.yaml" \
  "mask-deny-values.txt line 3: the rule matches a key or other text outside values and comments")" "$CASE/fmt/secrets.yaml"
printf '[%s]\nkey=x\n' "$ORG1" >"$CASE/fmt/.pypirc"
expect "a rule matching an ini section blocks" "$(refused "$CASE/fmt/.pypirc" \
  "mask-deny-values.txt line 3: the rule matches a key or other text outside values and comments")" "$CASE/fmt/.pypirc"

# MUST-FAIL: every refused rule shape, from either file, blocks and names
# only the file label, line and reason.
LONG=ORGTOK-$(awk 'BEGIN { while (n++ < 250) printf "q" }')
SLOW=$(awk 'BEGIN { while (n++ < 25) printf ".{0,255}"; print "Q" }')
printf '# %s\nK=v\n' "$(awk 'BEGIN { while (n++ < 3000) printf "a" }')" >"$CASE/slow.env"
while IFS='~' read -r rule why; do
  RULES=$rule
  for where in user env; do
    case $where in
      user) user_rules "$USER_RULE" "$rule"; set -- ; label="mask-deny-values.txt line 4" ;;
      env) user_rules "$USER_RULE"; env_rules "# repository rules" "$rule"
        set -- AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-rules"; label="AGENT_GUARD_MASK_DENY_VALUES line 2" ;;
    esac
    start=$(date +%s)
    expect "$where rule refused: $why" "$(refused "$W/$DOT" "$label: the rule $why")" "$W/$DOT" "$@"
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -lt 10 ]; then ok "$where $why: 4 hooks in ${elapsed}s"; else bad "$where $why: 4 hooks took ${elapsed}s"; fi
  done
done <<EOF
ORGTOK(~is not a valid extended regular expression
(ORGTOK)\\1~uses a back-reference
(ORGTOK+)+~repeats an expression that already repeats
(.*)*ORGTOK~repeats an expression that already repeats
ORGTOK-**~repeats an expression that already repeats
(ORG|ORGTOK)*X~repeats a group that contains |
ORGTOK{300}~repeats more than 255 times
(ORGTOK)?~matches empty text
${LONG}x~is longer than 256 bytes
EOF

env_rules "$SLOW"
for host in claude codex; do
  start=$(date +%s)
  hook "$host" "$(read_json "$CASE/slow.env")" AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-rules"
  elapsed=$(( $(date +%s) - start ))
  last=$(tail -n 1 "$CASE/err")
  case $last in
    "agent-guard: no masked view: AGENT_GUARD_MASK_DENY_VALUES line 1: the rule took too long to "*) timed=1 ;;
    *) timed=0 ;;
  esac
  if [ "$status" -eq 2 ] && [ "$timed" -eq 1 ] && [ "$elapsed" -lt 10 ] \
     && ! grep -Fq "$HEADER" "$CASE/err" && clean "$SLOW"; then
    ok "$host: a rule that runs away is stopped by the timer in ${elapsed}s"
  else
    bad "$host: a rule that runs away is stopped by the timer (status $status, ${elapsed}s)"
    show
  fi
done

RULES=
awk 'BEGIN { print "# 40 rules"; for (i = 0; i < 40; i++) print "ORGTOK-" i "[0-9]" }' >"$USER_FILE"
awk 'BEGIN { for (i = 0; i < 25; i++) print "ZETA-" i "[0-9]" }' >"$CASE/env-rules"
expect "the 64-rule limit counts both files together" "$(refused "$W/$DOT" \
  "AGENT_GUARD_MASK_DENY_VALUES line 25: the rule is past the limit of 64 rules")" "$W/$DOT" \
  AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-rules"
awk 'BEGIN { for (i = 0; i < 64; i++) print "ORGTOK-" i "[0-9]" }' >"$USER_FILE"
hook claude "$(read_json "$W/$DOT")"
if [ "$status" -eq 2 ] && grep -Fqx "$HEADER" "$CASE/err"; then
  ok "64 rules are accepted"
else
  bad "64 rules are accepted (status $status)"
  show
fi
user_rules "$USER_RULE"

# MUST-FAIL: a rule file that exists but cannot be read blocks; only a
# missing user file means no rules.
expect "an env path that does not exist blocks" "$(refused "$W/$DOT" \
  "the file AGENT_GUARD_MASK_DENY_VALUES names could not be read")" "$W/$DOT" \
  AGENT_GUARD_MASK_DENY_VALUES="$CASE/missing-rules"
mkdir "$CASE/rules-dir"
expect "an env path that is a directory blocks" "$(refused "$W/$DOT" \
  "the file AGENT_GUARD_MASK_DENY_VALUES names could not be read")" "$W/$DOT" \
  AGENT_GUARD_MASK_DENY_VALUES="$CASE/rules-dir"
chmod 000 "$USER_FILE"
if [ -r "$USER_FILE" ]; then
  ok "# skip unreadable user file: running as a user who can read mode 000"
else
  expect "an unreadable user file blocks" "$(refused "$W/$DOT" \
    "mask-deny-values.txt could not be read")" "$W/$DOT"
fi
chmod 644 "$USER_FILE"
rm -f "$USER_FILE"
ln -s "$CASE/missing-rules" "$USER_FILE"
expect "a dangling user file symlink blocks" "$(refused "$W/$DOT" \
  "mask-deny-values.txt could not be read")" "$W/$DOT"
rm -f "$USER_FILE"

# Block mode never reads the rules, so even a broken rule changes nothing.
user_rules 'ORGTOK('
for mode in "" block; do
  MODE=$mode
  hook claude "$(read_json "$W/$DOT")" AGENT_GUARD_MASK_DENY_VALUES="$CASE/missing-rules"
  if [ "$status" -eq 2 ] && [ "$(cat "$CASE/err")" = "$HEAD $W/$DOT" ]; then
    ok "mode '${mode:-unset}' blocks as before whatever the rules"
  else
    bad "mode '${mode:-unset}' blocks as before whatever the rules (status $status)"
    show
  fi
done
unset MODE

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
