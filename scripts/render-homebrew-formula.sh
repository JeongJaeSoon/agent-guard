#!/usr/bin/env sh
set -eu

version=${1:?version required}
sha256=${2:?sha256 required}

printf '%s\n' "$version" | awk '!/^[0-9]+\.[0-9]+\.[0-9]+$/ { exit 1 }' \
  || { printf '%s\n' 'version must be X.Y.Z' >&2; exit 2; }
case "$sha256" in
  *[!0-9a-fA-F]*|"") printf '%s\n' 'sha256 must be 64 hex characters' >&2; exit 2 ;;
esac
[ "${#sha256}" -eq 64 ] || { printf '%s\n' 'sha256 must be 64 hex characters' >&2; exit 2; }

cat <<EOF
class AgentGuard < Formula
  desc "Deterministic secret guardrails for AI coding agents"
  homepage "https://github.com/JeongJaeSoon/agent-guard"
  url "https://github.com/JeongJaeSoon/agent-guard/releases/download/v${version}/agent-guard-${version}.tar.gz"
  sha256 "${sha256}"
  license "MIT"

  def install
    libexec.install Dir["*"]
    (bin/"agent-guard").write <<~SH
      #!/bin/sh
      exec "#{libexec}/bin/agent-guard" "\$@"
    SH
  end

  test do
    assert_match "agent-guard ${version}", shell_output("#{bin}/agent-guard version")
  end
end
EOF
