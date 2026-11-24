#!/bin/sh
# Consume qualified artifacts from the checked source tree.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
sha=${1:?release commit required}
out=${2:?new native artifact directory required}
release_sha=${3:-$sha}
repo=${GITHUB_REPOSITORY:-JeongJaeSoon/agent-guard}
case "$sha" in *[!0-9a-f]*|'') exit 2 ;; esac
[ "${#sha}" -eq 40 ] || exit 2
[ ! -e "$out" ] || { echo 'native release output already exists' >&2; exit 2; }
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
if [ "$release_sha" != "$sha" ]; then
  [ "$(git rev-parse "$release_sha^{tree}")" = "$(git rev-parse "$sha^{tree}")" ] \
    || { echo 'native source and release trees differ' >&2; exit 2; }
fi
gh api "repos/$repo/actions/workflows/native-platforms.yml/runs?head_sha=$sha&per_page=100" > "$tmp/runs.json"
run=$(jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha and
  ((.head_branch == "main" and .event == "push") or
   (.event == "workflow_dispatch" and (.head_branch | startswith("release/")))))]
  | map(select(.status == "completed")) | sort_by(.id) | last | select(.conclusion == "success") | .id' "$tmp/runs.json")
[ -n "$run" ] && [ "$run" != null ] || { echo 'no successful native workflow for checked source SHA' >&2; exit 2; }
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin; do
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
  # The warm gitleaks helper archive of the same run (#569): built from this
  # commit, tested from the archive, and holding exactly the two binaries the
  # release's CLI pins, so `setup --install-gitleaks-helper` accepts it.
  helper="agent-guard-gitleaks-helper-$target"
  [ "$(head -n 1 "$tmp/$target/$helper.build.txt")" = "$sha" ] \
    || { echo "helper source does not match release SHA: $target" >&2; exit 2; }
  grep -Eq '^passed: [1-9][0-9]*$' "$tmp/$target/gitleaks-helper.log" && grep -Fxq 'failed: 0' "$tmp/$target/gitleaks-helper.log" \
    || { echo "helper tests did not pass: $target gitleaks-helper.log" >&2; exit 2; }
  # The corpus suite prints its own result lines; hold them to its own pass
  # condition: every input compared, no difference, and at least 98 of 100
  # eligible inputs answered by the warm helper.
  awk '
    $1 == "inputs:" && $3 == "of" {
      compared = $2 + 0; inputs = $4 + 0
      for (i = 5; i < NF; i++) {
        if ($i == "answers:") answered = $(i + 1) + 0
        if ($i == "differences:") { differences = $(i + 1); result = 1 }
      }
    }
    /^eligible for the helper: [0-9]+$/ { eligible = $NF + 0; counted = 1 }
    END { exit !(result && counted && compared > 0 && compared == inputs && differences == "0" && answered * 100 >= eligible * 98) }
  ' "$tmp/$target/gitleaks-helper-corpus.log" \
    || { echo "helper tests did not pass: $target gitleaks-helper-corpus.log" >&2; exit 2; }
  expected=$(cat "$tmp/$target/$helper.tar.gz.sha256")
  actual=$(CDPATH= cd -- "$tmp/$target" && shasum -a 256 "$helper.tar.gz")
  [ "$expected" = "$actual" ] || { echo "helper archive checksum mismatch: $target" >&2; exit 2; }
  mkdir "$tmp/$target/helper"
  tar -xzf "$tmp/$target/$helper.tar.gz" -C "$tmp/$target/helper" agent-guard-gitleaks-helper agent-guard-scan
  awk -v target="$target" 'NF == 2 && index($2, target "/") == 1 { sub(/^.*\//, "", $2); print $1 "  " $2 }' \
    "$ROOT/plugins/agent-guard/config/gitleaks-helper.sha256" > "$tmp/$target/helper-pins"
  [ "$(grep -c . "$tmp/$target/helper-pins")" = 2 ] \
    && (CDPATH= cd -- "$tmp/$target/helper" && shasum -a 256 -c ../helper-pins >/dev/null) \
    || { echo "helper binaries differ from the pinned checksums: $target" >&2; exit 2; }
  # Binaries are published only with their license notices: the archive's
  # file must have a section for every module the license table names, which
  # are the modules the build links (tests/gitleaks-helper-notices.sh).
  tar -xzf "$tmp/$target/$helper.tar.gz" -C "$tmp/$target/helper" THIRD_PARTY_LICENSES.txt LICENSE 2>/dev/null \
    || { echo "helper archive carries no license notices: $target" >&2; exit 2; }
  awk '!/^#/ && NF { print "## " $1 " " $2 }' "$ROOT/native/gitleaks-helper/module-licenses.txt" > "$tmp/$target/helper-headings"
  [ -s "$tmp/$target/helper-headings" ] || { echo 'the helper license table is empty' >&2; exit 2; }
  while IFS= read -r heading; do
    grep -Fxq -- "$heading" "$tmp/$target/helper/THIRD_PARTY_LICENSES.txt" \
      || { echo "helper license notices lack ${heading#\#\# }: $target" >&2; exit 2; }
  done < "$tmp/$target/helper-headings"
  cp "$tmp/$target/$helper.tar.gz" "$tmp/$target/$helper.tar.gz.sha256" "$out/"
done
jq -n --arg sha "$release_sha" --arg source "$sha" --arg repo "$repo" --argjson run "$run" \
  '{release_sha:$sha,source_sha:$source,native_workflow_url:("https://github.com/"+$repo+"/actions/runs/"+($run|tostring)),targets:["x86_64-unknown-linux-musl","aarch64-unknown-linux-musl","aarch64-apple-darwin"]}' > "$out/native-validation.json"
