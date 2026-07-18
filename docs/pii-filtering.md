# PII filtering

PII filtering is separate from Agent Guard's gitleaks-based secret scanning. The CLI can mask text before it reaches another tool; agent hooks can optionally block tool inputs but cannot rewrite them.

## CLI masking

`pii-filter` reads stdin and writes the masked text to stdout:

```sh
printf '%s\n' 'Contact jane@example.com at 203.0.113.42' \
  | agent-guard pii-filter
```

Output:

```text
Contact [PII:EMAIL] at [PII:IP_ADDRESS]
```

Select a provider with `AGENT_GUARD_PII_PROVIDER`. Only these values are supported:

| Provider | Behavior | Requirements |
|---|---|---|
| `regex` | Local deterministic masking; the default. | `awk` |
| `http` | Sends text to a compatible redaction endpoint. | `curl`, `jq`, and `AGENT_GUARD_PII_REDACT_URL` |

Any other provider value exits with status 2.

Validate the selected provider before use:

```sh
agent-guard pii-filter --check
```

## Regex provider

The built-in provider masks common email addresses, phone numbers, credit-card-shaped numbers, US SSNs, and IPv4 addresses. It leaves unmatched text unchanged and makes no network requests.

This is format matching, not general-purpose de-identification. Expect false positives and false negatives for ambiguous or locale-specific values.

## HTTP provider

Configure a compatible endpoint:

```sh
AGENT_GUARD_PII_PROVIDER=http \
AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
agent-guard pii-filter --check

printf '%s\n' 'Customer jane@example.com' \
  | AGENT_GUARD_PII_PROVIDER=http \
    AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:8080/api/redact \
    agent-guard pii-filter
```

Agent Guard sends:

```json
{"text":"Customer jane@example.com\n"}
```

The response must be JSON with a string at one of these paths:

- `redacted_text`
- `anonymized_text`
- `text`
- `data.redacted_text`

Missing dependencies, a missing URL, HTTP errors, invalid JSON, and unsupported response shapes fail closed. `--check` verifies reachability and response shape with harmless sample text; it cannot prove the endpoint's redaction quality.

The HTTP provider sends its input to the configured service. Use an endpoint whose privacy and retention policy you accept.

## Agent hook blocking

PII enforcement in agent hooks is off by default. Enable blocking in the hook process environment:

```sh
AGENT_GUARD_PII_HOOK_MODE=block
```

Block mode checks proposed `Write`, `Edit`, `MultiEdit`, `apply_patch`, `Bash`, `WebFetch`, `WebSearch`, and MCP inputs with the selected provider. If PII is detected, the tool call is rejected with guidance to run `agent-guard pii-filter` first.

`AGENT_GUARD_PII_HOOK_MODE=mask` is not supported because hooks cannot safely rewrite pending tool payloads. If the HTTP provider is selected, hook checks also send inspected tool input to that endpoint.
