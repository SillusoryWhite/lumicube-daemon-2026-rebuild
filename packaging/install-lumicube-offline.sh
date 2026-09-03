#!/bin/bash
# ============================================================================
# LumiCube Daemon - 离线一键安装器（自解压）
# ----------------------------------------------------------------------------
# 用法：
#   chmod +x install-lumicube-offline.sh
#   ./install-lumicube-offline.sh
#
# 功能：
#   1) 自动解压内嵌的 payload（Daemon JAR + 依赖 .deb + pip wheels + 服务文件）
#   2) 离线安装系统依赖（Java、armhf 库、ffmpeg、espeak、python 包等）
#   3) 离线安装 Python wheels（vosk/pyttsx3/precise-runner/cffi 等）
#   4) 部署 Daemon 到 ~/AbstractFoundry/Daemon 官方目录布局
#   5) 配置 systemd 用户级开机自启（含 linger）
#   6) 启动并验证
#
# 环境要求：
#   - 64 位 Raspberry Pi OS（Debian 13 trixie / arm64）
#   - 普通用户运行（内部需要 sudo 时提示）
#   - 无需联网（全部离线）
#
# 环境变量（可选）：
#   DAEMON_DEVICE=/dev/ttyAMA0   串口设备（默认 /dev/ttyAMA0）
# ============================================================================

set -u

# ---------- 自解压逻辑 ----------
# 说明：本脚本的逻辑部分结束于文件末尾的标记行 `# __PAYLOAD_BELOW__`，
# 之后追加的是 payload 的 tar.gz 二进制数据。
PAYLOAD_START=$(grep -a -n '^# __PAYLOAD_BELOW__$' "$0" | tail -1 | cut -d: -f1)
PAYLOAD_START=$((PAYLOAD_START + 1))

say()  { printf '\n\033[1;32m[LumiCube] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; }

# 临时解压目录
EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "$EXTRACT_DIR"' EXIT

say "解压安装包 payload ..."
tail -n +"$PAYLOAD_START" "$0" | tar -xzf - -C "$EXTRACT_DIR"
if [ $? -ne 0 ]; then
  err "payload 解压失败（安装包可能损坏）。"
  exit 1
fi
PAYLOAD="$EXTRACT_DIR/payload"
DEBS_DIR="$PAYLOAD/debs"
WHEELS_DIR="$PAYLOAD/wheels"

# 检查 payload 结构
if [ ! -d "$DEBS_DIR" ] || [ ! -d "$WHEELS_DIR" ]; then
  err "payload 结构不完整（缺少 debs/ 或 wheels/）。"
  exit 1
fi

echo "  payload: $(ls "$PAYLOAD")"
echo "  debs:    $(ls "$DEBS_DIR"/*.deb 2>/dev/null | wc -l) 个"
echo "  wheels:  $(ls "$WHEELS_DIR"/* 2>/dev/null | wc -l) 个"

# ---- 1. 架构检查 ----
ARCH=$(uname -m)
say "架构检查: $ARCH"
case "$ARCH" in
  aarch64|arm64)
    ;;
  *)
    err "仅支持 64 位 ARM (aarch64/arm64)，当前为 $ARCH。"
    exit 1
    ;;
esac

# ---- 2. 离线安装 .deb ----
say "离线安装系统依赖 (.deb) ..."
# 启用 armhf 多架构（内嵌 Redis 是 32 位 ARM 二进制）
sudo dpkg --add-architecture armhf 2>/dev/null
export DEBIAN_FRONTEND=noninteractive
echo "  安装包数量: $(ls "$DEBS_DIR"/*.deb | wc -l)"
# 优先尝试 apt（本地 deb 闭包，可解析依赖顺序）
sudo apt-get install -y --no-download --no-install-recommends "$DEBS_DIR"/*.deb 2>&1 | tail -20
APT_RC=$?
if [ $APT_RC -ne 0 ]; then
  warn "apt 本地安装返回 $APT_RC，回退到 dpkg -i ..."
  sudo dpkg -i "$DEBS_DIR"/*.deb 2>&1 | tail -25
  DPKG_RC=$?
  if [ $DPKG_RC -ne 0 ]; then
    warn "dpkg -i 返回 $DPKG_RC，尝试 --configure -a 修复 ..."
    sudo dpkg --configure -a 2>&1 | tail -10
  fi
fi
# 确认关键组件就绪
echo "  检查: java=$(command -v java >/dev/null && java -version 2>&1 | head -1 || echo MISSING)"
echo "  检查: pactl=$(command -v pactl >/dev/null && echo OK || echo MISSING)"
echo "  检查: ffplay=$(command -v ffplay >/dev/null && echo OK || echo MISSING)"

# ---- 3. 离线安装 pip wheels ----
say "离线安装 Python 依赖 (wheels) ..."
if command -v python3 >/dev/null; then
  python3 -m pip install --no-index --find-links="$WHEELS_DIR" \
    vosk pyttsx3 precise-runner cffi pycparser srt websockets \
    --break-system-packages 2>&1 | tail -15
  PIP_RC=$?
  echo "  pip 安装返回: $PIP_RC"
else
  warn "未找到 python3，跳过 pip 安装（Daemon 的 Python 服务将不可用）。"
fi

# ---- 4. 部署 Daemon ----
say "部署 Daemon 到官方目录布局 ..."
DAEMON_DIR="$HOME/AbstractFoundry/Daemon"
SOFTWARE_DIR="$DAEMON_DIR/Software"
mkdir -p "$SOFTWARE_DIR"
mkdir -p "$DAEMON_DIR/Scripts"

# 拷贝 JAR（若 payload 中存在）
JAR_SRC="$PAYLOAD/daemon/Daemon-1.9-SNAPSHOT.jar"
if [ -f "$JAR_SRC" ]; then
  cp "$JAR_SRC" "$SOFTWARE_DIR/"
  echo "  已部署: $(ls "$SOFTWARE_DIR"/*.jar)"
else
  warn "payload 中未找到 Daemon JAR，跳过拷贝（请手动放置到 $SOFTWARE_DIR/）。"
fi

# 创建 launch.sh
cat > "$DAEMON_DIR/launch.sh" <<EOF
#!/bin/bash
CONTAINING_DIRECTORY="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
exec /usr/bin/java -Xmx1024m -jar "\$CONTAINING_DIRECTORY"/Software/Daemon-1.9-SNAPSHOT.jar "\$@"
EOF
chmod +x "$DAEMON_DIR/launch.sh"
echo "  已创建: $DAEMON_DIR/launch.sh"

# ---- 5. systemd 用户服务 ----
say "配置 systemd 开机自启服务 ..."
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/foundry-daemon.service" <<EOF
[Unit]
Description=Abstract Foundry Daemon
After=network.target pulseaudio.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
ExecStartPre=/bin/sleep 5
ExecStart=%h/AbstractFoundry/Daemon/launch.sh $DAEMON_DEVICE
WorkingDirectory=%h/AbstractFoundry/Daemon
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
EOF
echo "  已创建: ~/.config/systemd/user/foundry-daemon.service"

# 启用 linger（开机无登录时也能启动用户服务）
say "启用 linger（开机自启必要条件）..."
loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" 2>/dev/null | grep -i '^Linger=' || true

# 启动服务
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload
systemctl --user enable foundry-daemon.service 2>&1
systemctl --user start foundry-daemon.service 2>&1
sleep 15

# ---- 6. 验证 ----
say "验证服务状态 ..."
systemctl --user is-active foundry-daemon.service && echo "  -> 服务 active (running)" || warn "  -> 服务未运行！"
systemctl --user is-enabled foundry-daemon.service && echo "  -> 开机自启已启用" || warn "  -> 开机自启未启用"
echo ""
echo "端口监听:"
ss -tlnp 2>/dev/null | grep -E ':(2020|8686|6380)\b' | awk '{print "  " $4}' | sort -u || echo "  (无端口监听)"
echo ""
echo "日志: $(ls -t "$DAEMON_DIR"/log-*.log 2>/dev/null | head -1)"
LOGF=$(ls -t "$DAEMON_DIR"/log-*.log 2>/dev/null | head -1)
[ -n "$LOGF" ] && grep -aE 'Starting daemon|ERROR' "$LOGF" | tail -5

# ---- 7. 串口提示 ----
echo ""
if [ -e "$DAEMON_DEVICE" ]; then
  echo "  串口 $DAEMON_DEVICE: 存在 ✓"
elif [ -e /dev/serial0 ]; then
  warn "未找到 $DAEMON_DEVICE，但存在 /dev/serial0。若 daemon 未识别硬件，可尝试:"
  warn "  systemctl --user edit foundry-daemon.service  # 修改 ExecStart 中的设备路径"
else
  warn "未找到 $DAEMON_DEVICE。请先启用 UART 串口（若需连接 LumiCube 硬件）："
  warn "  sudo raspi-config  -> Interface Options -> Serial Port -> 启用，并关闭串口登录 Shell"
  warn "  或编辑 /boot/config.txt 添加: dtoverlay=miniuart-bt"
fi

echo ""
say "安装完成！"
echo "  服务状态: systemctl --user status foundry-daemon"
echo "  日志:     tail -f $DAEMON_DIR/log-*.log"
echo "  Web 界面: http://<树莓派IP>  (80 -> 8686)"

# 脚本逻辑到此结束，退出；标记行之后的二进制 payload 不会被 bash 解析。
exit 0

# ============================================================================
# 标记行：此标记行之后为 payload（tar.gz 二进制数据）。请勿删除或修改本行。
# __PAYLOAD_BELOW__
