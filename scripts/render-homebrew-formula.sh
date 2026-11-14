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

  depends_on "git"
  depends_on "gitleaks"
  depends_on "jq"
  depends_on "perl"

  def install
    libexec.install Dir["*"]
    (libexec/".agent-guard-homebrew").write "homebrew\n"
    (bin/"agent-guard").write <<~SH
      #!/bin/sh
      exec "#{libexec}/bin/agent-guard" "\$@"
    SH
  end

  def caveats
    on_macos do
      on_intel do
        <<~EOS
          Intel Mac (x86_64) support ended after Agent Guard v3.8.2.
          Later releases ship no Intel native helper and are not tested on Intel;
          redaction uses the shell/jq fallback.
        EOS
      end
    end
  end

  test do
    assert_match "agent-guard ${version}", shell_output("#{bin}/agent-guard version")
    system bin/"agent-guard", "check"
    system bin/"agent-guard", "smoke-test"
  end
end
EOF
