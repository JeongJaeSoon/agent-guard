#!/usr/bin/env sh
set -u

# A PR body, review reply or note that names a full git object id (40 hex, or
# 64 in a SHA-256 repository) near a credential word ("the token fix, merge
# commit: <id>") reads to generic-api-key as a keyword-labelled secret, so the
# Write PreToolUse check blocked drafts in the agent's own scratchpad (#599).
# Only a line that names the id as a commit (commit, sha, rev, merge, head as
# a word of the plain clause right before it), or an issue-key branch name as a
# branch, and holds no other value-length run after a separator may pass;
# numbered dummy/example placeholders pass too. A 40-hex value under a credential name without that git
# word (the old GitHub token shape), a second assignment on the line, a value
# on the next line, other lengths or uppercase, vendor token shapes, a
# high-entropy name=value and a private key keep their findings.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-write-object-id.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' EXIT INT TERM
mkdir "$CASE/cwd" "$CASE/home" "$CASE/scan"
# A host that passes the variable empty means "no real gitleaks".
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG=${WRITE_OBJECT_ID_TEST_CONFIG:-$ROOT/plugins/agent-guard/config/gitleaks.toml}
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_INFRA_FAILURE_MODE=closed AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_OUTPUT_REDACT AI_AGENT
PATH="$(dirname "$GITLEAKS"):$PATH"
pass=0
fail=0
n=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  cut -c1-200 "$CASE/err" | sed 's/^/  stderr: /'
}

# Fixed, not random: a low-entropy id falls under generic-api-key's 3.5
# entropy floor and would turn every must-keep-finding case into a silent
# pass. Built from pieces at run time so this file holds no literal finding.
SHA1=$(printf '%s%s%s%s' 9f3a7c21d4e6 b05a8c731d2f 4e69ab07c35d 8e12)
SHA2=$(printf '%s%s%s%s%s' 4b1d09e7a35c 82f6d0143ba9 c7e5128d6f40 a93be5071c2d 68f4e3a1b957c2d1)
OTHER=$(printf '%s%s%s%s' 3c8e5a09f1d7 24b6e08c9a13 d5f7e2410b68 a9c4)
if [ "${#SHA1}" -ne 40 ] || [ "${#SHA2}" -ne 64 ] || [ "${#OTHER}" -ne 40 ]; then
  printf 'not ok - fixed hex lengths\n'
  exit 1
fi
UPPER=$(printf '%s' "$SHA1" | tr 'a-f' 'A-F')
TAIL10=$(printf '%s' "$OTHER" | cut -c1-10)
P=$(printf '%s%s' to ken)
K=$(printf '%s%s' k ey)
AU=$(printf '%s%s' au th)
AP=$(printf '%s%s' ap i)
MIXED=$(printf '%s%s%s' Zt8q3LmX7vR2 nK9pW4cH6dJ1 sF5gB0yA)
# Twelve distinct characters: entropy log2(12), just over the 3.5 floor.
TWELVE=$(printf '%s%s' Ab3Cd4 Ef5Gh6)
BRANCH=$(printf '%s-%s-%s' 94S 2515 mcp-oidc-kind-lenient)
GH_SHAPE=$(printf '%s%s%s' gh p_R8mZq2Lx7Vt4Nc9P w1Ks6Hd3Fj5Gb0Ya8Ue2)
# The vendor rule takes exactly 36 characters after the prefix.
if [ "${#GH_SHAPE}" -ne 40 ]; then
  printf 'not ok - GitHub token shape length\n'
  exit 1
fi
AWS_SHAPE=$(printf '%s%s' AK IAQ7ZK3M9X2LTW5RBN)
ANT_SHAPE=$(printf '%s%s%s' sk-an t-api03-Hq7Lm2Zx9Rt4Vc8N k3Pw6Sd1Fj5Gb0Ya2Ue7Ko4)
SLACK_SHAPE=$(printf '%s%s%s' xo xb-2648391057-8392016473215- Zq4Lm8Rt2Vx6Nc0Pk3Hw9Sd)
GL_SHAPE=$(printf '%s%s' glp at-x7Kq2Lm9Rt4Vz8Nc3Pw1)
PK_HEAD=$(printf '%s%s' '-----BEGIN RSA PRI' 'VATE KEY-----')
PK_FOOT=$(printf '%s%s' '-----END RSA PRI' 'VATE KEY-----')
PK_BODY=$(printf '%s%s\n%s%s\n%s%s' \
  MIIEowIBAAKCAQEAu7Hq2Lm9Zx4Rt8Vc3Nk6Pw1Sd5Fj0Gb7Ya2 Ue4Ko9Ti3Mh8Wq6Ez1Xr5Cv0Bn \
  Jp7Dl2Gs9Ha4Kf6Lq1Mw8Ne3Ox5Py0Qz7Rv2Sw9Tx4Uy6Vz1Wa 8Xb3Yc5Zd0Ae7Bf2Cg9Dh4Ei \
  6Fj1Gk8Hl3Im5Jn0Ko7Lp2Mq9Nr4Os6Pt1Qu8Rv3Sw5Tx0Uy7Vz 2Wa9Xb4Yc6Zd1Ae8Bf3CgQ)

# $1 expected status, $2 label, $3 Write content. The file sits in a scratch
# directory, as the PR body draft of #599 did.
write_case() {
  n=$((n + 1))
  jq -nc --arg p "$CASE/cwd/pr-body-$n.md" --arg c "$3" --arg d "$CASE/cwd" \
    --arg s "write-object-id-$n" \
    '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p,content:$c},cwd:$d}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool) >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -ne "$1" ]; then
    not_ok "Write: $2 (expected $1, got $status)"
  elif [ "$1" -eq 2 ] && ! grep -q 'secret-like value detected in proposed Write content' "$CASE/err"; then
    not_ok "Write: $2 (blocked without the Write content scan message)"
  else
    ok "Write: $2"
  fi
}

# Shape boundaries through scan-path with the real scanner.
scan_case() {
  rm -f "$CASE/scan/"*
  printf '%s\n' "$3" >"$CASE/scan/fixture.md"
  "$GUARD" scan-path "$CASE/scan" >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$1" ]; then
    ok "scan-path: $2"
  else
    not_ok "scan-path: $2 (expected $1, got $status)"
  fi
}

# Prints the rules that fire on $2 without judging it (--measure only).
measure() {
  printf '%s\n' "$2" >"$CASE/in"
  rm -f "$CASE/report.json"
  "$GITLEAKS" stdin --no-banner --no-color --log-level error \
    --config "$AGENT_GUARD_GITLEAKS_CONFIG" --exit-code 1 \
    --report-format json --report-path "$CASE/report.json" <"$CASE/in" >/dev/null 2>&1
  printf 'measure - %s: status %s rules %s\n' "$1" "$?" \
    "$(jq -r '[.[] | .RuleID + "/" + (.Secret | length | tostring)] | join(",")' "$CASE/report.json" 2>/dev/null)"
}

EN_BODY="## Summary
Fix the $P refresh race in the MCP client.

- $P refresh fix commit: $SHA1
- Rotated the $AP $K handling, merge commit: $SHA1.
- $AU fix head: \`$SHA2\`"
KO_BODY="## 요약
MCP 클라이언트의 $P 갱신 경합을 고친다.

- $P fix commit: $SHA1 (재현 절차는 아래)
- $AU 처리 수정 sha: $SHA1"
JA_BODY="## 概要
MCP クライアントの $P 更新の競合を直す。

- $AP $K rotation commit: $SHA1 を参照
- $AU fix merge: $SHA2"
TABLE_BODY="| 변경 | 커밋 |
| --- | --- |
| $P fix commit: | $SHA1 |
| $AU rev: | \`$SHA1\` |"

# An argument, not a variable: an inherited variable would turn the suite into
# a run that checks nothing and still passes.
if [ "${1-}" = --measure ]; then
  measure 'en: commit before the keyword' "- Head commit for the $P fix: $SHA1"
  measure 'en: commit after the keyword' "Fix $AU commit: $SHA1"
  measure 'ko: Korean between keyword and colon' "- $P 수정 커밋: $SHA1"
  measure 'table: single pipes only' "| $P fix | $SHA1 |"
  measure 'short sha' "- $P fix: $(printf '%s' "$SHA1" | cut -c1-12)"
  measure 'branch as value (auth word)' "Branch for the $P change: 94S-2515-mcp-$AU-kind-lenient"
  measure 'branch as value (no stopword)' "Branch for the $P change: 94S-2515-mcp-oidc-kind-lenient"
  measure 'branch with owner as value' "$P branch: JeongJaeSoon/94S-2515-mcp-oidc-kind-lenient"
  measure 'branch keyword then sha' "94S-2515-mcp-$AU-kind-lenient, $SHA1"
  measure 'dummy word value' "$AP-$K=dummy-$K-12345"
  measure 'test word value' "$P: test-$P-12345"
  measure 'fake word value' "$P=fake-$P-1234567"
  measure 'example word value' "$P=example-$P-123"
  measure 'placeholder word value' "$P=placeholder-1234"
  measure 'your here value' "$P=your-$P-here"
  measure 'x run' "$P=xxxxxxxxxxxxxxxx"
  measure 'angle placeholder' "$P=<$P>"
  measure 'variable placeholder' "$P=\${TOKEN}"
  exit 0
fi

# The drafts of #599: a full object id named as a commit near a credential word.
write_case 0 'en PR body naming commit, merge commit and head ids' "$EN_BODY"
write_case 0 'ko PR body naming commit and sha ids' "$KO_BODY"
write_case 0 'ja PR body naming commit and merge ids' "$JA_BODY"
write_case 0 'markdown table of commits' "$TABLE_BODY"
write_case 0 'Korean words between the keyword and the colon' "- $P 수정 커밋: $SHA1"
write_case 0 'issue-key branch name after a credential word' "$EN_BODY

$P change branch: $BRANCH"
write_case 2 'branch word earlier in the clause than the last word' "Branch for the $P change: $BRANCH"
write_case 0 'numbered dummy credential in a test description' "The test sends $AP-$K=dummy-$K-12345 and expects a block."
write_case 0 'numbered example credential' "$P=example_$P-123456"

# Real-looking secrets keep blocking, alone and inside the same drafts.
write_case 2 '40 hex under a credential name without a git word' "$P: $SHA1"
write_case 2 '40 hex after a credential sentence without a git word' "- Rotated the $AP $K: $SHA1"
write_case 2 'draft with a second keyword assignment on the commit line' "- $P fix commit: $SHA1, api_$P=$OTHER"
write_case 2 'draft with a high-entropy name=value line' "$EN_BODY
api_$P=$MIXED"
write_case 2 'draft with a GitHub token shape on the commit line' "- $AU fix commit: $SHA1 uses $GH_SHAPE"
write_case 2 'draft with an AWS key id shape' "$KO_BODY
$AWS_SHAPE"
write_case 2 'draft with an Anthropic key shape' "$JA_BODY
$ANT_SHAPE"
write_case 2 'draft with a Slack bot token shape' "$TABLE_BODY
$SLACK_SHAPE"
write_case 2 'draft with a GitLab token shape' "$EN_BODY
$GL_SHAPE"
write_case 2 'draft with a private key' "$EN_BODY

$PK_HEAD
$PK_BODY
$PK_FOOT"

scan_case 1 'git word earlier in the clause than the last word' "- Head commit for the $P fix: $SHA1"
scan_case 1 'credential label that starts with a git word' "commit signing $K: $SHA1"
scan_case 1 'credential label between a git word and the colon' "merge bot $P: $SHA1"
scan_case 0 'commit word after the keyword' "Fix $AU commit: $SHA1"
scan_case 0 'sha word' "$P fix sha: $SHA1"
scan_case 0 'rev word' "$AU rev: $SHA1"
scan_case 0 'merge word after a short comma clause' "Rotated the $AP $K, merge commit: $SHA1"
scan_case 0 'HEAD word with a 64-hex id' "$P HEAD: $SHA2"
scan_case 0 'id in backticks' "$P fix commit: \`$SHA1\`"
scan_case 0 'id ending the sentence' "$P fix commit: $SHA1."
scan_case 0 'id followed by prose with short words' "$P fix commit: $SHA1 (see: ok, done)"
scan_case 0 'bold git word' "**$P fix commit**: $SHA1"
scan_case 1 'hyphen-joined field name ending in commit' "$AU-fix-commit: $SHA1"
scan_case 1 'credential field name ending in commit, assigned' "deploy-$K-commit=$SHA1"
scan_case 1 'git word then an equals sign' "$P fix commit = $SHA1"
scan_case 1 'git word then a comma' "$P fix commit, $SHA1"
scan_case 1 '40 hex under a credential name' "$P: $SHA1"
scan_case 1 '40 hex under an underscore name ending in commit' "${P}_commit: $SHA1"
scan_case 1 'git word glued to a longer word' "$P headroom: $SHA1"
scan_case 1 'git word only after the id' "$P: $SHA1 commit"
scan_case 1 'git word in an earlier clause' "commit done, $P: $SHA1"
scan_case 1 'id on the next line' "$P fix commit:
$SHA1"
scan_case 1 'uppercase hex' "$P fix commit: $UPPER"
scan_case 1 'one more hex digit' "$P fix commit: ${SHA1}a"
scan_case 1 'token characters after the id' "$P fix commit: ${SHA1}_x"
scan_case 1 '41 to 63 hex' "$P fix commit: $SHA1$TAIL10"
scan_case 1 'id in double quotes' "$P fix commit: \"$SHA1\""
scan_case 1 'second assignment after the id' "$P fix commit: $SHA1; api_$P=$OTHER"
scan_case 1 'second 40 hex after a later separator' "$P fix commit: $SHA1, $AP $K: $OTHER"
scan_case 1 'assignment before the commit clause' "api_$P=$OTHER, $P fix commit: $SHA1"
scan_case 1 'twelve-character value after the id' "$P fix commit: $SHA1, api_$P=$TWELVE"
scan_case 1 'twelve-character value before the commit clause' "api_$P=$TWELVE, $P fix commit: $SHA1"
scan_case 1 'twelve-character value after a later colon' "$P fix commit: $SHA1 then $P: $TWELVE"
scan_case 1 'id line followed by a keyword assignment line' "$P fix commit: $SHA1
api_$P=$OTHER"
scan_case 1 'high-entropy name=value' "api_$P=$MIXED"
# Shell text is not prose: the commit verb, an option or a quote keeps it found.
scan_case 1 'quoted commit message with a value' "git commit -m \"$P: $OTHER\""
scan_case 1 'unquoted commit message with a value' "git commit -m $P: $OTHER"
scan_case 1 'echoed sentence with the id' "echo \"Head commit for the $P fix: $SHA1\""
scan_case 1 'long first word after a separator' "$P, $TWELVE commit: $SHA1"
scan_case 1 'long hyphenated first word after a separator' "$P, $TWELVE-head fix: $SHA1"

# Branch names: only an issue key, a number and lowercase words.
scan_case 0 'branch name as a value' "$P branch: $BRANCH"
scan_case 0 'digit-led lowercase issue key' "$P branch: $(printf '%s' "$BRANCH" | tr 'A-Z' 'a-z')"
scan_case 1 'mixed-case key with words (a password shape)' "pass$(printf w)ord: Summer-2024-winter-sale"
scan_case 1 'branch-shaped password' "pass$(printf w)ord: $BRANCH"
scan_case 1 'branch shape under a credential name without the branch word' "$P: $BRANCH"
scan_case 1 'branch word then an equals sign' "$P branch=$BRANCH"
scan_case 1 'branch word glued to a field name' "$P-branch: $BRANCH"
scan_case 1 'branch shape with a digit in a word' "$P branch: 94S-2515-mcp-k3x9q2-lenient"
scan_case 1 'branch shape with an uppercase word' "$P branch: 94S-2515-mcp-Oidc-lenient"
scan_case 1 'branch shape with one word' "$P branch: 94S-2515-mcpoidckind"
scan_case 1 'branch shape with a token tail' "$P branch: 94S-2515-mcp-oidc_$TWELVE"
# Numbered placeholders: only the dummy/example credential words and digits.
scan_case 0 'dummy key with a number' "$AP-$K=dummy-$K-12345"
scan_case 1 'dummy key with a random tail' "$AP-$K=dummy-$K-$TWELVE"
scan_case 1 'dummy key with a number and an adjacent tail' "$AP-$K=dummy-$K-123$TWELVE"
scan_case 1 'dummy key with a number and a random tail' "$AP-$K=dummy-$K-123-$TWELVE"

printf '%s write object id checks, %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
