#!/bin/bash
# 停止并移除 Patrol 的两个 LaunchAgent；数据目录保留。
set -uo pipefail

AGENTS="$HOME/Library/LaunchAgents"
UID_="$(id -u)"
for label in com.ryankiin.patrol.collector com.ryankiin.patrol.panel; do
  launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
  echo "removed $label"
done
echo "数据仍在 data/，需要彻底清除请手动删除项目目录。"
