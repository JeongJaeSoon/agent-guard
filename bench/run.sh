#!/usr/bin/env sh
# agent-guard leak-prevention benchmark.
#
# Measures, per CHANNEL, whether a secret is prevented from reaching the model's
# context — classifying each case into blocked | masked | leaked (and
# false-positive for benign controls). Unlike tests/run.sh, this drives the
# engine against the REAL gitleaks binary + real config/gitleaks.toml, so it
# reflects true pattern coverage, not the test mock.
#
# It is a measurement, not a gate: it always exits 0 and prints a matrix + the
# headline metrics (per-channel leak-prevention rate, channel coverage,
# false-positive rate). The `!` bang channel is recorded as structurally
# UNCOVERED — Claude Code fires no hook for shell-escapes, so no hook-based
# guardrail (agent-guard included) can intercept it; see docs/benchmark.md.
#
# The interceptor under test is $AGENT_GUARD_BIN, so a peer tool could later be
# dropped in behind the same channel drivers.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_BIN:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CFG=${AGENT_GUARD_GITLEAKS_CONFIG:-"$ROOT/plugins/agent-guard/config/gitleaks.toml"}
export AGENT_GUARD_GITLEAKS_CONFIG="$CFG"
RESULTS=${BENCH_RESULTS:-"$ROOT/bench/results.tsv"}

# --- preflight: the benchmark is meaningless without the real detector --------
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "bench: real gitleaks binary not found on PATH — install gitleaks to measure real coverage" >&2
  exit 3
fi
command -v jq >/dev/null 2>&1 || { echo "bench: jq is required" >&2; exit 3; }
[ -x "$BIN" ] || { echo "bench: engine not found/executable at $BIN" >&2; exit 3; }
# The most common scanner-health failure Codex flagged: a missing/invalid config
# makes every gitleaks-dependent case exit 2. Fail fast here with a clear message
# rather than letting it surface as an ambiguous exit 2 during scoring.
[ -f "$CFG" ] || { echo "bench: gitleaks config not found at $CFG" >&2; exit 3; }

# A non-git scratch dir so hook-post-tool's mutation backstop (working-tree
# scan) stays inert and we isolate the output-redaction path.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-bench.XXXXXX") || exit 3
trap 'rm -rf "$WORK"' EXIT INT TERM

: >"$RESULTS"
printf 'channel\tvariant\tkind\toutcome\tverdict\n' >>"$RESULTS"

# --- canary generation (assembled at runtime; no literal secrets on disk) -----
lc() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }

canary() { # $1 = shape -> echoes a fresh, real-shaped, gitleaks-catchable secret
  # Shapes are matched by prefix-anchored rules (or, for jwt on the output path,
  # the engine's structural JWT regex) with no entropy gate, so detection is
  # deterministic across random draws — verified 20/20 per shape.
  case "$1" in
    anthropic) printf 'sk-%s-api03-%sAA' 'ant' "$(lc 93)" ;;
    github)    printf 'ghp_%s' "$(lc 36)" ;;
    jwt)       printf 'eyJ%s.eyJ%s.%s' 'hbGciOiJIUzI1NiJ9' 'zdWIiOiJib3QifQ' "$(lc 43)" ;;
    envpass)   printf 'DATABASE_PASSWORD=%s' "$(lc 24)" ;;
    apikey)    printf 'API_KEY=%s' "$(lc 32)" ;;
  esac
}

# --- payload builders (jq handles all escaping) -------------------------------
pre_read()  { jq -cn --arg p "$1"                 '{tool_name:"Read",tool_input:{file_path:$p}}'; }
pre_bash()  { jq -cn --arg c "$1"                 '{tool_name:"Bash",tool_input:{command:$c}}'; }
post_bash() { jq -cn --arg s "$1"                 '{tool_name:"Bash",tool_response:{stdout:$s,stderr:"",interrupted:false,isImage:false}}'; }
post_read() { jq -cn --arg s "$1"                 '{tool_name:"Read",tool_response:$s}'; }
post_mcp()  { jq -cn --arg s "$1"                 '{tool_name:"mcp__srv__tool",tool_response:{content:$s}}'; }

# --- interceptor drivers ------------------------------------------------------
# pre-tool: exit 2 is OVERLOADED — the engine uses it both for a real policy
# block (secret detected / deny-listed path) AND for fail-closed infra errors
# (missing/invalid gitleaks config, `gitleaks stdin` fatal status). Keying on
# the exit code alone would score an infra failure as `blocked`/`protected` and
# overstate the headline rate. So on exit 2 we inspect stderr for the engine's
# infra-failure markers and score those `error` (indeterminate), never blocked —
# symmetric with drive_post/drive_exec. Anything else on exit 2 is a real block.
drive_pre() { # json
  err=$(printf '%s' "$1" | "$BIN" hook-pre-tool 2>&1 >/dev/null)
  st=$?
  [ "$st" -eq 2 ] || { echo leaked; return; }
  case "$err" in
    *"gitleaks failed while scanning"*|*"gitleaks config not found"*) echo error ;;
    *) echo blocked ;;
  esac
}

# post-tool: masked if the emitted updatedToolOutput drops the secret and shows
# [REDACTED]; leaked if unchanged (redactor emits nothing → secret passes through)
# or the secret survives; error if the engine itself failed (so an infra failure
# is never mislabelled as a security leak). Runs from the non-git $WORK so the
# mutation backstop stays inert and only the redaction path is measured.
drive_post() { # json, secret
  out=$(printf '%s' "$1" | ( cd "$WORK" && "$BIN" hook-post-tool ) 2>/dev/null)
  [ "$?" -eq 0 ] || { echo error; return; }
  [ -n "$out" ] || { echo leaked; return; }
  txt=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput
        | if type=="string" then . else [..|strings]|join("\n") end' 2>/dev/null)
  if printf '%s' "$txt" | grep -qF "$2"; then echo leaked
  elif printf '%s' "$txt" | grep -q 'REDACTED'; then echo masked
  else echo leaked; fi
}

# exec wrapper (the opt-in `!` mitigation): masked if the wrapped command's
# output has the secret replaced by [REDACTED]; error if exec/the wrapped command
# failed. printf is run as the wrapped command so the secret only ever lives in
# argv, never in a script literal.
drive_exec() { # secret
  out=$("$BIN" exec -- printf 'API_KEY=%s\n' "$1" 2>/dev/null)
  [ "$?" -eq 0 ] || { echo error; return; }
  if printf '%s' "$out" | grep -qF "$1"; then echo leaked
  elif printf '%s' "$out" | grep -q 'REDACTED'; then echo masked
  else echo leaked; fi
}

# --- verdict mapping ----------------------------------------------------------
verdict() { # channel, kind, outcome
  ch=$1; kind=$2; oc=$3
  if [ "$oc" = error ]; then echo 'ERROR'; return; fi
  if [ "$ch" = bang ]; then echo 'UNCOVERED'; return; fi
  if [ "$kind" = benign ]; then
    case "$oc" in passthrough) echo 'ok' ;; *) echo 'FALSE-POS' ;; esac
    return
  fi
  case "$oc" in blocked|masked) echo 'protected' ;; *) echo 'LEAK' ;; esac
}

record() { # channel, variant, kind, outcome
  v=$(verdict "$1" "$3" "$4")
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$v" >>"$RESULTS"
}

# --- scanner health probe (before scoring any gitleaks-dependent case) --------
# pre-tool exit 2 is trustworthy as "blocked" only if the detector is actually
# healthy. A malformed gitleaks config is the sharp edge: in practice gitleaks
# exits 1 (not 2) on a fatal config-load error, which the engine reports as
# "secret detected" — so a broken config makes EVERYTHING look blocked and would
# silently inflate the headline rate. The config is fixed for the whole run, so
# one probe covers every case: assert a known secret blocks AND a known-benign
# command passes. If either fails the detector is unhealthy — abort with a clear
# message rather than emit a misleading matrix. (This is the robust complement to
# drive_pre's stderr-based `error` classification, which only catches genuine
# exit-2 gitleaks failures.)
scanner_health_probe() {
  probe_secret=$(canary anthropic)
  if [ "$(drive_pre "$(pre_bash "git config user.email \"$probe_secret\"")")" != blocked ]; then
    echo "bench: scanner health check failed — a known secret was not blocked; gitleaks/config is unhealthy" >&2
    exit 3
  fi
  if [ "$(drive_pre "$(pre_bash 'echo build finished in 4.2s')")" != leaked ]; then
    echo "bench: scanner health check failed — a benign command was blocked; gitleaks config is over-triggering (likely invalid)" >&2
    exit 3
  fi
}

# --- cases --------------------------------------------------------------------
run_cases() {
  # read-tool (sensitive file read, blocked on path) --------------------------
  record read-tool plaintext  secret "$(drive_pre "$(pre_read '.env')")"
  record read-tool alt-path   secret "$(drive_pre "$(pre_read "$HOME/.aws/credentials")")"
  record read-tool benign     benign "$(o=$(drive_pre "$(pre_read '.env.example')"); [ "$o" = leaked ] && echo passthrough || echo "$o")"

  # bash-read (sensitive file via a shell command, blocked on path) -----------
  record bash-read plaintext    secret "$(drive_pre "$(pre_bash 'cat .env')")"
  record bash-read alt-command  secret "$(drive_pre "$(pre_bash 'head -c 200 .env')")"
  record bash-read redirect     secret "$(drive_pre "$(pre_bash 'cat < .env')")"

  # bash-command-secret (a literal secret inside the command) -----------------
  s=$(canary anthropic)
  record bash-cmd plaintext secret "$(drive_pre "$(pre_bash "git config user.email \"$s\"")")"

  # bash-output (secret in Bash stdout, masked on output) ---------------------
  s=$(canary github);  record bash-output plaintext secret "$(drive_post "$(post_bash "$s")" "$s")"
  record bash-output benign benign "$(o=$(drive_post "$(post_bash 'build finished in 4.2s, 0 errors')" 'NOPE'); [ "$o" = leaked ] && echo passthrough || echo "$o")"

  # read-output (secret in a non-denylisted file's contents) ------------------
  s=$(canary jwt);     record read-output plaintext secret "$(drive_post "$(post_read "config: $s")" "$s")"
  record read-output benign-config benign "$(o=$(drive_post "$(post_read 'service_url = https://api.example.com/v2')" 'NOPE'); [ "$o" = leaked ] && echo passthrough || echo "$o")"
  # placeholder-in-env-assignment: gitleaks.toml allowlists `example_token`, but the
  # output env-value heuristic doesn't consult that allowlist — records the over-mask.
  record read-output benign-placeholder benign "$(o=$(drive_post "$(post_read 'API_KEY=example_token')" 'NOPE'); [ "$o" = leaked ] && echo passthrough || echo "$o")"

  # mcp-output (secret in an MCP tool response) -------------------------------
  # Grade against the value only (prefix stripped): the redactor keeps the `KEY=`
  # and masks the value → `DATABASE_PASSWORD=[REDACTED]`, so grepping the full
  # `KEY=value` would false-negative. (bash-/read-output grep the full secret.)
  s=$(canary envpass); record mcp-output plaintext secret "$(drive_post "$(post_mcp "$s")" "${s#DATABASE_PASSWORD=}")"

  # bang (! shell-escape: no hook fires — structurally uncovered) -------------
  # Hardcoded `leaked` by design: there is no interception point to drive.
  record bang plaintext secret leaked

  # bang-wrapped (opt-in `agent-guard exec` mitigation) -----------------------
  s=$(canary apikey);  record bang-wrapped exec secret "$(drive_exec "${s#API_KEY=}")"
}

scanner_health_probe
run_cases

# --- render matrix + metrics --------------------------------------------------
echo
echo "agent-guard leak-prevention benchmark"
echo "engine: $("$BIN" version 2>/dev/null) | gitleaks: $(gitleaks version 2>/dev/null)"
echo
awk -F'\t' '
  NR==1 { next }
  {
    printf "  %-13s %-11s %-7s %-11s %s\n", $1, $2, $3, $4, $5
    if ($4=="error") { ec++; next }        # indeterminate (engine failure) — not scored
    if ($1=="bang-wrapped") { bw=$5; next } # opt-in mitigation — reported separately, not folded in
    if ($3=="secret" && $1!="bang") { st++; if ($5=="protected") sp++ }
    if ($3=="benign") { bt++; if ($5=="FALSE-POS") bf++ }
  }
  END {
    printf "\nmetrics\n"
    printf "  passive hook-channel leak-prevention : %d/%d secret cases protected", sp, st
    if (st>0) printf " (%.0f%%)", 100*sp/st
    printf "\n"
    printf "  ! bang channel                       : UNCOVERED (no hook fires)\n"
    printf "  ! bang + agent-guard exec (opt-in)   : %s\n", (bw=="protected" ? "masked (opt-in mitigation, NOT passive coverage)" : (bw=="" ? "n/a" : bw))
    printf "  false-positive rate                  : %d/%d benign cases mis-flagged", bf+0, bt+0
    if (bt>0) printf " (%.0f%%)", 100*(bf+0)/bt
    printf "\n"
    if (ec>0) printf "  engine errors (indeterminate)        : %d — investigate before trusting the run\n", ec
  }
' "$RESULTS"

echo
echo "matrix header: channel | variant | kind | outcome | verdict"
echo "results written to: $RESULTS"
exit 0
