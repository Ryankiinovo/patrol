#!/bin/bash
# 卸载 Patrol 菜单栏 App（只移除菜单栏，采集器与网页面板不受影响）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.ryankiin.patrol.bar"
UID_="$(id -u)"

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "$ROOT/dist/PatrolBar.app/Contents/MacOS/PatrolBar" 2>/dev/null || true
echo "已卸载菜单栏 App（dist/PatrolBar.app 保留，可随时重装）"
