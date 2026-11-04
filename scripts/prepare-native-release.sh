#!/bin/sh
# Consume only successful main-push artifacts built from the release commit.
set -eu
sha=${1:?release commit required}
out=${2:?new native artifact directory required}
repo=${GITHUB_REPOSITORY:-JeongJaeSoon/agent-guard}
case "$sha" in *[!0-9a-f]*|'') exit 2 ;; esac
[ "${#sha}" -eq 40 ] || exit 2
[ ! -e "$out" ] || { echo 'native release output already exists' >&2; exit 2; }
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
gh api "repos/$repo/actions/workflows/native-platforms.yml/runs?head_sha=$sha&event=push&per_page=100" > "$tmp/runs.json"
run=$(jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha and .head_branch == "main" and .event == "push")] | sort_by(.id) | last | select(.status == "completed" and .conclusion == "success") | .id' "$tmp/runs.json")
[ -n "$run" ] && [ "$run" != null ] || { echo 'no successful native main workflow for release SHA' >&2; exit 2; }
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin; do
  name="agent-guard-redact-$target"
  gh run download "$run" --repo "$repo" --name "native-$target" --dir "$tmp/$target"
  [ "$(head -n 1 "$tmp/$target/$name.build.txt")" = "$sha" ] \
    || { echo "artifact source does not match release SHA: $target" >&2; exit 2; }
  jq -e '.failed == 0 and .passed == 1024' "$tmp/$target/differential.json" >/dev/null
  jq -e '.failed == 0 and .passed == 90 and .native_invocation_verified == true' "$tmp/$target/integration.json" >/dev/null
  expected=$(cat "$tmp/$target/$name.sha256")
  actual=$(CDPATH= cd -- "$tmp/$target" && shasum -a 256 "$name")
  [ "$expected" = "$actual" ] || { echo "artifact checksum mismatch: $target" >&2; exit 2; }
  cp "$tmp/$target/$name" "$tmp/$target/$name.sha256" "$out/"
  chmod 755 "$out/$name"
done
jq -n --arg sha "$sha" --arg repo "$repo" --argjson run "$run" \
  '{release_sha:$sha,native_workflow_url:("https://github.com/"+$repo+"/actions/runs/"+($run|tostring)),targets:["x86_64-unknown-linux-musl","aarch64-unknown-linux-musl","x86_64-apple-darwin","aarch64-apple-darwin"]}' > "$out/native-validation.json"
