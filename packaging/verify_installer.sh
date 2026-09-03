#!/bin/bash
# verify_installer2.sh - 验证自解压安装包（对头部文本部分做语法检查）
set -u
OUT=/home/illusorywhite/lumicube-offline-build/install-lumicube-offline.sh
echo "=== 1. 文件信息 ==="
ls -la "$OUT"
echo "=== 2. 标记行位置与内容 ==="
MARK_LINE=$(grep -a -n '^# __PAYLOAD_BELOW__$' "$OUT" | tail -1 | cut -d: -f1)
echo "标记行: $MARK_LINE"
sed -n "$((MARK_LINE-2)),$((MARK_LINE+1))p" "$OUT"
echo "=== 3. 标记行后二进制开头 ==="
tail -n +"$((MARK_LINE+1))" "$OUT" | head -c 2 | od -A x -t x1 | head -1
echo "  期望: 1f 8b (gzip)"
echo "=== 4. 头部文本语法检查（截取标记行之前的部分） ==="
head -n "$((MARK_LINE-1))" "$OUT" > /tmp/installer_header.sh
bash -n /tmp/installer_header.sh && echo "  头部语法 OK" || echo "  头部语法错误!"
echo "=== 5. 确认 exit 0 在标记行之前 ==="
grep -n '^exit 0$' /tmp/installer_header.sh
echo "=== 6. payload 解压冒烟测试（仅列目录） ==="
tail -n +"$((MARK_LINE+1))" "$OUT" | tar -tzf - > /tmp/payload_list.txt 2>/dev/null
echo "  tar 列表行数: $(wc -l < /tmp/payload_list.txt)"
grep -c 'payload/debs/.*\.deb' /tmp/payload_list.txt | xargs echo "  deb 数量:"
grep -c 'payload/wheels/' /tmp/payload_list.txt | xargs echo "  wheels 数量:"
grep 'payload/daemon/' /tmp/payload_list.txt | head -2
echo "=== 7. 安装脚本核心逻辑仍存在 ==="
for key in '离线安装系统依赖' '配置 systemd 开机自启服务' 'loginctl enable-linger' 'systemctl --user enable'; do
  grep -a -q "$key" "$OUT" && echo "  OK: $key" || echo "  MISS: $key"
done
echo "=== 完成 ==="