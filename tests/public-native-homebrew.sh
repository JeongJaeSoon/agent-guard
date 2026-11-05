#!/bin/sh
# Run only in a disposable CI runner: exercises real Homebrew install/upgrade.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
version=${1:?published version required}
out=${2:?new evidence directory required}
previous=${3:-3.7.1}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
case "$previous" in 3.6.14|3.6.15|3.7.0|3.7.1) ;; *) echo 'unqualified previous release' >&2; exit 2 ;; esac
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'requires a disposable Actions runner' >&2; exit 2; }
[ ! -e "$out" ] || exit 2
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd -P)
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
brew_prefix=$(brew --prefix)
export PATH="$brew_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if command -v cargo || command -v rustc; then
  echo 'Rust compiler visible on runtime test PATH' >&2; exit 1
fi
brew config > "$out/brew-config.txt"
# Homebrew resets author environment variables in tap-new. Initialise its
# temporary Git repository ourselves without changing global Git settings.
brew tap-new --no-git agent-guard-validation/releases
tap=$(brew --repo agent-guard-validation/releases)
git -C "$tap" init --initial-branch=main
git -C "$tap" add --all
git -C "$tap" -c user.name='Agent Guard release validation' \
  -c user.email='release-validation@example.invalid' -c commit.gpgsign=false \
  commit -m 'Create disposable release-validation tap'
mkdir -p "$tap/Formula"
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$previous/agent-guard.rb" -o "$tap/Formula/agent-guard.rb"
brew install agent-guard-validation/releases/agent-guard > "$out/install-old.log" 2>&1
agent-guard version | grep -F "agent-guard $previous"
printf '%s\n' "$previous" > "$out/upgrade-from.txt"
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$version/agent-guard.rb" -o "$out/published-formula.rb"
cp "$out/published-formula.rb" "$tap/Formula/agent-guard.rb"
brew upgrade agent-guard-validation/releases/agent-guard > "$out/upgrade.log" 2>&1
agent-guard version | grep -F "agent-guard $version"
brew test agent-guard-validation/releases/agent-guard >> "$out/upgrade.log" 2>&1
prefix=$(brew --prefix agent-guard)
(cd "$prefix/libexec/libexec" && shasum -a 256 -c ./*.sha256) > "$out/native-checksums.txt"
if agent-guard update > "$out/standalone-refused.log" 2>&1; then
  echo 'Homebrew install accepted standalone update' >&2; exit 1
fi
grep -F 'update is unavailable for Homebrew installs' "$out/standalone-refused.log"
# Upgrade intentionally retained the old keg for recovery. Remove both test
# versions before untapping so the following canonical-tap install is fresh.
brew uninstall --force agent-guard-validation/releases/agent-guard
brew untap agent-guard-validation/releases
brew tap JeongJaeSoon/tap
cmp "$out/published-formula.rb" "$(brew --repo JeongJaeSoon/tap)/Formula/agent-guard.rb"
brew install JeongJaeSoon/tap/agent-guard > "$out/install-tap.log" 2>&1
agent-guard version | grep -F "agent-guard $version"
brew test JeongJaeSoon/tap/agent-guard >> "$out/install-tap.log" 2>&1
prefix=$(brew --prefix agent-guard)
if [ -f "$prefix/libexec/scripts/output-pipeline-experiment.sh" ]; then
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Darwin:x86_64) target=x86_64-apple-darwin ;;
    Darwin:arm64) target=aarch64-apple-darwin ;;
    *) exit 2 ;;
  esac
  AGENT_GUARD_TEST_PAYLOAD="$prefix/libexec" sh "$ROOT/tests/fused-packaged.sh" \
    "$prefix/libexec/libexec/agent-guard-redact-$target" "$(command -v gitleaks)" > "$out/fused-packaged.log"
fi
brew list --versions agent-guard > "$out/installed-version.txt"
printf 'passed: published formula upgrade and canonical tap fresh install\n'
