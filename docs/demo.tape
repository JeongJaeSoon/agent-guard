# Agent Guard demo tape — record with:  vhs docs/demo.tape
# Produces docs/demo.gif (embedded in the README hero).
#
# Prerequisites:
#   - vhs:          brew install vhs            (https://github.com/charmbracelet/vhs)
#   - agent-guard:  curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
#
# The demo generates a throwaway private key INTO a .env at record time (in an
# isolated temp dir), then shows the agent's read being blocked and a scan
# flagging the leak. No real secret is stored in this tape or the repo.

Output docs/demo.gif

Require agent-guard

Set Shell "bash"
Set FontSize 20
Set Width 1200
Set Height 720
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 45ms

# Hidden setup: isolated temp dir + a clean prompt
Hide
Type "cd $(mktemp -d) && export PS1='$ ' && clear"
Enter
Show
Sleep 600ms

Type "# A secret (private key) slips into .env — generated live, never stored in this tape"
Sleep 600ms
Enter
Type "ssh-keygen -t rsa -b 2048 -N '' -f .env -q"
Sleep 300ms
Enter
Sleep 1600ms

Type "# 1) The agent asks to read .env — blocked at the tool boundary, before the read"
Sleep 600ms
Enter
Type `echo '{"tool_name":"Read","tool_input":{"file_path":".env"}}' | agent-guard hook-pre-tool`
Sleep 300ms
Enter
Sleep 2200ms

Type "# 2) And if a secret reaches the tree, a scan flags it deterministically"
Sleep 600ms
Enter
Type "agent-guard scan-path .env"
Sleep 300ms
Enter
Sleep 2600ms

Type "# Real-time. No model in the loop. The leak is stopped before it lands."
Sleep 600ms
Enter
Sleep 2600ms
