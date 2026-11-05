#!/bin/sh
# Real published source -> candidate update; only candidate HTTP is substituted.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
: "${AGENT_GUARD_NATIVE_ARTIFACT_DIR:?all four qualified artifacts required}"
previous=${1:-3.6.14}
case "$previous" in
  3.6.14) previous_bootstrap_sha=2f6a796c1249d1a4ecdfa9b41507dcd61f34cc42dbb43013769c7cbac3112e12 ;;
  3.7.1) previous_bootstrap_sha=a28827587c60a02c44567a480e1e0e08bf517c407f64e8b28fa4450aee75b64e ;;
  *) echo 'unqualified previous release' >&2; exit 2 ;;
esac
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
mkdir -p "$case_dir/download" "$case_dir/http-bin" "$case_dir/home"
version=$(sed -n 's/^VERSION=//p' "$ROOT/plugins/agent-guard/bin/agent-guard")
sh "$ROOT/scripts/build-release-tarball.sh" "$version" "$case_dir/download/agent-guard-$version.tar.gz"
(cd "$case_dir/download" && shasum -a 256 "agent-guard-$version.tar.gz" > "agent-guard-$version.tar.gz.sha256")
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$previous/bootstrap.sh" -o "$case_dir/old-bootstrap.sh"
printf '%s  %s\n' "$previous_bootstrap_sha" "$case_dir/old-bootstrap.sh" | shasum -a 256 -c -
env HOME="$case_dir/home" AGENT_GUARD_VERSION="$previous" AGENT_GUARD_HOME="$case_dir/install" \
  AGENT_GUARD_BIN_DIR="$case_dir/public" sh "$case_dir/old-bootstrap.sh" > "$case_dir/old.log" 2>&1 \
  || { cat "$case_dir/old.log" >&2; exit 1; }
"$case_dir/public/agent-guard" version | grep -Fx "agent-guard $previous"
printf 'preserve local file\n' > "$case_dir/install/local-note"
cat > "$case_dir/http-bin/curl" <<'HTTP'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out=$1 ;; esac
  shift
done
case "$out" in
  */bootstrap.sh) cp "$NATIVE_INSTALL_SOURCE/bootstrap.sh" "$out" ;;
  *.tar.gz|*.tar.gz.sha256) cp "$NATIVE_INSTALL_DOWNLOAD/${out##*/}" "$out" ;;
  *) exit 2 ;;
esac
HTTP
chmod 755 "$case_dir/http-bin/curl"
export NATIVE_INSTALL_SOURCE="$ROOT" NATIVE_INSTALL_DOWNLOAD="$case_dir/download"
env HOME="$case_dir/home" PATH="$case_dir/http-bin:$PATH" AGENT_GUARD_VERSION="$version" \
  AGENT_GUARD_HOME="$case_dir/install" "$case_dir/public/agent-guard" update > "$case_dir/update.log" 2>&1 \
  || { cat "$case_dir/update.log" >&2; exit 1; }
grep 'preserve local file' "$case_dir/install/local-note"
test -d "$case_dir/install/libexec"
env HOME="$case_dir/home" PATH="$case_dir/http-bin:$PATH" AGENT_GUARD_VERSION="$version" \
  AGENT_GUARD_HOME="$case_dir/fresh" AGENT_GUARD_BIN_DIR="$case_dir/fresh-bin" \
  sh "$ROOT/bootstrap.sh" > "$case_dir/fresh.log" 2>&1 \
  || { cat "$case_dir/fresh.log" >&2; exit 1; }
for prefix in install fresh; do
  (cd "$case_dir/$prefix/libexec" && shasum -a 256 -c ./*.sha256)
  "$case_dir/$prefix/bin/agent-guard" version | grep "agent-guard $version"
  env HOME="$case_dir/home" AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust "$case_dir/$prefix/bin/agent-guard" smoke-test
done
before=$(shasum -a 256 "$case_dir/install/bin/agent-guard")
mkdir "$case_dir/broken"
tar -xzf "$case_dir/download/agent-guard-$version.tar.gz" -C "$case_dir/broken"
printf 'broken\n' >> "$case_dir/broken/libexec/agent-guard-redact-x86_64-unknown-linux-musl"
tar -czf "$case_dir/download/agent-guard-$version.tar.gz" -C "$case_dir/broken" .
(cd "$case_dir/download" && shasum -a 256 "agent-guard-$version.tar.gz" > "agent-guard-$version.tar.gz.sha256")
if env HOME="$case_dir/home" PATH="$case_dir/http-bin:$PATH" AGENT_GUARD_VERSION="$version" \
  AGENT_GUARD_HOME="$case_dir/install" "$case_dir/public/agent-guard" update > "$case_dir/broken.log" 2>&1; then
  echo 'corrupted native payload was installed' >&2; exit 1
fi
grep 'native checksum mismatch' "$case_dir/broken.log"
test "$before" = "$(shasum -a 256 "$case_dir/install/bin/agent-guard")"
(cd "$case_dir/install/libexec" && shasum -a 256 -c ./*.sha256)
printf 'passed: compiler-free fresh install and published %s -> candidate update\n' "$previous"
