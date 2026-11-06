#!/bin/sh
# 공개 파일 준비는 계측 밖에서 수행한다. 기존 사용자 prefix는 사용하지 않는다.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd -P)
lab=${1:?new laboratory directory}
evidence=${2:?new evidence directory}
image=${3:-agent-guard-public-bench:20261106}
scanner_kind=${4:-official}
host_kind=${5:-claude}
action=${6:-runtime}
case "$lab:$evidence" in /*:/*) ;; *) echo 'absolute paths required' >&2; exit 2 ;; esac
[ ! -e "$lab" ] && [ ! -e "$evidence" ] || { echo 'refusing to overwrite previous evidence' >&2; exit 2; }
mkdir -p "$evidence/provision" "$evidence/runtime"
python3 "$root/bench/results/public-versions-20261106/runtime/prepare-ci.py" --lab "$lab" --evidence "$evidence/provision"
scanners=official
# The hosted runner's fresh Homebrew prefix is independent of the user's host.
brew=/home/linuxbrew/.linuxbrew/bin/brew
if [ "$scanner_kind" = homebrew ] && [ -x "$brew" ]; then
  brew_status=0
  HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install --force-bottle gitleaks > "$evidence/provision/homebrew-install.stdout" 2> "$evidence/provision/homebrew-install.stderr" || brew_status=$?
  printf '%s\n' "$brew_status" > "$evidence/provision/homebrew-install.status"
  if [ "$brew_status" -eq 0 ]; then
    installed="$("$brew" --prefix gitleaks)/bin/gitleaks"
    HOMEBREW_NO_AUTO_UPDATE=1 "$brew" fetch --force-bottle gitleaks > "$evidence/provision/homebrew-fetch.stdout" 2> "$evidence/provision/homebrew-fetch.stderr" || brew_status=$?
    bottle=$("$brew" --cache gitleaks)
    if [ "$brew_status" -eq 0 ] && [ "$("$installed" version)" = 8.30.1 ] && [ -f "$bottle" ]; then
      actual=$(sha256sum "$bottle" | awk '{print $1}')
      if [ "$actual" = 78b43afdf14a05c5df07b73aeaf63ae56b784c905f057411a43ee8fde40fe5d1 ]; then
        mkdir -p "$lab/scanners/homebrew"
        cp "$installed" "$lab/scanners/homebrew/gitleaks"
        cmp "$installed" "$lab/scanners/homebrew/gitleaks"
        sha256sum "$bottle" "$installed" "$lab/scanners/homebrew/gitleaks" > "$evidence/provision/homebrew-checksums.txt"
        "$brew" info --json=v2 gitleaks > "$evidence/provision/homebrew-info.json"
        "$brew" config > "$evidence/provision/homebrew-config.txt"
        cp "$("$brew" --prefix gitleaks)/sbom.spdx.json" "$evidence/provision/homebrew-sbom.json"
        scanners=official,homebrew
      else
        printf 'N/A: pinned Homebrew bottle SHA256 differs: %s\n' "$actual" > "$evidence/provision/homebrew-unavailable.txt"
      fi
    else
      printf 'N/A: Homebrew fetch/version/asset validation failed (status=%s)\n' "$brew_status" > "$evidence/provision/homebrew-unavailable.txt"
    fi
  else
    printf 'N/A: actual Homebrew installation failed (status=%s)\n' "$brew_status" > "$evidence/provision/homebrew-unavailable.txt"
  fi
elif [ "$scanner_kind" = homebrew ]; then
  printf 'N/A: hosted runner has no actual Homebrew prefix\n' > "$evidence/provision/homebrew-unavailable.txt"
fi

docker build --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  -f "$root/bench/results/public-versions-20261106/runtime/Dockerfile" -t "$image" "$root" \
  > "$evidence/provision/image-build.stdout" 2> "$evidence/provision/image-build.stderr"
docker image inspect "$image" > "$evidence/provision/image.json"
docker info > "$evidence/provision/docker-info.txt"
# uid 1000 is used inside the image; this output directory belongs to this CI run.
sudo chown -R 1000:1000 "$lab" "$evidence"
network=none
[ "$action" != installation ] || network=bridge
set -- docker run --rm --init --network="$network" --cpus=2 --memory=1g --memory-swap=1g \
  -v "$lab:/lab:ro" -v "$evidence:/results" -v "$root:/repo:ro"
if [ -d /home/linuxbrew/.linuxbrew ]; then
  set -- "$@" -v /home/linuxbrew/.linuxbrew:/home/linuxbrew/.linuxbrew:ro
fi
# Preserve missing scanner as N/A; never replace it with the official scanner.
if [ "$scanner_kind" = homebrew ] && [ "$scanners" != official,homebrew ]; then
  exit 3
fi
"$@" "$image" sh /repo/bench/results/public-versions-20261106/runtime/inside-ci.sh "$action" "$scanner_kind" "$host_kind"
