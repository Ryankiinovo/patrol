#!/bin/bash
# Patrol 一键部署（幂等，可反复执行）。
#
#   ./bin/bootstrap.sh            实际安装/修复
#   ./bin/bootstrap.sh --dry-run  只检查并打印将要做的事，不写文件、不加载服务
#
# 它做的事：读 .env → 选 Python 解释器（含 time.monotonic 健康检查）→ 补 smctemp
# → 渲染配置 → 复用 bin/install.sh 装三条 LaunchAgent → 自检。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "未知参数：$1（支持 --dry-run / --help）" >&2; exit 2 ;;
esac

STEP=0
step() { STEP=$((STEP + 1)); printf '\n==> [%d/9] %s\n' "$STEP" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }
die()  { printf '\n[x] %s\n' "$*" >&2; exit 1; }

# ============================================================ 1. 平台
step "检查运行环境"
[ "$(uname -s)" = "Darwin" ] || die "Patrol 只支持 macOS（当前 $(uname -s)）"
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME 未设置或不存在：请在正常登录的用户会话里运行"
REAL_USER="$(id -un)"
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS_VER%%.*}"
info "macOS $MACOS_VER / $(uname -m) / bash $BASH_VERSION / 用户 $REAL_USER (uid $(id -u))"
if [ "$MACOS_MAJOR" -lt 14 ] 2>/dev/null; then
  warn "macOS $MACOS_VER 低于 14.0：菜单栏 App 的 target 是 macosx14.0，可能起不来（采集器与面板仍可用）"
fi
CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || echo '')"
if [ "$CONSOLE_USER" != "$REAL_USER" ]; then
  warn "控制台登录用户是 '${CONSOLE_USER:-未知}'，不是 $REAL_USER"
  warn "LaunchAgent 会装进 gui/$(id -u) 域，纯 SSH 会话下可能加载后不运行；建议在 macOS 桌面终端里执行"
fi

# ============================================================ 2. 配置
step "读取配置"
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
  info "已加载 $ROOT/.env"
else
  info "没有 .env，使用默认值（可 cp .env.example .env 后修改）"
fi
PATROL_PORT="${PATROL_PORT:-8787}"
case "$PATROL_PORT" in
  ''|*[!0-9]*) die "PATROL_PORT 必须是数字，当前是 '$PATROL_PORT'" ;;
esac
if [ "$PATROL_PORT" -lt 1024 ] || [ "$PATROL_PORT" -gt 65535 ]; then
  die "PATROL_PORT 需要在 1024-65535 之间（当前 ${PATROL_PORT}）"
fi
info "PATROL_PORT=$PATROL_PORT"

# ============================================================ 3. Python
step "选择 Python 解释器（需 >= 3.10 且 time.monotonic() 正常）"
# 返回空串表示可用；否则返回原因。
py_problem() {
  _p="$1"
  if [ ! -x "$_p" ]; then printf '不存在或不可执行'; return 0; fi
  if ! "$_p" -c 'pass' >/dev/null 2>&1; then printf '无法运行'; return 0; fi
  if ! "$_p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' >/dev/null 2>&1; then
    printf '版本 %s 低于 3.10' "$("$_p" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
    return 0
  fi
  if ! "$_p" -c 'import sys, time; sys.exit(0 if time.monotonic() > 60 else 1)' >/dev/null 2>&1; then
    printf 'time.monotonic() 返回进程启动时间（Apple 自带 python3.9 的补丁），系统指标会恒为 0'
    return 0
  fi
  if ! "$_p" -c 'import sqlite3, ctypes, json, subprocess, dataclasses' >/dev/null 2>&1; then
    printf '缺少所需标准库模块（sqlite3/ctypes/json）'
    return 0
  fi
  printf ''
}

PY=""
if [ -n "${PATROL_PYTHON:-}" ]; then
  PY="$PATROL_PYTHON"
  _why="$(py_problem "$PY")"
  [ -z "$_why" ] || die "PATROL_PYTHON=$PY 不可用：${_why}。改 .env 里的 PATROL_PYTHON 或留空让脚本自动探测"
  info "使用 .env 指定的解释器：$PY"
else
  BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  CANDIDATES="$(printf '%s\n' \
    /opt/miniconda3/bin/python3.13 \
    "$HOME/miniconda3/bin/python3.13" \
    "$HOME/miniconda3/bin/python3" \
    "$HOME/opt/miniconda3/bin/python3.13" \
    "$BREW_PREFIX/bin/python3.13" \
    /opt/homebrew/bin/python3.13 \
    /usr/local/bin/python3.13 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    "$(command -v python3.13 2>/dev/null || true)" \
    "$(command -v python3 2>/dev/null || true)")"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    _why="$(py_problem "$cand")"
    if [ -z "$_why" ]; then
      PY="$cand"
      break
    fi
    info "跳过 ${cand}：${_why}"
  done <<< "$CANDIDATES"
  [ -n "$PY" ] || {
    printf '\n[x] 找不到可用的 Python 3.10+（且 time.monotonic() 正常）。装一个再重跑：\n\n' >&2
    printf '  # 方式 A（推荐，不需要 sudo）：\n' >&2
    printf '  curl -fsSL -o /tmp/miniconda3.sh "https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-%s.sh"\n' "$(uname -m)" >&2
    printf '  bash /tmp/miniconda3.sh -b -p "$HOME/miniconda3"\n' >&2
    printf '  # 解释器：$HOME/miniconda3/bin/python3.13\n\n' >&2
    printf '  # 方式 B：\n' >&2
    printf '  brew install python@3.13\n\n' >&2
    printf '  装完重跑本脚本（自动探测），或在 .env 里写 PATROL_PYTHON=<绝对路径>。\n' >&2
    exit 1
  }
  info "选中：${PY}（$("$PY" -c 'import platform; print(platform.python_version())')）"
fi
# ============================================================ 4. smctemp
step "检查 smctemp（温度数据源）"
SMCTEMP=""
if command -v smctemp >/dev/null 2>&1; then
  SMCTEMP="$(command -v smctemp)"
elif [ -x /opt/homebrew/bin/smctemp ]; then
  SMCTEMP=/opt/homebrew/bin/smctemp
elif [ -x /usr/local/bin/smctemp ]; then
  SMCTEMP=/usr/local/bin/smctemp
fi
if [ -n "$SMCTEMP" ]; then
  info "已安装：$SMCTEMP"
else
  warn "未找到 smctemp：温度会恒为 0，temp_high 告警不会触发（其余功能正常）"
  if ! command -v brew >/dev/null 2>&1; then
    warn "也没有 Homebrew，无法自动安装。手动执行："
    info "  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    info "  brew tap narugit/tap && brew install smctemp"
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] brew tap narugit/tap && brew install smctemp"
  else
    info "开始安装（brew）..."
    brew tap narugit/tap >/dev/null 2>&1 || true
    if brew install smctemp; then
      info "smctemp 安装完成"
    else
      warn "smctemp 安装失败：可稍后手动执行 brew install narugit/tap/smctemp，温度功能会缺失"
    fi
  fi
fi

# ============================================================ 5. swiftc
step "检查 Swift 工具链（菜单栏 App）"
if command -v swiftc >/dev/null 2>&1; then
  info "swiftc：$(swiftc --version 2>/dev/null | head -n 1)"
  info "SDK：$(xcrun --show-sdk-version 2>/dev/null || echo '?') / target macOS $MACOS_VER"
else
  warn "没有 swiftc：将跳过菜单栏 App（采集器 + 网页面板照常工作）"
  info "需要时执行：xcode-select --install  然后在弹出的窗口点安装"
fi

# ============================================================ 6. 渲染配置
step "渲染配置与目录"
# set_env KEY VALUE：就地更新 .env 里的 KEY（不存在则追加），保留其它行与注释。
set_env() {
  _key="$1"
  _val="$2"
  _file="$ROOT/.env"
  _tmp="$(mktemp "${TMPDIR:-/tmp}/patrol-env.XXXXXX")"
  awk -v k="$_key" -v v="$_val" '
    index($0, k "=") == 1 { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$_file" > "$_tmp"
  mv "$_tmp" "$_file"
}

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] mkdir -p $ROOT/data $ROOT/logs"
  info "[dry-run] 在 .env 写入 PATROL_PYTHON=$PY / PATROL_PORT=$PATROL_PORT"
else
  mkdir -p "$ROOT/data" "$ROOT/logs"
  info "目录就绪：data/ logs/"
  if [ ! -f "$ROOT/.env" ] && [ -f "$ROOT/.env.example" ]; then
    cp "$ROOT/.env.example" "$ROOT/.env"
    info "已从 .env.example 创建 .env"
  fi
  if [ -f "$ROOT/.env" ]; then
    set_env PATROL_PYTHON "$PY"
    set_env PATROL_PORT "$PATROL_PORT"
    info ".env 已更新：PATROL_PYTHON=${PY}，PATROL_PORT=$PATROL_PORT"
  else
    warn "没有 .env 也没有 .env.example，跳过配置回写（install.sh 会用 PATH 里的 python3）"
  fi
fi

# ============================================================ 7. TCC
step "检查项目位置（TCC 磁盘访问）"
case "$ROOT" in
  "$HOME/Documents"/*|"$HOME/Desktop"/*|"$HOME/Downloads"/*)
    warn "项目在受 TCC 保护的目录：$ROOT"
    warn "launchd 拉起的进程默认无权读取这里，可能报 Errno 1 Operation not permitted"
    info "方案 A（推荐）：给解释器完全磁盘访问 —— 系统设置 > 隐私与安全性 > 完全磁盘访问 > + > $PY"
    info "方案 B：把项目移到不受保护的目录，如 \$HOME/opt/Patrol，再重跑本脚本"
    info "方案 C：保持现状（当前机器上该解释器已授权）"
    ;;
  *) info "位置 OK：$ROOT" ;;
esac

# ============================================================ 8. 安装
step "安装 LaunchAgent（复用 bin/install.sh）"
[ -x "$ROOT/bin/install.sh" ] || die "缺少 $ROOT/bin/install.sh（仓库不完整？）"
SHIM_DIR=""
cleanup() {
  if [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ]; then rm -rf "$SHIM_DIR"; fi
}
trap cleanup EXIT

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] mkdir <tmp>; ln -s $PY <tmp>/python3"
  info "[dry-run] PATH=<tmp>:\$PATH PATROL_PORT=$PATROL_PORT $ROOT/bin/install.sh"
else
  SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/patrol-py.XXXXXX")"
  ln -sf "$PY" "$SHIM_DIR/python3"
  info "shim：$SHIM_DIR/python3 -> $PY"
  if ! PATH="$SHIM_DIR:$PATH" PATROL_PORT="$PATROL_PORT" "$ROOT/bin/install.sh"; then
    warn "install.sh 返回非 0，2 秒后重试一次（launchctl 偶发 Input/output error）"
    sleep 2
    PATH="$SHIM_DIR:$PATH" PATROL_PORT="$PATROL_PORT" "$ROOT/bin/install.sh" \
      || die "安装失败。排查：launchctl print gui/$(id -u)/com.patrol.collector  与  $ROOT/logs/*.stderr.log"
  fi
fi

# ============================================================ 9. 自检
step "自检"
if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] $ROOT/bin/verify.sh"
else
  if [ -x "$ROOT/bin/verify.sh" ]; then
    "$ROOT/bin/verify.sh" || true
  else
    warn "没有 bin/verify.sh，跳过自检"
  fi
fi

printf '\n==> 完成\n'
printf '    面板：http://127.0.0.1:%s/\n' "$PATROL_PORT"
printf '    日志：%s/logs/\n' "$ROOT"
printf '    数据：%s/data/patrol.db\n' "$ROOT"
printf '    卸载：%s/bin/uninstall.sh && %s/bin/uninstall-bar.sh\n' "$ROOT" "$ROOT"
printf '    提示：首个系统级采样要 30 秒才落库；若 verify 的「数据新鲜度/系统指标」不是 PASS，等 35 秒后重跑 bin/verify.sh\n'
