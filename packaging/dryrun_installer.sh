#!/bin/bash
# dryrun_installer.sh - 干跑测试：只验证自解压提取，不安装任何东西
set -u
OUT=/home/illusorywhite/lumicube-offline-build/install-lumicube-offline.sh

echo "=== 模拟安装器的自解压逻辑（只提取） ==="
MARK_LINE=$(grep -a -n '^# __PAYLOAD_BELOW__$' "$OUT" | tail -1 | cut -d: -f1)
PAYLOAD_START=$((MARK_LINE + 1))
EXTRACT_DIR=$(mktemp -d)
tail -n +"$PAYLOAD_START" "$OUT" | tar -xzf - -C "$EXTRACT_DIR"
RC=$?
echo "解压退出码: $RC (0=成功)"

PAYLOAD="$EXTRACT_DIR/payload"
echo ""
echo "=== payload 结构 ==="
ls "$PAYLOAD"
echo ""
echo "debs: $(ls "$PAYLOAD/debs"/*.deb 2>/dev/null | wc -l) 个"
echo "wheels: $(ls "$PAYLOAD/wheels"/* 2>/dev/null | wc -l) 个"
echo "JAR: $(ls -la "$PAYLOAD/daemon/"*.jar 2>/dev/null | awk '{print $5"  "$NF}')"

echo ""
echo "=== 关键 deb 存在性 ==="
for p in openjdk-21-jre-headless libc6_armhf libssl1.1 ffmpeg espeak python3-waitress python3-pyaudio pipewire-pulse; do
  found=$(ls "$PAYLOAD/debs/" | grep "$p" | head -1)
  [ -n "$found" ] && echo "  OK: $found" || echo "  MISS: $p"
done

echo ""
echo "=== 模拟安装脚本实际执行的第一个命令（检查架构分支） ==="
echo "  当前架构: $(uname -m)"
case "$(uname -m)" in
  aarch64|arm64) echo "  -> 通过" ;;
  *) echo "  -> 不通过（非 arm64）" ;;
esac
rm -rf "$EXTRACT_DIR"
echo "=== 干跑完成（未安装任何东西） ==="