#!/bin/bash
# cleanup_pi.sh - 清理树莓派上的会话期调试脚本、日志与临时文件
set -u
echo "=== 1. 删除 ~/lumicube 下所有日志与临时输出 ==="
rm -f /home/illusorywhite/lumicube/*.log /home/illusorywhite/lumicube/*.out /home/illusorywhite/lumicube/nohup.out
echo "  已删除日志类文件"

echo "=== 2. 删除临时文件与调试脚本（本机 tools/ 有全部副本并会整理进仓库） ==="
rm -f /home/illusorywhite/lumicube/redis-test /home/illusorywhite/lumicube/dist-src.tar.gz
cd /home/illusorywhite/lumicube
rm -f *.sh *.py
echo "  ~/lumicube 顶层剩余:"
ls -la /home/illusorywhite/lumicube/ | grep -v '^d' | tail -n +3 || true

echo "=== 3. 清理 daemon-src（源码副本）：删除编译产物、日志、会话 tools ==="
cd /home/illusorywhite/lumicube/daemon-src
rm -rf target
rm -f log-*.log
rm -rf tools
echo "  daemon-src 顶层:"
ls /home/illusorywhite/lumicube/daemon-src/

echo "=== 4. 清理部署目录日志（保留运行数据与软件） ==="
rm -f /home/illusorywhite/AbstractFoundry/Daemon/log-*.log
ls -la /home/illusorywhite/AbstractFoundry/Daemon/

echo "=== 5. 剩余空间报告 ==="
du -sh /home/illusorywhite/lumicube /home/illusorywhite/AbstractFoundry 2>/dev/null
echo "=== 完成 ==="