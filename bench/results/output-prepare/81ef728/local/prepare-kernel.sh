#!/bin/sh
set -eu
out=/workspace/agent-guard-evidence/candidate-1/kernel
mkdir "$out"
jq -c .tool_response /workspace/agent-guard-evidence/profile-v3.7.0/input.json > "$out/response.json"
cat > "$out/baseline" <<'SH'
#!/bin/sh
set -eu
jq -rj 'if type == "string" then . else [.. | strings] | join("\n") end' "$1/response.json" > "$1/plain"
jq -rj '.. | strings | (split("\u001f") | join("\u001f\u001f")) | (split("\u001e") | join("\u001f\u001e")) | . + "\u001e\n"' "$1/response.json" > "$1/framed"
SH
cat > "$out/candidate" <<'SH'
#!/bin/sh
exec /workspace/agent-guard-output/native/redaction-core/target/release/agent-guard-redact prepare-v1 "$1/plain" "$1/framed" < "$1/response.json"
SH
chmod 755 "$out/baseline" "$out/candidate"
: > "$out/plain"
: > "$out/framed"
"$out/baseline" "$out"
cp "$out/plain" "$out/plain.expected"
cp "$out/framed" "$out/framed.expected"
for round in 1 2 3 4 5 6 7 8 9; do
  order='baseline candidate'
  case "$round" in 2|4|6|8) order='candidate baseline' ;; esac
  for variant in $order; do
    /workspace/agent-guard-output/native/devtools/target/release/agent-guard-devtools resource-sample "$out/$variant-$round.json" "$out/$variant" "$out" > "$out/$variant-$round.stdout" 2> "$out/$variant-$round.stderr"
    cmp "$out/plain" "$out/plain.expected"
    cmp "$out/framed" "$out/framed.expected"
  done
done
