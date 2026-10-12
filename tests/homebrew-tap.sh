#!/usr/bin/env sh
# Drive scripts/publish-homebrew-tap.sh against a fake gh that keeps the tap's
# branches and pull requests in a directory, and check what it writes.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-homebrew-tap.XXXXXX")
trap 'rm -rf "$CASE"' EXIT INT TERM

fail() { printf 'homebrew-tap: %s\n' "$*" >&2; exit 1; }

mkdir "$CASE/bin"
cat >"$CASE/bin/gh" <<'STUB'
#!/bin/sh
# Fake gh: $TAP_STATE/branches/<name>/agent-guard.rb, $TAP_STATE/prs/<branch>.
set -eu
printf '%s\n' "$*" >>"$TAP_STATE/calls"
[ -z "${TAP_FAIL_READS:-}" ] || exit 1
br_dir() { printf '%s/branches/%s' "$TAP_STATE" "$(printf '%s' "$1" | tr / _)"; }
blob() { cksum <"$1/agent-guard.rb" | awk '{print $1}'; }
cmd=$1; shift
if [ "$cmd" = pr ]; then
  sub=$1; shift
  head=; while [ $# -gt 0 ]; do [ "$1" = --head ] && head=$2; shift; done
  pr="$TAP_STATE/prs/$(printf '%s' "$head" | tr / _)"
  case $sub in
    list) [ -f "$pr" ] && cat "$pr" || printf '\n' ;;
    create) printf 'https://github.com/fake/tap/pull/1\n' >"$pr"; cat "$pr" ;;
  esac
  exit 0
fi
method=GET raw= endpoint= fields=
while [ $# -gt 0 ]; do
  case $1 in
    -X) method=$2; shift ;;
    -H) [ "$2" = 'Accept: application/vnd.github.raw' ] && raw=1; shift ;;
    -f|-F) fields="$fields $2"; shift ;;
    --jq) shift ;;
    *) endpoint=$1 ;;
  esac
  shift
done
field() { printf '%s\n' $fields | sed -n "s/^$1=//p"; }
ref=${endpoint#*\?ref=}
case "$method $endpoint" in
  "GET repos/"*"/contents/Formula/agent-guard.rb?ref="*)
    [ -f "$(br_dir "$ref")/agent-guard.rb" ] || exit 1
    if [ -n "$raw" ]; then cat "$(br_dir "$ref")/agent-guard.rb"; else blob "$(br_dir "$ref")"; fi ;;
  "GET repos/"*"/branches/"*)
    [ -d "$(br_dir "${endpoint#*/branches/}")" ] || exit 1; printf '%s\n' "${endpoint#*/branches/}" ;;
  "GET repos/"*"/git/ref/heads/main") printf '%s\n' 1111111111111111111111111111111111111111 ;;
  "POST repos/"*"/git/refs")
    new=$(br_dir "$(field ref | sed 's|^refs/heads/||')")
    [ ! -d "$new" ] || exit 1
    cp -R "$(br_dir main)" "$new" ;;
  "PUT repos/"*"/contents/Formula/agent-guard.rb")
    dir=$(br_dir "$(field branch)")
    [ "$(field sha)" = "$(blob "$dir")" ] || { echo 'stale blob sha' >&2; exit 1; }
    base64 --decode <"$(field content | sed 's/^@//')" >"$dir/agent-guard.rb"
    printf '%s\n' https://github.com/fake/tap/commit/1 ;;
  *) echo "fake gh: unhandled $method $endpoint" >&2; exit 1 ;;
esac
STUB
chmod +x "$CASE/bin/gh"
PATH="$CASE/bin:$PATH"
export PATH

zero_sha=$(printf '%064d' 0)
"$ROOT/scripts/render-homebrew-formula.sh" 3.5.0 "$zero_sha" >"$CASE/old.rb"
"$ROOT/scripts/render-homebrew-formula.sh" 3.6.0 "$zero_sha" >"$CASE/new.rb"
"$ROOT/scripts/render-homebrew-formula.sh" 3.7.0 "$zero_sha" >"$CASE/newer.rb"

# reset MAIN_FORMULA: a tap whose main carries MAIN_FORMULA and nothing else.
reset() {
  rm -rf "$CASE/tap"
  mkdir -p "$CASE/tap/branches/main" "$CASE/tap/prs"
  cp "$1" "$CASE/tap/branches/main/agent-guard.rb"
  : >"$CASE/tap/calls"
  TAP_STATE="$CASE/tap"
  export TAP_STATE
}
publish() { "$ROOT/scripts/publish-homebrew-tap.sh" "$@" >"$CASE/out" 2>&1; }
mutations() { grep -cE -- '^api -X (POST|PUT)|^pr create' "$CASE/tap/calls" || true; }
branch_rb="$CASE/tap/branches/release_agent-guard-v3.6.0/agent-guard.rb"

reset "$CASE/old.rb"
publish 3.6.0 "$CASE/new.rb" || fail "first publish failed: $(cat "$CASE/out")"
cmp -s "$branch_rb" "$CASE/new.rb" || fail 'release branch does not carry the new formula'
cmp -s "$CASE/tap/branches/main/agent-guard.rb" "$CASE/old.rb" || fail 'publish wrote to main'
[ -f "$CASE/tap/prs/release_agent-guard-v3.6.0" ] || fail 'no pull request was opened'
[ "$(mutations)" = 3 ] || fail "first publish made $(mutations) writes, want 3 (branch, file, PR)"

: >"$CASE/tap/calls"
publish 3.6.0 "$CASE/new.rb" || fail "rerun failed: $(cat "$CASE/out")"
[ "$(mutations)" = 0 ] || fail 'rerun wrote to the tap again'
grep -q 'reusing open pull request' "$CASE/out" || fail 'rerun did not reuse the open PR'

# A branch left behind with other content and no PR is brought up to date.
printf 'stale\n' >"$branch_rb"
rm "$CASE/tap/prs/release_agent-guard-v3.6.0"
: >"$CASE/tap/calls"
publish 3.6.0 "$CASE/new.rb" || fail "stale-branch publish failed: $(cat "$CASE/out")"
cmp -s "$branch_rb" "$CASE/new.rb" || fail 'stale branch was not refreshed'
[ "$(mutations)" = 2 ] || fail "stale-branch publish made $(mutations) writes, want 2 (file, PR)"

reset "$CASE/new.rb"
publish 3.6.0 "$CASE/new.rb" || fail "up-to-date publish failed: $(cat "$CASE/out")"
[ "$(mutations)" = 0 ] || fail 'an up-to-date tap was written to'

reset "$CASE/newer.rb"
if publish 3.6.0 "$CASE/new.rb"; then fail 'a downgrade was accepted'; fi
grep -q 'refusing to downgrade' "$CASE/out" || fail "downgrade refusal unclear: $(cat "$CASE/out")"
[ "$(mutations)" = 0 ] || fail 'a refused downgrade still wrote to the tap'

reset "$CASE/old.rb"
if publish 3.7.0 "$CASE/new.rb"; then fail 'a formula for another version was accepted'; fi
if publish 3.6 "$CASE/new.rb"; then fail 'a non-canonical version was accepted'; fi
[ ! -s "$CASE/tap/calls" ] || fail 'input validation ran after contacting the tap'

reset "$CASE/old.rb"
if TAP_FAIL_READS=1 publish 3.6.0 "$CASE/new.rb"; then fail 'an unreadable tap counted as success'; fi
[ "$(mutations)" = 0 ] || fail 'an unreadable tap was written to'

wf="$ROOT/.github/workflows/release.yml"
publish_line=$(grep -n 'name: Tag and publish release' "$wf" | cut -d: -f1)
tap_line=$(grep -n 'name: Open Homebrew tap PR' "$wf" | cut -d: -f1)
[ -n "$tap_line" ] && [ "$tap_line" -gt "$publish_line" ] \
  || fail 'release workflow does not open the tap PR after publishing'
sed -n "${tap_line},\$p" "$wf" >"$CASE/step"
grep -Fq "if: \${{ steps.state.outputs.publish_ready == 'true' && !inputs.dry_run }}" "$CASE/step" \
  || fail 'tap step is not gated like the publish step'
grep -Fq 'GH_TOKEN: ${{ secrets.HOMEBREW_TAP_GITHUB_TOKEN }}' "$CASE/step" \
  || fail 'tap step does not use the tap token'
grep -Fq 'if [ -z "$GH_TOKEN" ]; then' "$CASE/step" && grep -Fq 'exit 1' "$CASE/step" \
  || fail 'tap step does not fail when the token is missing'
