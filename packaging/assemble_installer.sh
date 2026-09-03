#!/bin/bash
# assemble_installer.sh - 组装单文件自解压离线安装包
#
# 用法：
#   WORK=<工作目录> \
#   DAEMON_JAR=<路径>/Daemon-1.9-SNAPSHOT.jar \
#   INSTALLER_HEADER=<路径>/install-lumicube-offline.sh \
#   ./assemble_installer.sh
#
# 前置条件（均在 WORK 目录下）：
#   debs/    —— 由 collect_debs.sh 生成
#   wheels/  —— pip download 收集的 Python 包
# 输出：
#   WORK/install-lumicube-offline.sh —— 最终单文件安装器（可拷贝到目标机）
set -u
set -e
WORK="${WORK:-/tmp/lumicube-offline-build}"
DAEMON_JAR="${DAEMON_JAR:-/home/illusorywhite/AbstractFoundry/Daemon/Software/Daemon-1.9-SNAPSHOT.jar}"
INSTALLER_HEADER="${INSTALLER_HEADER:-$(cd "$(dirname "$0")" && pwd)/install-lumicube-offline.sh}"
OUT="$WORK/install-lumicube-offline.sh"
PAYLOAD_DIR="$WORK/payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR/debs" "$PAYLOAD_DIR/wheels" "$PAYLOAD_DIR/daemon"

echo "=== 1. 拷贝 debs ==="
cp "$WORK/debs"/*.deb "$PAYLOAD_DIR/debs/"
echo "  debs: $(ls "$PAYLOAD_DIR/debs" | wc -l) 个"

echo "=== 2. 拷贝 wheels（剔除 PyAudio 源码包，离线编译必败） ==="
rm -f "$WORK/wheels"/PyAudio-*.tar.gz
cp "$WORK/wheels"/* "$PAYLOAD_DIR/wheels/"
echo "  wheels: $(ls "$PAYLOAD_DIR/wheels" | wc -l) 个"

echo "=== 3. 拷贝 Daemon JAR ==="
cp "$DAEMON_JAR" "$PAYLOAD_DIR/daemon/"
ls -la "$PAYLOAD_DIR/daemon/"

echo "=== 4. 打包 payload.tar.gz ==="
cd "$WORK"
tar -czf payload.tar.gz payload
echo "  payload.tar.gz: $(du -h payload.tar.gz | cut -f1)"

echo "=== 5. 组装自解压安装脚本 ==="
cp "$INSTALLER_HEADER" "$OUT"
chmod +x "$OUT"
MARK_COUNT=$(grep -a -c '^# __PAYLOAD_BELOW__$' "$OUT" || true)
echo "  标记行数量: $MARK_COUNT (应为 1)"
cat "$WORK/payload.tar.gz" >> "$OUT"
echo "  最终文件: $OUT ($(du -h "$OUT" | cut -f1))"

echo "=== 6. 验证（对头部文本部分做语法检查） ==="
MARK_LINE=$(grep -a -n '^# __PAYLOAD_BELOW__$' "$OUT" | tail -1 | cut -d: -f1)
head -n "$((MARK_LINE-1))" "$OUT" > /tmp/installer_header.sh
bash -n /tmp/installer_header.sh && echo "  头部语法 OK"
rm -f /tmp/installer_header.sh
echo "=== 完成 ==="