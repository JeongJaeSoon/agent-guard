# Third-Party Notices

Agent Guard's source and bundled plugin payload are licensed under the MIT
License in [LICENSE](LICENSE).

Agent Guard integrates with, but does not vendor, the following independently
installed software:

- [gitleaks](https://github.com/gitleaks/gitleaks), used for secret detection.
  Agent Guard's approval-gated installer downloads the versioned upstream
  release archive and verifies a user-supplied published SHA-256. gitleaks is
  distributed under its own
  [MIT License](https://github.com/gitleaks/gitleaks/blob/v8.30.1/LICENSE).
- [jq](https://github.com/jqlang/jq), used for JSON processing. Agent Guard does
  not install jq automatically; users obtain it from their operating system or
  another trusted distributor under jq's own license terms.

No gitleaks or jq executable is included in the Agent Guard repository, plugin,
or release archive. Their names and links are provided for attribution and do
not imply endorsement.
