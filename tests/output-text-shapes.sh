#!/usr/bin/env sh
# Synthetic text only (#590 item 7). Output masking reads a line the same way
# whatever a tool prints around it: each line of the fixture runs on its own
# and inside the text shapes of git diff, grep -n, grep -rn, rg, cat -n, a
# Markdown table, one-line JSON and the Read tool's numbered lines, on Claude
# Bash and Read PostToolUse and on Codex Bash PostToolUse. Codex has no Read
# tool; it reads files with shell commands. Every cell must give the line's
# own verdict, and a masked cell must equal the shape around the masked line,
# so only the value changes. A cell may differ only where the fixture lists it
# under differences with a reason. The run prints one table: rows are lines,
# columns are shapes.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=$ROOT/tests/fixtures/output-text-shapes.json
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-text-shapes.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_KEY_NAME_REDACT AI_AGENT

# Assembled at run time so the repository's own scan finds no credential-shaped
# literal here. The input to tr is a fixed 8 KiB, so the pipeline ends even
# where SIGPIPE is ignored (see tests/key-name-masking.sh).
draw() { head -c 8192 /dev/urandom | LC_ALL=C tr -dc "$1" 2>/dev/null | head -c "$2"; }
rnd=q7$(draw a-z 12)
hex=$(draw a-f0-9 40)
weak=$(printf '%s%s' hunter 2)
marker=$(printf '%s_%s_%s_%s' AGENT GUARD TEST SECRET)
if [ "${#rnd}" -ne 14 ] || [ "${#hex}" -ne 40 ]; then
  printf 'not ok - generated values have the wrong length: %s %s\n' "${#rnd}" "${#hex}"
  exit 1
fi

# lines.json holds each line, want.json what each line must come back as.
# Each line gets a value of its own: the guard masks every copy of a value it
# finds, so a value shared by two lines would be masked in one line because the
# other line gave it away, and the cell would not show its own verdict.
jq -c --arg r "$rnd" --arg h "$hex" --arg w "$weak" --arg g "$marker" '
  def fill($k): gsub("%R%"; $r + ([97 + $k, 97 + $k] | implode))
    | gsub("%H%"; $h) | gsub("%W%"; $w) | gsub("%G%"; $g);
  [.lines | to_entries[] | .key as $k | .value.line | fill($k)]' "$FIXTURE" >"$CASE/lines.json" || exit 1
jq -c '[.lines[] | if .expect == "mask" then .masked else .line end]' \
  "$FIXTURE" >"$CASE/want.json" || exit 1
if ! jq -e '(.lines | length) > 0
    and all(.lines[]; (.expect == "mask" and (.masked | type) == "string"
                       and .masked != .line)
                      or (.expect == "keep" and has("masked") == false))
    and ([.lines[] | select(.expect == "mask")] | length) > 0
    and ([.lines[] | select(.expect == "keep")] | length) > 0
    and ([.lines[].label] | unique | length) == (.lines | length)
    and (. as $f | all("%H%", "%W%", "%G%";
           . as $x | [$f.lines[] | select(.line | contains($x))] | length <= 1))
    and all(.differences[]; (.reason | type) == "string" and .reason != ""
                            and (.verdict | IN("M", "=", "x")))' \
    "$FIXTURE" >/dev/null 2>&1; then
  printf 'not ok - the fixture lists lines without a verdict or differences without a reason\n'
  exit 1
fi

SHAPES='plain diff grep-n grep-rn rg-heading rg-no-heading cat-n table json read-n'
PATHS='claude-bash claude-read codex-bash'
# One file stands behind every shape. Each shape puts its header lines first
# and then exactly one line per fixture line.
RENDER='def pad6: tostring | (" " * (6 - length)) + .;
  def body(f): [to_entries[] | f];
  if $shape == "plain" then .
  elif $shape == "diff" then
    ["diff --git a/config/app.yml b/config/app.yml", "--- a/config/app.yml",
     "+++ b/config/app.yml", "@@ -0,0 +1,\(length) @@"] + map("+" + .)
  elif $shape == "grep-n" then body("\(.key + 1):\(.value)")
  elif $shape == "grep-rn" then body("config/app.yml:\(.key + 1):\(.value)")
  elif $shape == "rg-heading" then ["config/app.yml"] + body("\(.key + 1):\(.value)")
  elif $shape == "rg-no-heading" then body("config/app.yml:\(.value)")
  elif $shape == "cat-n" then body("\(.key + 1 | pad6)\t\(.value)")
  elif $shape == "table" then
    ["| path | line |", "|---|---|"] + body("| config/app.yml:\(.key + 1) | \(.value) |")
  elif $shape == "json" then body({path: "config/app.yml", line: (.key + 1), text: .value} | tojson)
  elif $shape == "read-n" then body("\(.key + 1 | pad6)→\(.value)")
  else error("unknown shape \($shape)") end
  | join("\n")'
headers() {
  case $1 in diff) echo 4 ;; rg-heading) echo 1 ;; table) echo 2 ;; *) echo 0 ;; esac
}

# run_path PATH reads $CASE/in and writes what the model would see to $CASE/got.
run_path() {
  case $1 in
    claude-bash|codex-bash)
      jq -nc --rawfile t "$CASE/in" \
        '{session_id:"text-shapes",hook_event_name:"PostToolUse",tool_name:"Bash",
          tool_input:{command:"grep -rn key config"},
          tool_response:{stdout:$t,stderr:"",interrupted:false}}' ;;
    claude-read)
      jq -nc --rawfile t "$CASE/in" \
        '{session_id:"text-shapes",hook_event_name:"PostToolUse",tool_name:"Read",
          tool_input:{file_path:"config/app.yml"},
          tool_response:{type:"text",file:{filePath:"config/app.yml",content:$t,
            numLines:($t | split("\n") | length),startLine:1,
            totalLines:($t | split("\n") | length)}}}' ;;
  esac >"$CASE/event" || return 1
  AGENT_GUARD_HOOK_HOST=${1%%-*} "$GUARD" hook-post-tool \
    <"$CASE/event" >"$CASE/out" 2>"$CASE/err" || return 1
  if [ ! -s "$CASE/out" ]; then cp "$CASE/in" "$CASE/got"; return; fi
  case $1 in
    claude-bash) jq -j '.hookSpecificOutput.updatedToolOutput.stdout | strings' ;;
    claude-read) jq -j '.hookSpecificOutput.updatedToolOutput.file.content | strings' ;;
    codex-bash)
      jq -j 'select(.decision == "block") | .hookSpecificOutput.additionalContext
        | sub("^Agent Guard sanitized tool output:\n"; "") | fromjson | .stdout | strings' ;;
  esac <"$CASE/out" >"$CASE/got" && [ -s "$CASE/got" ]
}

# Each result line: shape, path, then the verdict of every fixture line.
#   =  unchanged     M  only the value masked, as the plain line is
#   x  changed some other way    ?  the hook failed or its output was unreadable
: >"$CASE/results"
for shape in $SHAPES; do
  h=$(headers "$shape")
  jq -j --arg shape "$shape" "$RENDER" "$CASE/lines.json" >"$CASE/in" || exit 1
  jq -j --arg shape "$shape" "$RENDER" "$CASE/want.json" >"$CASE/want" || exit 1
  for path in $PATHS; do
    if run_path "$path"; then
      jq -nrc --rawfile in "$CASE/in" --rawfile want "$CASE/want" \
          --rawfile got "$CASE/got" --argjson h "$h" --arg s "$shape" --arg p "$path" '
        ($in | split("\n")) as $i | ($want | split("\n")) as $w | ($got | split("\n")) as $g
        | if ($g | length) != ($i | length) or $g[0:$h] != $i[0:$h] then
            [range($h; $i | length) | "x"]
          else
            [range($h; $i | length) as $n
             | if $g[$n] == $i[$n] then "=" elif $g[$n] == $w[$n] then "M" else "x" end]
          end
        | [$s, $p, join("")] | join(" ")' >>"$CASE/results" || exit 1
    else
      jq -nr --arg s "$shape" --arg p "$path" --slurpfile l "$CASE/lines.json" \
        '[$s, $p, ($l[0] | map("?") | join(""))] | join(" ")' >>"$CASE/results"
      sed 's/^/  stderr: /' "$CASE/err"
    fi
  done
done

jq -nr --rawfile results "$CASE/results" --slurpfile fx "$FIXTURE" \
    --arg shapes "$SHAPES" --arg paths "$PATHS" '
  ($fx[0]) as $f | ($shapes | split(" ")) as $S | ($paths | split(" ")) as $P
  | ($results | split("\n") | map(select(. != "") | split(" "))
     | map({key: "\(.[0]) \(.[1])", value: (.[2] | split(""))}) | from_entries) as $r
  | def listed($l; $s; $p): [$f.differences[]
      | select(.label == $l and .shape == $s and ((.paths // $P) | index([$p]) != null))][0];
    def cell($k; $s):
      $f.lines[$k] as $line
      | [$P[] as $p
         | listed($line.label; $s; $p) as $d
         | ($r["\($s) \($p)"][$k] // "?") as $v
         | {v: $v, ok: ($v == ($d.verdict // (if $line.expect == "mask" then "M" else "=" end))),
            listed: ($d != null), p: $p}] as $c
      | {text: ((if ($c | map(.v) | unique | length) == 1 then $c[0].v else ($c | map(.v) | join("")) end)
                + (if all($c[]; .ok) | not then "!" elif any($c[]; .listed) then "~" else "" end)),
         bad: [$c[] | select(.ok | not) | "\($line.label) / \($s) / \(.p): got \(.v)"]};
    def pad($n): . + (" " * ($n - length) // "");
    ([$f.lines[] | "\(.label) (\(.expect))" | length] | max + 2) as $w
  | [range($f.lines | length) as $k | [$S[] as $s | cell($k; $s)]] as $grid
  | (["line" | pad($w)] + ($S | map(pad(14))) | join("")),
    (range($f.lines | length) as $k
     | ([$f.lines[$k] | "\(.label) (\(.expect))" | pad($w)] + ($grid[$k] | map(.text | pad(14))) | join(""))),
    "",
    "= unchanged, M only the value masked, x changed some other way, ? hook failed;",
    "one letter when every path agrees, else one per path (\($P | join(", ")));",
    "~ a listed difference, ! differs from the plain-line verdict",
    ($grid | flatten | map(.bad[]) | if length == 0 then "ok - every cell gives its expected verdict"
      else (.[] | "not ok - \(.)") end),
    ([$f.differences[] | . as $d
      | select(([$f.lines[].label] | index([$d.label])) == null or ($S | index([$d.shape])) == null)
      | "not ok - difference names an unknown line or shape: \($d.label) / \($d.shape)"] | .[])
' >"$CASE/table" || exit 1
cat "$CASE/table"
! grep -q '^not ok' "$CASE/table"
