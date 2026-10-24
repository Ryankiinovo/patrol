#!/bin/bash
# 安装 Patrol 菜单栏 App：第三个 LaunchAgent（登录自启、崩溃自动拉起）。
# 卸载：./bin/uninstall-bar.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.patrol.bar"
# 端口与面板保持一致：在 shell 里 export PATROL_PORT 后重跑本脚本即可。
PORT_ENV=""
if [ -n "${PATROL_PORT:-}" ]; then
  PORT_ENV="    <key>PATROL_PORT</key><string>${PATROL_PORT}</string>"
fi
APP="$ROOT/dist/PatrolBar.app"
UID_="$(id -u)"

"$ROOT/src/menubar/build.sh"

mkdir -p "$ROOT/logs" "$AGENTS"

# 关掉手动 open 起来的实例，避免菜单栏出现两个图标
pkill -f "$APP/Contents/MacOS/PatrolBar" 2>/dev/null || true
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true

# 日志文件必须由 launchd 自己创建：预先 touch 出来的文件带沙箱 provenance 标记，
# launchd 打不开会直接以 EX_CONFIG(78) 退出，进程根本起不来。
cat > "$AGENTS/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/PatrolBar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$ROOT/logs/bar.stdout.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/bar.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
$PORT_ENV
  </dict>
</dict>
</plist>
PLIST

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
  echo "加载失败：$1（可重跑 ./bin/install-bar.sh）" >&2
  return 1
}

wait_job_gone "$LABEL"
sleep 1
bootstrap_job "$LABEL" || true

sleep 2
echo "app:  $APP"
echo "log:  $ROOT/logs/bar.stderr.log"
echo
launchctl list | grep patrol || true
