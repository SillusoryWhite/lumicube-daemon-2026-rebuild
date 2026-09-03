#!/bin/bash
# collect_debs.sh - 收集离线安装所需的 .deb 依赖闭包
#
# 用法：
#   WORK=<工作目录> ./collect_debs.sh
#   默认 WORK=/tmp/lumicube-offline-build
#
# 策略：
#   1) 用 apt-cache depends --recurse 生成所需包的完整依赖闭包
#   2) 排除 "任何 Debian 系统都保证存在" 的核心包（Priority: required / Essential: yes）
#      这些包目标机基础系统必有，不需要打包
#   3) 其余包全部下载（含 :armhf 变体——目标机默认没有 armhf 库）
#
# 说明：需在联网的、与目标机同版本（Debian 13 trixie / arm64）的机器上运行。
set -u
export DEBIAN_FRONTEND=noninteractive
WORK="${WORK:-/tmp/lumicube-offline-build}"
mkdir -p "$WORK/debs" "$WORK/tmp-v2"
rm -f "$WORK/debs"/*.deb "$WORK/tmp-v2"/*.deb

PACKAGES="openjdk-21-jre-headless libc6:armhf libatomic1:armhf libgcc-s1:armhf libstdc++6:armhf espeak espeak-ng libespeak1 ffmpeg pulseaudio-utils pipewire-pulse python3-flask python3-waitress python3-pil python3-numpy python3-psutil python3-alsaaudio python3-pyaudio libportaudio2 python3-pip"

echo "=== 1. 生成完整依赖闭包 ==="
CLOSURE=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $PACKAGES 2>/dev/null | grep -E '^[a-zA-Z0-9]' | tr -d ' ' | sort -u)
echo "闭包总数: $(echo "$CLOSURE" | wc -l)"

echo "=== 2. 排除核心基础包（Priority required / Essential） ==="
TO_DOWNLOAD=""
SKIPPED=""
for p in $CLOSURE; do
  pkg="${p%%:*}"; arch="${p##*:}"
  [ "$arch" = "$pkg" ] && arch=""
  if [ -z "$arch" ]; then
    meta=$(apt-cache show "$pkg" 2>/dev/null | grep -aE '^(Priority|Essential):' | tr '\n' ';')
  else
    meta=$(apt-cache show "$pkg:$arch" 2>/dev/null | grep -aE '^(Priority|Essential):' | tr '\n' ';')
  fi
  prio=$(echo "$meta" | grep -o 'Priority: [a-z]*' | head -1 | cut -d' ' -f2)
  ess=$(echo "$meta" | grep -o 'Essential: yes' | head -1)
  if [ -z "$arch" ] && { [ "$prio" = "required" ] || [ -n "$ess" ]; }; then
    SKIPPED="$SKIPPED $p"
    continue
  fi
  TO_DOWNLOAD="$TO_DOWNLOAD $p"
done
echo "需要打包: $(echo $TO_DOWNLOAD | wc -w)"
echo "跳过核心基础包: $(echo $SKIPPED | wc -w)"

echo "=== 3. 下载 ==="
cd "$WORK/tmp-v2"
if [ -n "$TO_DOWNLOAD" ]; then
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY apt-get download $TO_DOWNLOAD 2>&1 | tail -10
fi

echo "=== 4. 补充 bullseye libssl1.1:armhf（trixie 源中没有） ==="
if [ ! -f libssl1.1_1.1.1w-0+deb11u1_armhf.deb ]; then
  curl -s --noproxy '*' --max-time 90 -o libssl1.1_1.1.1w-0+deb11u1_armhf.deb \
    "https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_armhf.deb" || echo "libssl1.1 下载失败"
fi

echo "=== 5. 复制到 debs ==="
cp *.deb "$WORK/debs/" 2>/dev/null
echo "最终 debs: $(ls "$WORK/debs"/*.deb | wc -l) 个, 大小 $(du -sh "$WORK/debs" | cut -f1)"
echo "=== 完成 ==="