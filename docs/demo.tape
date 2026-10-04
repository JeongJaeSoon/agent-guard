# Agent Guard demo tape — record from the repository root with:  vhs docs/demo.tape
# Produces docs/demo.gif (embedded in the README hero).
#
# Prerequisites:
#   - vhs:       brew install vhs            (https://github.com/charmbracelet/vhs)
#   - gitleaks:  brew install gitleaks
#
# The tape records this checkout's plugins/agent-guard/bin/agent-guard, so the
# GIF matches the version in the tree. It generates a throwaway private key
# INTO a .env at record time (in an isolated temp repo), then shows the agent's
# read and its commit being blocked. No real secret is stored in this tape or
# the repo.

Output docs/demo.gif

Require git
Require gitleaks
Require ssh-keygen

Set Shell "bash"
Set FontSize 18
Set Width 1280
Set Height 420
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 40ms

# Hidden setup: this checkout's CLI on PATH, an isolated temp repo, a clean prompt
Hide
Type `export PATH="$PWD/plugins/agent-guard/bin:$PATH" && cd "$(mktemp -d)" && git init -q && export PS1='$ ' && clear`
Enter
Show
Sleep 800ms

Type "# A secret (private key) slips into .env — generated live, never stored in this tape"
Sleep 600ms
Enter
Type "ssh-keygen -t rsa -b 2048 -N '' -f .env -q"
Sleep 300ms
Enter
Sleep 1500ms

Enter
Sleep 800ms

Type "# 1) The agent asks to read .env — blocked at the tool boundary, before the read"
Sleep 600ms
Enter
Type `echo '{"tool_name":"Read","tool_input":{"file_path":".env"}}' | agent-guard hook-pre-tool`
Sleep 300ms
Enter
Sleep 2600ms

Enter
Sleep 800ms

Type "# 2) The agent stages it and runs git commit — the commit is blocked before git runs"
Sleep 600ms
Enter
Type "git add .env"
Sleep 300ms
Enter
Sleep 600ms
Type `echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}' | agent-guard hook-pre-tool`
Sleep 300ms
Enter
Sleep 3200ms

Enter
Sleep 800ms

Type "# Real-time. No model in the loop. The leak is stopped before it lands."
Sleep 600ms
Enter
Sleep 2800ms
