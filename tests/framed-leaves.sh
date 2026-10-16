#!/usr/bin/env sh
# Compare the optimized framing path with its byte decoder, keeping the same
# detector and explicit output assertions. No production bypass is introduced.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-framing.XXXXXX")
trap 'rm -rf "$CASE"' 0
awk '
  /^frame_json_string_leaves\(\)/ { copying=1 }
  /^# Treat malformed byte counts/ { exit }
  copying { print }
' "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CASE/fast.sh"
# Force only the bulk framing path off: the existing byte decoder is the
# reference for escaping, physical newlines, leaf boundaries and output modes.
[ "$(grep -c 'if (!escaped && index' "$CASE/fast.sh")" -eq 1 ]
sed 's/if (!escaped \&\& index/if (0 \&\& !escaped \&\& index/' \
  "$CASE/fast.sh" >"$CASE/slow.sh"
printf '\nsecretish_env_values "$1"\n' >>"$CASE/fast.sh"
printf '\nsecretish_env_values "$1"\n' >>"$CASE/slow.sh"

jq -nc '[
  [""],
  ["clean", "PASSWORD=framing-alpha-value", "TOKEN=framing-beta-value"],
  ["PASSWORD=\"first line\nsecond line\"", "TOKEN=framing-next-value"],
  ["PASSWORD=\"unfinished", "clean", "TOKEN=framing-next-value"],
  ["PASSWORD=\"trailing\n"],
  ["PASSWORD=framing-\u001e-rs", "TOKEN=framing-\u001f-us"],
  ["clean\n", "\n", "PASSWORD=framing-tail-value\n"],
  ["日本語🙂", "PASSWORD=framing-日本語🙂-value", "TOKEN=framing-next-value"],
  [("日本語🙂" * 1024) + " PASSWORD=framing-unicode-prefix", "TOKEN=framing-next-value"],
  [("a" * 4096) + " PASSWORD=framing-after-prefix", "TOKEN=framing-last-value"],
  ["PASSWORD=\"a\u001f\u001eb\nline\"", "TOKEN=framing-next-value"]
] | .[]' >"$CASE/cases.jsonl"
count=0
while IFS= read -r leaves; do
  count=$((count + 1))
  printf '%s' "$leaves" | jq -rj '.[] |
    ((gsub("\u001f"; "\u001f\u001f") | gsub("\u001e"; "\u001f\u001e")) + "\u001e\n")' >"$CASE/input"
  for mode in json framed probe; do
    sh "$CASE/fast.sh" "$mode" <"$CASE/input" >"$CASE/fast.out"
    sh "$CASE/slow.sh" "$mode" <"$CASE/input" >"$CASE/slow.out"
    cmp "$CASE/fast.out" "$CASE/slow.out"
  done
done <"$CASE/cases.jsonl"

# Exercise decoder fallbacks not emitted by the JSON producer: multiple leaf
# boundaries in one physical record, pending escape, partial record, and raw
# invalid UTF-8. Framed mode must preserve bytes rather than reinterpret them.
for fixture in boundaries pending partial invalid; do
  case "$fixture" in
    boundaries) printf 'PASSWORD=framing-first\036TOKEN=framing-second\036\n' ;;
    pending) printf 'clean\037\nPASSWORD=framing-next\036\n' ;;
    partial) printf '%s="framing-unfinished' PASSWORD ;;
    invalid) printf 'PASSWORD=framing-\377-value\036\nTOKEN=framing-next\036\n' ;;
  esac >"$CASE/input"
  for mode in json framed probe; do
    sh "$CASE/fast.sh" "$mode" <"$CASE/input" >"$CASE/fast.out"
    sh "$CASE/slow.sh" "$mode" <"$CASE/input" >"$CASE/slow.out"
    cmp "$CASE/fast.out" "$CASE/slow.out"
  done
done

# Normal JSON mode must emit every finding, not adopt probe's early exit.
printf 'PASSWORD=framing-first\036\nTOKEN=framing-second\036\n' \
  | sh "$CASE/fast.sh" json >"$CASE/actual"
printf '"framing-first"\n"framing-second"\n' >"$CASE/expected"
cmp "$CASE/actual" "$CASE/expected"
# Empty leaves and a preceding unclosed quote cannot swallow a later finding.
# Assemble the quoted synthetic assignment at runtime, as in other fixtures.
printf '%s="framing-first\036\n\036\nTOKEN=framing-second\036\n' PASSWORD \
  | sh "$CASE/fast.sh" json >"$CASE/actual"
cmp "$CASE/actual" "$CASE/expected"

# Framed output preserves all findings and raw non-UTF-8 bytes independently
# of the differential oracle.
printf 'PASSWORD=framing-first\036\nTOKEN=framing-\377-value\036\n' \
  | sh "$CASE/fast.sh" framed >"$CASE/actual"
printf 'Sframing-first\036Sframing-\377-value\036' >"$CASE/expected"
cmp "$CASE/actual" "$CASE/expected"

# A failed awk producer must keep its nonzero status even after partial output.
mkdir "$CASE/bin"
printf '#!/bin/sh\nprintf partial\nexit 23\n' >"$CASE/bin/awk"
chmod +x "$CASE/bin/awk"
for engine in fast slow; do
  status=0
  PATH="$CASE/bin:$PATH" sh "$CASE/$engine.sh" json </dev/null >"$CASE/$engine.out" || status=$?
  [ "$status" -eq 23 ]
done
cmp "$CASE/fast.out" "$CASE/slow.out"
printf 'ok - %s JSON leaf fixtures, four raw boundary fixtures, all three modes and producer failure\n' "$count"
