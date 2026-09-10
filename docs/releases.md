# Maintainer release handoff

This is the manual handoff from a published Agent Guard GitHub release to the
separate Homebrew tap. It does not publish a release, modify the tap, or merge a
pull request by itself.

Run it from an Agent Guard source checkout, only after the release workflow has published the versioned tarball,
SHA-256 file, and generated `agent-guard.rb` asset. The tap is a separate
repository, so the release workflow intentionally has no cross-repository write
credential.

## Verify the published assets

Use a clean temporary directory and the exact version being handed off:

```sh
version=3.3.0
release_dir=$(mktemp -d)
trap 'rm -rf "$release_dir"' EXIT INT TERM

gh release download "v$version" --repo JeongJaeSoon/agent-guard \
  --dir "$release_dir" \
  --pattern "agent-guard-$version.tar.gz" \
  --pattern "agent-guard-$version.tar.gz.sha256" \
  --pattern agent-guard.rb

(
  cd "$release_dir"
  shasum -a 256 -c "agent-guard-$version.tar.gz.sha256"
)

archive_sha=$(awk '{print $1; exit}' \
  "$release_dir/agent-guard-$version.tar.gz.sha256")
case "$archive_sha" in *[!0-9a-fA-F]*|'')
  printf '%s\n' 'release checksum was not a SHA-256 value' >&2; exit 1 ;;
esac
[ "${#archive_sha}" -eq 64 ] \
  || { printf '%s\n' 'release checksum was not 64 hexadecimal characters' >&2; exit 1; }

./scripts/render-homebrew-formula.sh "$version" "$archive_sha" \
  >"$release_dir/agent-guard.generated.rb"
cmp "$release_dir/agent-guard.generated.rb" "$release_dir/agent-guard.rb"
```

The checksum check verifies the downloaded archive. The `cmp` check proves the
formula that will enter the tap is exactly the formula asset generated for that
same version and checksum. Stop if either check fails.

## Prepare a tap pull request

Homebrew maps `brew tap JeongJaeSoon/tap` to the public
`JeongJaeSoon/homebrew-tap` repository. Clone it locally and make one formula
change:

```sh
tap_dir=$(mktemp -d)
git clone https://github.com/JeongJaeSoon/homebrew-tap.git "$tap_dir"
git -C "$tap_dir" switch -c "release/agent-guard-v$version"
mkdir -p "$tap_dir/Formula"
cp "$release_dir/agent-guard.generated.rb" "$tap_dir/Formula/agent-guard.rb"

git -C "$tap_dir" diff --check
git -C "$tap_dir" diff -- Formula/agent-guard.rb
```

Run the formula checks from that clone. The formula declares its runtime
dependencies and its Homebrew test runs `agent-guard check` plus the local,
deterministic `smoke-test`:

```sh
HOMEBREW_NO_INSTALL_FROM_API=1 brew audit --formula "$tap_dir/Formula/agent-guard.rb"
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --build-from-source \
  "$tap_dir/Formula/agent-guard.rb"
brew test "$tap_dir/Formula/agent-guard.rb"
```

If these checks pass, create a normal pull request using the maintainer's
existing GitHub authentication:

```sh
git -C "$tap_dir" add Formula/agent-guard.rb
git -C "$tap_dir" commit -m "agent-guard $version"
git -C "$tap_dir" push -u origin "release/agent-guard-v$version"
gh pr create --repo JeongJaeSoon/homebrew-tap \
  --title "agent-guard $version" \
  --body "Updates the formula from the published Agent Guard v$version release. The archive SHA-256 and generated formula asset were verified before this pull request."
```

Creating the pull request is a proposal. A tap maintainer must review and
approve its merge as the final publication action. Do not add a release-workflow
token or automated cross-repository push to bypass that approval.
