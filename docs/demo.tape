# Agent Guard demo tape — record with:  vhs docs/demo.tape
# Produces docs/demo.gif (to be embedded in the README hero once recorded).
#
# Prerequisites:
#   - vhs:          brew install vhs            (https://github.com/charmbracelet/vhs)
#   - agent-guard:  curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
#
# The demo runs `agent-guard smoke-test`, which exercises every guardrail
# (path scan, .env read block, secret-write block, PII filter, native
# pre-commit block) against throwaway fixtures in temp dirs — so this tape
# contains no real secret literal and is safe to commit.

Output docs/demo.gif

Require agent-guard

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 760
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 45ms

Type "# Agent Guard — deterministic secret-leak guardrails for AI coding agents"
Sleep 700ms
Enter
Sleep 900ms

Type "# One command exercises every guardrail: reads, writes, hooks, commits."
Sleep 700ms
Enter
Sleep 900ms

Type "agent-guard smoke-test"
Sleep 400ms
Enter
Sleep 4500ms

Type "# Deterministic. No model in the loop. Pair with commit/CI scanning for depth."
Sleep 700ms
Enter
Sleep 2500ms
