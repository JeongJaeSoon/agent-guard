#!/usr/bin/env sh
set -u

# Claude Code checks a PostToolUse replacement for a built-in tool against that
# tool's output schema and, on a mismatch, gives the model the original output.
# A replacement that masks a field the host reads as one of a few values (Read's
# `type`, Grep's `mode`) therefore hides nothing (#612). For each output in the
# fixture, on each rewrite path (a scanned secret, an output too large to scan,
# and the closed policy with no scanner), the replacement must keep every key,
# the type of every value, those fields, every number and boolean, image bytes
# and a file path equal to the one in tool_input, and must still drop the
# planted value. Where a rewrite cannot keep the shape, stderr must not say the
# output was masked. The fixed replacement each tool gets when nothing can
# rewrite its output must fit that tool's output schema.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=$ROOT/tests/fixtures/claude-output-shapes.json
OUTPUTS=$ROOT/tests/fixtures/claude-tool-outputs.json
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-output-shape.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/repo" || exit 1
cd "$CASE/repo" || exit 1
git init -q || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_INFRA_FAILURE_MODE AI_AGENT
S=AGENT_GUARD_TEST_SECRET
passed=0
failed=0

ok() { passed=$((passed + 1)); }
not_ok() {
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"
}

# Over the output scan cap (320 KiB), so the guard masks every string leaf.
awk 'BEGIN { while (n < 340000) { printf "x"; n++ } }' >"$CASE/pad" || exit 1
awk 'BEGIN { while (n < 340000) { printf "A"; n++ } }' >"$CASE/pad-image" || exit 1

# event INDEX SESSION [large|large-pages] writes one PostToolUse event.
event() {
  jq -c --argjson i "$1" --arg s "$S" --arg id "$2" --arg mode "${3:-}" \
    --rawfile pad "$CASE/pad" --rawfile image "$CASE/pad-image" '
    def plant: if type == "object" then with_entries(.value |= plant)
      elif type == "array" then map(plant)
      elif type == "string" then (split("{{SECRET}}") | join($s)) else . end;
    def grow: if type == "object" then with_entries(.value |= grow)
      elif type == "array" then map(grow)
      elif type == "string" and contains($s) then . + $pad else . end;
    .cases[$i]
    | {session_id: $id, hook_event_name: "PostToolUse", tool_name: .tool,
       tool_input: .tool_input,
       tool_response: (.output | plant
         | if $mode == "large" then grow
           elif $mode == "large-pages" then .pages[0].base64 = $image
           else . end)}
  ' "$FIXTURE" >"$CASE/event"
}

run_post() {
  env "$@" AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-post-tool \
    <"$CASE/event" >"$CASE/out" 2>"$CASE/err"
}

# kept_shape OUT WORDS reads the event and the guard's stdout OUT and is true
# when the replacement keeps the output's shape as the header describes. WORDS
# is the case's JSON array of host-read field paths. Both documents ride files:
# a large one exceeds Linux's per-argument limit.
KEPT='def kinds: if type == "object" then with_entries(.value |= kinds)
    elif type == "array" then map(kinds) else type end;
  ($ev[0].tool_response) as $o
  | ($out[0].hookSpecificOutput.updatedToolOutput) as $u
  | ([$ev[0].tool_input.file_path, $ev[0].tool_input.notebook_path]
     | map(select(type == "string"))) as $inputs
  | ($out | length) == 1
    and ($u | kinds) == ($o | kinds)
    and all($words[]; . as $p | ($u | getpath($p)) == ($o | getpath($p)))
    and all($o | paths(type == "number" or type == "boolean");
            . as $p | ($u | getpath($p)) == ($o | getpath($p)))
    and all($o | paths(type == "string");
            . as $p | ($p[-1] == "base64"
                       or ((["filePath", "notebook_path"] | index([$p[-1]])) != null
                           and ($inputs | index([$o | getpath($p)])) != null))
                      | not or (($u | getpath($p)) == ($o | getpath($p))))
    and ($u | tojson | contains($s) | not)
    and (($o | tojson | contains($s) | not) or ($u | tojson | contains("[REDACTED]")))'

kept_shape() {
  jq -e -n --slurpfile out "$1" --slurpfile ev "$CASE/event" \
    --argjson words "$2" --arg s "$S" "$KEPT" >/dev/null 2>&1
}

cases=$(jq '.cases | length' "$FIXTURE") || exit 1
index=0
while [ "$index" -lt "$cases" ]; do
  label=$(jq -r --argjson i "$index" '.cases[$i].label' "$FIXTURE")
  words=$(jq -c --argjson i "$index" '.cases[$i].words' "$FIXTURE")
  planted=$(jq -r --argjson i "$index" '.cases[$i].output | tojson | contains("{{SECRET}}")' "$FIXTURE")
  for path in scanned large closed; do
    case $path in
      scanned) event "$index" "output-shape-$index-$path"; run_post ;;
      large) event "$index" "output-shape-$index-$path" large; run_post ;;
      closed)
        event "$index" "output-shape-$index-$path"
        run_post AGENT_GUARD_INFRA_FAILURE_MODE=closed AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks"
        ;;
    esac
    status=$?
    expected=0
    [ "$path" != closed ] || expected=2
    if [ "$planted:$path" = false:scanned ] || [ "$planted:$path" = false:large ]; then
      # Nothing to find: a clean output is left alone.
      [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ]
    else
      [ "$status" -eq "$expected" ] && kept_shape "$CASE/out" "$words"
    fi
    if [ "$?" -eq 0 ]; then ok; else
      not_ok "$label: $path rewrite keeps the output's shape (status $status)"
      [ ! -s "$CASE/out" ] || head -c 600 "$CASE/out" | sed 's/^/  stdout: /'
    fi
  done
  index=$((index + 1))
done
if [ "$cases" -ge 21 ]; then ok; else not_ok "output shape fixture lists $cases cases"; fi

# The PDF page read that #612 saw: page images over the scan cap. The images
# pass through like any other image bytes and only the page error is masked.
parts=$(jq '[.cases[].label] | index("Read PDF pages")' "$FIXTURE")
words=$(jq -c --argjson i "$parts" '.cases[$i].words' "$FIXTURE")
event "$parts" output-shape-large-pages large-pages
run_post
status=$?
if [ "$status" -eq 0 ] && kept_shape "$CASE/out" "$words" \
   && jq -e '.hookSpecificOutput.updatedToolOutput.pages[1].error == "page 2: [REDACTED]"' \
        "$CASE/out" >/dev/null 2>&1; then ok; else
  not_ok "Read PDF pages with large page images: only the page error is masked (status $status)"
fi
grep -q 'masked secret-like values in Read output' "$CASE/err" || \
  not_ok "a replacement that keeps the shape still reports the masking"

# The checker must reject a replacement that changes a host-read field or a
# file path: these are the rewrites the host threw away.
text=$(jq '[.cases[].label] | index("Read text file")' "$FIXTURE")
event "$text" output-shape-control
run_post
for broken in '.type = "[REDACTED]"' '.file.filePath = "[REDACTED]"' '.file.numLines = 0'; do
  jq -c ".hookSpecificOutput.updatedToolOutput |= ($broken)" "$CASE/out" >"$CASE/broken" || exit 1
  if kept_shape "$CASE/out" '[["type"]]' && ! kept_shape "$CASE/broken" '[["type"]]'; then ok; else
    not_ok "the shape check rejects a replacement where $broken"
  fi
done

# A Read type the guard does not know is masked with the rest of a large
# output. The host would reject that replacement, so stderr must not say the
# output was masked or withheld without saying the original may get through.
event "$text" output-shape-unknown-type large
jq -c '.tool_response.type = "brand_new_kind"' "$CASE/event" >"$CASE/event.new" \
  && mv "$CASE/event.new" "$CASE/event" || exit 1
run_post
status=$?
if [ "$status" -eq 0 ] \
   && jq -e '.hookSpecificOutput.updatedToolOutput.type == "[REDACTED]"' "$CASE/out" >/dev/null 2>&1 \
   && ! grep -q 'masked secret-like values' "$CASE/err" \
   && grep -q 'original output unchanged' "$CASE/err"; then ok; else
  not_ok "an unknown Read type: stderr does not claim the output was masked (status $status)"
fi
run_post AGENT_GUARD_INFRA_FAILURE_MODE=closed AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks"
status=$?
if [ "$status" -eq 2 ] && grep -q 'original output unchanged' "$CASE/err"; then ok; else
  not_ok "an unknown Read type under the closed policy: stderr says the original may get through (status $status)"
fi

# An enum value the guard does not know in a Code Mode result is masked with
# the rest of a large output, so stderr must say the original may get through.
for unknown in 'Poll delivers events from each authority|.tool_response.provenance[0].authority = "brand-new-authority"' \
               'REPL stopped by a refusal|.tool_response.stoppedBy = "brand-new-reason"'; do
  index=$(jq --arg l "${unknown%%|*}" '[.cases[].label] | index($l)' "$FIXTURE")
  event "$index" output-shape-unknown-word large
  jq -c "${unknown#*|}" "$CASE/event" >"$CASE/event.new" && mv "$CASE/event.new" "$CASE/event" || exit 1
  run_post
  status=$?
  if [ "$status" -eq 0 ] && [ -s "$CASE/out" ] \
     && ! grep -q 'masked secret-like values' "$CASE/err" \
     && grep -q 'original output unchanged' "$CASE/err"; then ok; else
    not_ok "${unknown%%|*} with an unknown enum value: stderr does not claim the output was masked (status $status)"
  fi
done

# The fixed replacement for each tool, and the recorded output it stands in
# for, must fit that tool's 2.1.330 output schema: every required field with
# its kind, no key the schema lacks, and an allowed value in each enum field.
# Eval is the REPL tool under another name.
SCHEMA='def kind_ok($k): type as $t | $k == "any" or ($k | split("|") | index([$t])) != null;
  def has_at($p): ($p | split(".")) as $q
    | try (getpath($q[:-1]) | type == "object" and has($q[-1])) catch false;
  def at($p): getpath($p | split("."));
  . as $f
  | ($schema.required | to_entries
     | all(.key as $p | .value as $k | ($f | has_at($p)) and ($f | at($p) | kind_ok($k))))
  and ($schema.optional | to_entries
     | all(.key as $p | .value as $k | ($f | has_at($p) | not) or ($f | at($p) | kind_ok($k))))
  and ($f | keys | all(. as $key | $schema.required + $schema.optional | has($key)))
  and (($schema.words // {}) | to_entries
     | all(.key as $p | .value as $vs | ($f | has_at($p) | not) or ($vs | index([$f | at($p)])) != null))'

fits_schema() {  # TOOL JSON
  jq -e -n --argjson f "$2" --slurpfile fx "$FIXTURE" --arg tool "$1" '
    $fx[0].schemas[if $tool == "Eval" then "REPL" else $tool end] as $schema
    | $schema != null and ($f | '"$SCHEMA"')' >/dev/null 2>&1
}

count=0
for name in $(jq -r '.tools | keys[]' "$OUTPUTS"); do
  count=$((count + 1))
  for part in fixed output; do
    doc=$(jq -c --arg tool "$name" --arg part "$part" '.tools[$tool][$part]' "$OUTPUTS") || exit 1
    if fits_schema "$name" "$doc"; then ok; else
      not_ok "$name $part fits the tool's output schema"
    fi
  done
done
if [ "$count" -ge 12 ]; then ok; else not_ok "outputs fixture lists $count tools"; fi
for broken in 'Write|.type = "[REDACTED]"' 'Bash|del(.interrupted)' 'REPL|.stoppedBy = "[REDACTED]"' \
              'Grep|.numFiles = "0"' 'Poll|.extra = 1'; do
  doc=$(jq -c --arg tool "${broken%%|*}" ".tools[\$tool].fixed | ${broken#*|}" "$OUTPUTS") || exit 1
  if fits_schema "${broken%%|*}" "$doc"; then
    not_ok "the schema check rejects a ${broken%%|*} replacement where ${broken#*|}"
  else ok; fi
done

printf 'output shape assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
