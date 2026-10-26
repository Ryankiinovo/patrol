#!/bin/bash
# Patrol 自检：逐项打印 PASS / FAIL，最后给出汇总与退出码。
#
#   ./bin/verify.sh          检查本机部署
#   （退出码 0 = 全部通过；1 = 有 FAIL）
#
# 只读：不装东西、不写 plist、不重启服务。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASSED=0
FAILED=0
SKIPPED=0
pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$*"; }
fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "$1"
  if [ "$#" -ge 2 ] && [ -n "$2" ]; then printf '        -> %s\n' "$2"; fi
}
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP  %s\n' "$*"; }
note() { printf '  note  %s\n' "$*"; }
hdr()  { printf '\n— %s\n' "$*"; }

if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi
PORT="${PATROL_PORT:-8787}"
DB="$ROOT/data/patrol.db"

printf 'Patrol 自检：%s\n' "$ROOT"
printf '时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------- 1 平台
hdr "1. 运行环境"
if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS $(sw_vers -productVersion) / $(uname -m)"
else
  fail "不是 macOS（$(uname -s)）" "Patrol 只支持 macOS"
fi
CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || echo '')"
if [ "$CONSOLE_USER" = "$(id -un)" ]; then
  pass "图形会话属于当前用户（$(id -un)）"
else
  fail "控制台用户是 '${CONSOLE_USER:-未知}'，不是 $(id -un)" "LaunchAgent 装在 gui/$(id -u)，需要在已登录的桌面会话里跑"
fi

# ---------------------------------------------------------------- 2 仓库
hdr "2. 仓库文件"
MISSING=""
for f in monitor/collector.py monitor/system.py web/server.py web/index.html bin/install.sh bin/uninstall.sh; do
  [ -f "$ROOT/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass "必需文件齐全（monitor/ web/ bin/）"
else
  fail "缺文件：$MISSING" "仓库不完整，重新 clone 或检查是否在项目根目录运行"
fi
if [ -f "$ROOT/.env" ]; then
  pass ".env 存在"
else
  note "没有 .env，按默认值检查（PATROL_PORT=${PORT}）"
fi

# ---------------------------------------------------------------- 3 Python
hdr "3. Python 解释器"
PY="${PATROL_PYTHON:-}"
if [ -z "$PY" ]; then
  PY="$(command -v python3.13 2>/dev/null || command -v python3 2>/dev/null || true)"
fi
if [ -z "$PY" ]; then
  fail "PATH 里找不到 python3" "装 Python 3.10+（见 DEPLOY.md），或在 .env 里写 PATROL_PYTHON"
elif [ ! -x "$PY" ]; then
  fail "解释器不可执行：$PY" "改 .env 的 PATROL_PYTHON，或重跑 bin/bootstrap.sh 自动探测"
else
  pass "解释器：$PY"
  PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  [ -n "$PYVER" ] || PYVER="?"
  PYOK="$("$PY" -c 'import sys; print(1 if sys.version_info >= (3,10) else 0)' 2>/dev/null || echo 0)"
  if [ "$PYOK" = "1" ]; then
    pass "版本 $PYVER >= 3.10"
  else
    fail "版本 $PYVER < 3.10" "装 3.13：curl -fsSL -o /tmp/m.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-$(uname -m).sh && bash /tmp/m.sh -b -p \$HOME/miniconda3"
  fi
  if "$PY" -c 'import sys, time; sys.exit(0 if time.monotonic() > 60 else 1)' >/dev/null 2>&1; then
    pass "time.monotonic() 正常（开机以来秒数）"
  else
    fail "time.monotonic() 返回进程启动时间，系统指标会恒为 0" "换成 3.10+ 的解释器（不要用 /usr/bin/python3），然后重跑 bin/bootstrap.sh"
  fi
  if "$PY" -c 'import sqlite3, ctypes, json, subprocess, dataclasses' >/dev/null 2>&1; then
    pass "标准库模块齐备（sqlite3/ctypes/json/subprocess/dataclasses）"
  else
    fail "标准库模块缺失" "用官方 python.org 或 conda 的完整安装，不要用精简版"
  fi
fi

# ---------------------------------------------------------------- 4 外部依赖
hdr "4. 外部依赖"
SMCTEMP=""
if command -v smctemp >/dev/null 2>&1; then SMCTEMP="$(command -v smctemp)"; fi
if [ -z "$SMCTEMP" ] && [ -x /opt/homebrew/bin/smctemp ]; then SMCTEMP=/opt/homebrew/bin/smctemp; fi
if [ -z "$SMCTEMP" ] && [ -x /usr/local/bin/smctemp ]; then SMCTEMP=/usr/local/bin/smctemp; fi
if [ -n "$SMCTEMP" ]; then
  pass "smctemp：$SMCTEMP"
else
  fail "没有 smctemp（温度会恒为 0）" "brew tap narugit/tap && brew install smctemp，然后 launchctl kickstart -k gui/$(id -u)/com.patrol.collector"
fi

# ---------------------------------------------------------------- 5 菜单栏
hdr "5. 菜单栏 App"
BAR="$ROOT/dist/PatrolBar.app"
if [ -d "$BAR" ]; then
  pass "已构建：dist/PatrolBar.app"
  if [ -x "$BAR/Contents/MacOS/PatrolBar" ]; then
    pass "可执行文件存在"
  else
    fail "dist/PatrolBar.app 缺少可执行文件" "src/menubar/build.sh 重新编译"
  fi
else
  fail "没有 dist/PatrolBar.app" "有 swiftc 就执行 bin/install-bar.sh（需要 xcode-select --install），否则忽略此项"
fi
# ---------------------------------------------------------------- 6 LaunchAgent 文件
hdr "6. LaunchAgent 配置"
LA_DIR="$HOME/Library/LaunchAgents"
for label in com.patrol.collector com.patrol.panel com.patrol.bar; do
  plist="$LA_DIR/$label.plist"
  if [ ! -f "$plist" ]; then
    if [ "$label" = "com.patrol.bar" ] && [ ! -d "$ROOT/dist/PatrolBar.app" ]; then
      skip "${label}（未安装菜单栏）"
    else
      fail "缺少 $plist" "运行 ./bin/install.sh（或 ./bin/bootstrap.sh）"
    fi
    continue
  fi
  if plutil -lint "$plist" >/dev/null 2>&1; then
    pass "$label.plist 语法有效"
  else
    fail "$label.plist 语法无效" "plutil -lint '$plist' 看具体错误，然后重跑 ./bin/install.sh"
    continue
  fi
  PLIST_DUMP="$(plutil -p "$plist" 2>/dev/null || true)"
  case "$PLIST_DUMP" in
    *"$ROOT"*) pass "$label.plist 指向当前项目目录" ;;
    *) fail "$label.plist 内没有指向 $ROOT 的路径" "仓库搬过位置？重跑 ./bin/bootstrap.sh 重新渲染" ;;
  esac
  if [ "$label" != "com.patrol.bar" ]; then
    PYPATH="$(plutil -extract ProgramArguments.0 raw "$plist" 2>/dev/null || true)"
    if [ -n "$PYPATH" ] && [ -x "$PYPATH" ]; then
      pass "$label 的解释器可用：$PYPATH"
    else
      fail "$label 的解释器不存在：'${PYPATH:-空}'" "解释器被删/换路径？重跑 ./bin/bootstrap.sh"
    fi
  fi
done

# ---------------------------------------------------------------- 7 加载状态
hdr "7. launchctl 加载状态"
for label in com.patrol.collector com.patrol.panel com.patrol.bar; do
  plist="$LA_DIR/$label.plist"
  if [ ! -f "$plist" ]; then
    skip "${label}（plist 不存在）"
    continue
  fi
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    pass "$label 已加载"
  else
    fail "$label 未加载" "launchctl bootstrap gui/$(id -u) '$plist'（报错就先 bootout 再 bootstrap）"
  fi
done

# ---------------------------------------------------------------- 8 进程
hdr "8. 进程"
COLL_PID="$(pgrep -f "$ROOT/monitor/collector.py" 2>/dev/null | head -n 1 || true)"
if [ -n "$COLL_PID" ]; then
  pass "collector 存活（pid ${COLL_PID}）"
else
  fail "collector 进程不在" "launchctl kickstart -k gui/$(id -u)/com.patrol.collector；再看 logs/collector.stderr.log"
fi
PANEL_PID="$(pgrep -f "$ROOT/web/server.py" 2>/dev/null | head -n 1 || true)"
if [ -n "$PANEL_PID" ]; then
  pass "panel 存活（pid ${PANEL_PID}）"
else
  fail "panel 进程不在" "launchctl kickstart -k gui/$(id -u)/com.patrol.panel；再看 logs/panel.stderr.log"
fi
if [ -d "$ROOT/dist/PatrolBar.app" ]; then
  if pgrep -x PatrolBar >/dev/null 2>&1; then
    pass "菜单栏 PatrolBar 运行中"
  else
    fail "菜单栏 PatrolBar 未运行（非致命）" "open '$ROOT/dist/PatrolBar.app' 手动试；崩溃日志在 Console.app"
  fi
else
  skip "菜单栏未构建"
fi

# ---------------------------------------------------------------- 9 端口与 HTTP
hdr "9. 端口与 HTTP"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  pass "端口 $PORT 正在监听"
else
  fail "端口 $PORT 没有监听" "lsof -nP -iTCP:$PORT 看占用；或改 .env 的 PATROL_PORT 后重跑 bootstrap"
fi
CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
if [ "$CODE" = "200" ]; then
  pass "GET / 返回 200"
else
  fail "GET / 返回 $CODE" "面板没起来或端口不对；看 logs/panel.stderr.log"
fi
API="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/overview" 2>/dev/null || true)"
JSON_PY=/usr/bin/python3
if [ -n "${PY:-}" ] && [ -x "${PY}" ]; then JSON_PY="$PY"; fi
if [ -z "$API" ]; then
  fail "/api/overview 无响应" "先确认端口监听与 panel 进程"
elif printf '%s' "$API" | "$JSON_PY" -c 'import sys, json; json.load(sys.stdin)' >/dev/null 2>&1; then
  pass "/api/overview 返回合法 JSON"
else
  fail "/api/overview 不是合法 JSON" "重启 com.patrol.panel 再看 logs/panel.stderr.log"
fi
# ---------------------------------------------------------------- 10 数据
hdr "10. 数据与采集"
if [ -f "$DB" ]; then
  SIZE="$(wc -c < "$DB" | tr -d ' ')"
  MTIME="$(stat -f %m "$DB" 2>/dev/null || echo 0)"
  if [ -f "$DB-wal" ]; then
    WAL_MTIME="$(stat -f %m "$DB-wal" 2>/dev/null || echo 0)"
    if [ "$WAL_MTIME" -gt "$MTIME" ]; then MTIME="$WAL_MTIME"; fi
  fi
  NOW="$(date +%s)"
  AGE=$((NOW - MTIME))
  pass "数据库存在：data/patrol.db（${SIZE} 字节）"
  if [ "$AGE" -lt 120 ]; then
    pass "最近写入在 ${AGE}s 前（阈值 120s，含 -wal）"
  else
    fail "数据库 ${AGE}s 没有更新（阈值 120s，含 -wal）" "collector 卡住或 TCC 拦截：launchctl kickstart -k gui/$(id -u)/com.patrol.collector 后看 stderr"
  fi
else
  fail "没有 data/patrol.db" "collector 从未成功采样：看 logs/collector.stderr.log，常见是 TCC 或解释器错误"
fi
if [ -n "$API" ]; then
  METRICS="$(printf '%s' "$API" | "$JSON_PY" -c 'import sys,json; d=(json.load(sys.stdin).get("now") or {}); print(int(d.get("mem_used_mb") or 0), float(d.get("temp_c") or 0))' 2>/dev/null || echo '0 0.0')"
  MEM="${METRICS%% *}"
  TEMP="${METRICS##* }"
  if [ "${MEM:-0}" -gt 0 ] 2>/dev/null; then
    pass "内存指标非零：${MEM} MB"
  else
    fail "内存指标为 0：系统级采样没有落库" "多半是解释器 time.monotonic 陷阱（见 DEPLOY.md），换 3.10+ 解释器后重跑 bin/bootstrap.sh"
  fi
  if "$JSON_PY" -c "import sys; sys.exit(0 if float('$TEMP' or 0) > 0 else 1)" 2>/dev/null; then
    pass "温度指标非零：${TEMP} C"
  else
    if [ -n "$SMCTEMP" ]; then
      fail "温度指标为 0（smctemp 已装）" "smctemp -c -i25 -n180 -f 手动试一次；不行就 launchctl kickstart -k gui/$(id -u)/com.patrol.collector"
    else
      note "温度指标为 0：smctemp 未安装（见第 4 节）"
    fi
  fi
fi

# ---------------------------------------------------------------- 11 日志
hdr "11. 日志"
LOG_ISSUE=""
LOG_HISTORY=""
for lg in "$ROOT/logs/collector.stderr.log" "$ROOT/logs/panel.stderr.log"; do
  [ -f "$lg" ] || continue
  HIT=""
  if grep -q "Operation not permitted" "$lg" 2>/dev/null; then
    HIT="Operation not permitted（TCC 拦截）"
  elif grep -q "Traceback" "$lg" 2>/dev/null; then
    HIT="有 Traceback"
  fi
  [ -n "$HIT" ] || continue
  LMOD="$(stat -f %m "$lg" 2>/dev/null || echo 0)"
  LAGE=$(( $(date +%s) - LMOD ))
  if [ "$LAGE" -lt 300 ]; then
    LOG_ISSUE="$(basename "$lg"): $HIT（${LAGE}s 前还在写）"
  else
    LOG_HISTORY="$LOG_HISTORY $(basename "$lg"):$HIT(${LAGE}s 前)"
  fi
done
if [ -z "$LOG_ISSUE" ]; then
  if [ -n "$LOG_HISTORY" ]; then
    pass "stderr 日志近 5 分钟无新错误"
    note "历史错误（进程/HTTP/数据项已证明当前正常）：$LOG_HISTORY"
  else
    pass "stderr 日志无 TCC 拦截 / 崩溃栈"
  fi
else
  fail "$LOG_ISSUE" "TCC：给解释器完全磁盘访问或把项目移出 ~/Documents；崩溃栈：直接看 logs/ 里对应文件"
fi

# ---------------------------------------------------------------- 12 目录权限
hdr "12. 目录可写"
for d in data logs; do
  if [ -d "$ROOT/$d" ]; then
    if TMPW="$(mktemp "$ROOT/$d/.verify.XXXXXX" 2>/dev/null)"; then
      rm -f "$TMPW"
      pass "$d/ 可写"
    else
      fail "$d/ 不可写" "检查权限：ls -ld '$ROOT/$d'；必要时 chown 回当前用户"
    fi
  else
    fail "$d/ 不存在" "mkdir -p '$ROOT/$d' 或重跑 bin/bootstrap.sh"
  fi
done

# ---------------------------------------------------------------- 汇总
printf '\n==================================================\n'
printf '结果：%d PASS / %d FAIL / %d SKIP\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -eq 0 ]; then
  printf '结论：部署正常\n'
  printf '面板：http://127.0.0.1:%s/\n' "$PORT"
  exit 0
else
  printf '结论：有 %d 项失败，按上面的 -> 提示修复后重跑 ./bin/verify.sh\n' "$FAILED"
  exit 1
fi
