#!/bin/bash
# 安装 Patrol：两个 LaunchAgent（采集器 + 面板），登录自启、崩溃自动拉起。
# 卸载：./bin/uninstall.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
PY="$(command -v python3 || true)"

if [ -z "$PY" ]; then
  echo "找不到 python3" >&2; exit 1
fi
PY="$(readlink -f "$PY" 2>/dev/null || echo "$PY")"

mkdir -p "$ROOT/data" "$ROOT/logs" "$AGENTS"

write_plist () {
  local label="$1" target="$2" stdout="$3"
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$ROOT/$target</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$ROOT/logs/$stdout.stdout.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/$stdout.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
}

UID_="$(id -u)"

for label in com.ryankiin.patrol.collector com.ryankiin.patrol.panel; do
  launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
done

write_plist "com.ryankiin.patrol.collector" "monitor/collector.py" "collector"
write_plist "com.ryankiin.patrol.panel" "web/server.py" "panel"

# 日志文件必须由 launchd 自己创建：预先 touch 出来的文件带沙箱 provenance 标记，
# launchd 打不开会直接以 EX_CONFIG(78) 退出，进程根本起不来。
wait_job_gone () {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    launchctl print "gui/$UID_/$1" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
}

bootstrap_job () {
  for _ in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_" "$AGENTS/$1.plist" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "加载失败：$1（可重跑 ./bin/install.sh）" >&2
  return 1
}

for label in com.ryankiin.patrol.collector com.ryankiin.patrol.panel; do
  wait_job_gone "$label"
done
sleep 1

for label in com.ryankiin.patrol.collector com.ryankiin.patrol.panel; do
  bootstrap_job "$label" || true
done

sleep 2
echo "python:  $PY"
echo "db:      $ROOT/data/patrol.db"
echo "panel:   http://127.0.0.1:8787/"
echo
launchctl list | grep patrol || true

# 菜单栏 App 单独编译安装；没有 swiftc 时跳过，不影响采集器与面板
if [ -x "$ROOT/bin/install-bar.sh" ] && command -v swiftc >/dev/null 2>&1; then
  echo
  echo "── 菜单栏 App ──"
  "$ROOT/bin/install-bar.sh" || echo "菜单栏安装失败，可单独运行 ./bin/install-bar.sh 重试"
fi
