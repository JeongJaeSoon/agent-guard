# Agent Guard demo tape — record from the repository root, then crop the
# Claude Code header (it shows the plan) off the top:
#
#   vhs docs/demo.tape
#   ffmpeg -y -i /tmp/agent-guard-demo-raw.gif \
#     -vf "crop=iw:ih-135:0:135,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
#     docs/demo.gif
#
# 135 px is the header height at these settings (the row above the first
# prompt). The crop only works while the header stays put, so the terminal is
# tall enough that the take never scrolls. Check that it did not: every frame
# must have the same top band, i.e. this prints a single hash.
#
#   ffmpeg -v error -i /tmp/agent-guard-demo-raw.gif -vf crop=iw:135:0:0 \
#     -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | sort -u
#
# What the take shows, and what it needs on a normal install:
#   1. The agent's Bash `cat .env` is blocked by the PreToolUse hook (plugin only).
#   2. The agent's Read of .env is blocked by the same hook (plugin only).
#   3. The user's own `! cat .env` runs, but its output is masked before it
#      reaches the transcript. This needs the one-time shell integration
#      (`/agent-guard:setup-shell`), which the plugin asks for at session start.
#      Here it is written into a throwaway ZDOTDIR so your own rc is untouched.
#
# Prerequisites:
#   - vhs, ffmpeg, jq, gitleaks:  brew install vhs ffmpeg jq gitleaks
#   - claude: Claude Code CLI logged in under a DEDICATED config dir, so your own
#     settings, status line, plugins and memory stay out of the recording:
#       CLAUDE_CONFIG_DIR="$HOME/.cache/agent-guard-demo/claude-config" claude auth login
#     Point AG_DEMO_CLAUDE_CONFIG_DIR elsewhere to use another dir. On macOS the
#     login token lives in the Keychain, not in that dir, so deleting the dir
#     alone leaves it behind; check which Keychain item it is before removing it.
#
# Each run makes live model calls (haiku, about three), so the agent's wording
# varies between takes; re-record and keep the cleanest one. Check every frame
# before committing: no account, email, plan, organization, home path, cwd,
# status line, usage or cost may appear.
#
# Claude runs under `env -i` so nothing from the launching shell leaks in, with
# IS_DEMO (hides email/organization), CLAUDE_CODE_HIDE_CWD, and nonessential
# traffic off (no startup notices). Only this checkout's plugin is loaded
# (--plugin-dir); the dedicated config dir has no installed plugins, so every
# block on screen comes from the tree. A throwaway private key is generated
# INTO .env at record time in a temp repo, gitignored as most repos have it.
# No real secret is stored in this tape or the repo.

Output /tmp/agent-guard-demo-raw.gif

Require git
Require gitleaks
Require ssh-keygen
Require jq
Require zsh
Require claude

Set Shell "bash"
Set FontSize 18
Set Width 1280
Set Height 1000
Set Padding 28
Set Theme "Dracula"
Set TypingSpeed 40ms

# Hidden setup: temp repo with the key, shell integration in a throwaway
# ZDOTDIR, folder trust pre-accepted so no dialog interrupts the take.
Hide
Type `export AG_PLUGIN="$PWD/plugins/agent-guard" AG_CFG="${AG_DEMO_CLAUDE_CONFIG_DIR:-$HOME/.cache/agent-guard-demo/claude-config}" AG_ZDOT=/tmp/agent-guard-demo-zdot && eval "$("$AG_PLUGIN/bin/agent-guard" shell-init --bash)"`
Enter
Type `rm -rf /tmp/agent-guard-demo "$AG_ZDOT" && mkdir -p /tmp/agent-guard-demo "$AG_ZDOT" && cd /tmp/agent-guard-demo && git init -q && echo .env >.gitignore`
Enter
Type `ssh-keygen -t rsa -b 2048 -N '' -f key -q && printf 'APP_ENV=demo\nDB_HOST=localhost\n' >.env && cat key >>.env && rm key key.pub`
Enter
Type `HOME="$AG_ZDOT" SHELL=/bin/zsh "$AG_PLUGIN/bin/agent-guard" setup-shell --zsh --rc "$AG_ZDOT/.zshrc" >/dev/null`
Enter
Type `c="$AG_CFG/.claude.json" && jq --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted=true' "$c" >"$c.tmp" && mv "$c.tmp" "$c"`
Enter
Type `clear && env -i HOME="$HOME" USER="$USER" PATH="$PATH" TERM="$TERM" LANG=en_US.UTF-8 SHELL=/bin/zsh ZDOTDIR="$AG_ZDOT" CLAUDE_CONFIG_DIR="$AG_CFG" AGENT_GUARD_SHELL_INIT_VERSION="$AGENT_GUARD_SHELL_INIT_VERSION" IS_DEMO=1 CLAUDE_CODE_HIDE_CWD=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude --model haiku --plugin-dir "$AG_PLUGIN" --setting-sources ""`
Enter
Sleep 6s
Show

# 1) The agent's shell read is blocked.
Type "run cat on .env with the Bash tool, then name the key type in one line"
Sleep 400ms
Enter
Sleep 9s

# 2) The agent's Read is blocked too.
Type "try the Read tool instead"
Sleep 400ms
Enter
Sleep 9s

# 3) The user runs it themselves; the key is masked before the transcript.
Type "!"
Sleep 300ms
Type "cat .env"
Sleep 400ms
Enter
Sleep 7s

Hide
Ctrl+C
Ctrl+C
Sleep 1s
Type `cd / && rm -rf /tmp/agent-guard-demo "$AG_ZDOT"`
Enter
