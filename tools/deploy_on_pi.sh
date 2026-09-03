#!/bin/bash
# ============================================================================
# LumiCube Daemon - Raspberry Pi 部署 & 验证脚本
# ----------------------------------------------------------------------------
# 功能：
#   1) env-check   : 环境核查（串口 / Python3 / PulseAudio / 端口 / 架构）
#   2) install     : 使用本仓库 packaging/install-lumicube-offline.sh 离线安装
#   3) start       : 启停服务 / 前台调试启动
#   4) verify      : 端口、套接字、Redis、Web、日志的存活检查
#   5) deploy      : 一键 = install + start + verify
#
# 用法：
#   ./deploy_on_pi.sh env-check
#   ./deploy_on_pi.sh install       # 离线安装（需先放置 install-lumicube-offline.sh）
#   ./deploy_on_pi.sh start         # systemctl --user start
#   ./deploy_on_pi.sh verify
#   ./deploy_on_pi.sh deploy        # 完整一键
#
# 注意：官方 install.py（www.abstractfoundry.com）已下线不可用，安装请走离线安装包。
# ============================================================================

set -u

DAEMON_PORT=2020
WEB_PORT=8686
REDIS_PORT=6380
DEVICE=/dev/ttyAMA0
SERVICE=foundry-daemon.service
INSTALLER="${INSTALLER:-install-lumicube-offline.sh}"   # 离线安装器（本仓库 packaging/ 生成）

cmd="${1:-help}"

say()  { printf '\n\033[1;32m[LumiCube] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[LumiCube ERROR] %s\033[0m\n' "$*" >&2; }
pass() { printf '\033[1;36m[ OK ]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }

# ----------------------------------------------------------------------------
env_check() {
  say "环境核查"

  echo "架构: $(uname -m)"
  if uname -m | grep -qi arm; then pass "ARM 架构 (匹配内嵌 arm 二进制)"; else fail "非 ARM 架构 → LumiCube 仅官方支持树莓派"; fi

  if [ -e "$DEVICE" ]; then
    pass "串口 $DEVICE 存在"
    ls -l "$DEVICE"
  else
    fail "串口 $DEVICE 缺失。请启用 UART：sudo raspi-config 或 /boot/config.txt 加 dtoverlay=miniuart-bt"
  fi

  if command -v python3 >/dev/null; then
    pass "python3: $(python3 --version)"
  else
    err "缺少 python3 (daemon 硬依赖 /usr/bin/python3)"; exit 1
  fi

  if command -v pactl >/dev/null && command -v pacat >/dev/null && pactl info >/dev/null 2>&1; then
    pass "PulseAudio 可用"
  else
    err "缺少 PulseAudio (VirtualMicrophone 硬依赖)。安装: sudo apt install -y pulseaudio"; exit 1
  fi

  echo "检查端口占用:"
  for p in $DAEMON_PORT $WEB_PORT $REDIS_PORT; do
    if ss -tlnp 2>/dev/null | grep -q ":$p "; then
      fail "端口 $p 已占用"
    else
      pass "端口 $p 空闲"
    fi
  done
}

# ----------------------------------------------------------------------------
install() {
  say "通过离线安装器安装: $INSTALLER"
  if [ ! -f "$INSTALLER" ]; then
    err "未找到 $INSTALLER。请先从本仓库 packaging/ 构建离线安装器并放到当前目录，或直接运行它："
    err "  chmod +x install-lumicube-offline.sh && ./install-lumicube-offline.sh"
    exit 1
  fi
  chmod +x "$INSTALLER"
  bash -c "./$INSTALLER"
}

# ----------------------------------------------------------------------------
start() {
  say "启动服务: $SERVICE"
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE"
  sleep 3
  systemctl --user status "$SERVICE" --no-pager || true
}

stop() {
  say "停止服务: $SERVICE"
  systemctl --user stop "$SERVICE"
}

run-foreground() {
  say "前台调试启动 (Ctrl+C 退出)"
  systemctl --user stop "$SERVICE" 2>/dev/null
  exec "$HOME/AbstractFoundry/Daemon/launch.sh" "$DEVICE"
}

# ----------------------------------------------------------------------------
verify() {
  say "存活验证"
  local ok=0

  systemctl --user is-active "$SERVICE" >/dev/null 2>&1 \
    && { pass "systemd 服务: active"; ok=$((ok+1)); } \
    || { fail "systemd 服务未运行 (可能正在随后台方式用 launch.sh 启动)"; }

  ss -tlnp 2>/dev/null | grep -q ":$DAEMON_PORT " \
    && { pass "TCP $DAEMON_PORT 监听"; ok=$((ok+1)); } \
    || fail "TCP $DAEMON_PORT 未监听"
  ss -tlnp 2>/dev/null | grep -q ":$WEB_PORT " \
    && { pass "Web $WEB_PORT 监听"; ok=$((ok+1)); } \
    || fail "Web $WEB_PORT 未监听"
  ss -tlnp 2>/dev/null | grep -q ":$REDIS_PORT " \
    && { pass "内嵌 Redis $REDIS_PORT 监听"; ok=$((ok+1)); } \
    || fail "内嵌 Redis $REDIS_PORT 未监听"
  [ -S /tmp/foundry_python_service.sock ] \
    && { pass "Python 套接字存在"; ok=$((ok+1)); } \
    || fail "Python 套接字缺失 (Python 服务可能未起)"

  local ip; ip=$(hostname -I | awk '{print $1}')
  pass "Web 界面: http://$ip  (80 转发 → 8686)"

  say "最近日志 (session/用户级):"
  journalctl --user -u "$SERVICE" -n 30 --no-pager 2>/dev/null || tail -n 30 "$HOME/AbstractFoundry/Daemon/Daemon.log" 2>/dev/null || true

  echo
  echo "通过项: $ok / 5"
}

# ----------------------------------------------------------------------------
deploy() {
  if [ "$(id -u)" = "0" ]; then
    err "deploy 需以普通用户运行 (install 内部会用 sudo)。请用非 root 用户执行。"
    exit 1
  fi
  env_check
  install
  start
  verify
}

# ----------------------------------------------------------------------------
help() {
  sed -n '2,40p' "$0"
}

case "$cmd" in
  env-check)    env_check ;;
  install)      install ;;
  start)        start ;;
  stop)         stop ;;
  run-foreground) run-foreground ;;
  verify)       verify ;;
  deploy)       deploy ;;
  *)            help ;;
esac