#!/usr/bin/env sh
# Opens (or refreshes) a pull request on the Homebrew tap that sets
# Formula/agent-guard.rb to the given release's rendered formula. Uses only the
# GitHub API through gh, so GH_TOKEN must be able to write contents and pull
# requests on the tap. Safe to rerun: an up-to-date tap, branch or PR is reused.
#
#   scripts/publish-homebrew-tap.sh 3.6.0 agent-guard.rb
set -eu

version=${1:?usage: publish-homebrew-tap.sh X.Y.Z FORMULA}
formula=${2:?usage: publish-homebrew-tap.sh X.Y.Z FORMULA}
tap=${AGENT_GUARD_HOMEBREW_TAP:-JeongJaeSoon/homebrew-tap}
path=Formula/agent-guard.rb
branch="release/agent-guard-v${version}"

die() { printf 'publish-homebrew-tap: %s\n' "$*" >&2; exit 1; }

printf '%s\n' "$version" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || die "version must be canonical X.Y.Z (got: $version)"
[ -f "$formula" ] || die "formula not found: $formula"
grep -qF "url \"https://github.com/JeongJaeSoon/agent-guard/releases/download/v${version}/agent-guard-${version}.tar.gz\"" "$formula" \
  || die "$formula does not point at the v${version} release tarball"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# Prints the file at $1 (a branch) to stdout; fails only when the file or the
# branch is missing, so callers must tell "absent" apart from an API error.
fetch_raw() {
  gh api -H 'Accept: application/vnd.github.raw' "repos/${tap}/contents/${path}?ref=$1"
}

# version_gt A B: A is a strictly newer X.Y.Z than B.
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1
  }'
}

fetch_raw main >"$tmp/main.rb" || die "cannot read ${path} on ${tap} main"
if cmp -s "$formula" "$tmp/main.rb"; then
  printf '%s\n' "${tap} main already carries agent-guard ${version}; nothing to do"
  exit 0
fi
current=$(sed -n 's|^  url "https://github.com/JeongJaeSoon/agent-guard/releases/download/v\([0-9.]*\)/.*|\1|p' "$tmp/main.rb")
[ -n "$current" ] || die "cannot find the release version in ${tap} main's ${path}"
if version_gt "$current" "$version"; then
  die "${tap} main is at ${current}, newer than ${version}; refusing to downgrade"
fi

if gh api "repos/${tap}/branches/${branch}" --jq .name >/dev/null 2>&1; then
  printf '%s\n' "reusing existing branch ${branch}"
else
  main_sha=$(gh api "repos/${tap}/git/ref/heads/main" --jq .object.sha)
  gh api -X POST "repos/${tap}/git/refs" \
    -f ref="refs/heads/${branch}" -f sha="$main_sha" --jq .ref >/dev/null
  printf '%s\n' "created branch ${branch} at ${main_sha}"
fi

if fetch_raw "$branch" >"$tmp/branch.rb" 2>/dev/null && cmp -s "$formula" "$tmp/branch.rb"; then
  printf '%s\n' "${branch} already carries the formula"
else
  blob_sha=$(gh api "repos/${tap}/contents/${path}?ref=${branch}" --jq .sha)
  base64 <"$formula" | tr -d '\n' >"$tmp/content.b64"
  gh api -X PUT "repos/${tap}/contents/${path}" \
    -f message="agent-guard ${version}" \
    -f branch="$branch" \
    -f sha="$blob_sha" \
    -F content=@"$tmp/content.b64" \
    --jq .commit.html_url
fi

url=$(gh pr list -R "$tap" --state open --base main --head "$branch" --json url --jq '.[0].url // ""')
if [ -n "$url" ]; then
  printf '%s\n' "reusing open pull request $url"
  exit 0
fi
printf '%s\n' \
  "Agent Guard v${version} 릴리스 자산 \`agent-guard.rb\`로 formula를 갱신한다." \
  "" \
  "agent-guard release workflow가 릴리스 tarball의 SHA-256으로 렌더링한 파일을 그대로 넣었다." \
  "릴리스: https://github.com/JeongJaeSoon/agent-guard/releases/tag/v${version}" \
  >"$tmp/body.md"
gh pr create -R "$tap" --base main --head "$branch" \
  --title "agent-guard ${version}" --body-file "$tmp/body.md"
