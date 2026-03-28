#!/bin/bash
# Auto-sync Obsidian vault to GitHub
cd /Users/maros/Zahrada || exit 1

# Pull latest changes first
git pull --rebase --autostash origin main 2>/dev/null

# Check if there are any changes
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "vault backup: $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin main
fi
