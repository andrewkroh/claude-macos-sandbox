#!/bin/bash
# statusline.sh — Claude Code status line showing firewall and privilege status.
# Receives JSON session data on stdin from Claude Code.

input=$(cat)
MODEL=$(echo "$input" | jq -r '.model.display_name // empty')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

if [[ -f /run/claude-firewall.lock ]]; then
    FW="\033[32mFW:ON\033[0m"
else
    FW="\033[31mFW:OFF\033[0m"
fi

# Check no_new_privs on parent process (claude) or self
if grep -q "NoNewPrivs:[[:space:]]*1" /proc/$PPID/status 2>/dev/null || \
   grep -q "NoNewPrivs:[[:space:]]*1" /proc/self/status 2>/dev/null; then
    PRIVS="\033[32mNNP\033[0m"
else
    PRIVS="\033[33mNNP:OFF\033[0m"
fi

echo -e "[$MODEL] ${PCT}% | $FW | $PRIVS"
