#!/bin/bash
# build_noise_arm64.sh - 在树莓派(aarch64)上编译 open-simplex-noise 原生 .so
set -u
set -e
WORK=/home/illusorywhite/lumicube/build-noise
mkdir -p "$WORK"
cd "$WORK"

BASE_URLS=(
  "https://raw.githubusercontent.com/smcameron/open-simplex-noise-in-c/master"
  "https://mirror.ghproxy.com/https://raw.githubusercontent.com/smcameron/open-simplex-noise-in-c/master"
)

echo "=== 1. 确保 .c 和 .h 源码 ==="
for f in open-simplex-noise.c open-simplex-noise.h; do
  if [ ! -s "$f" ]; then
    for u in "${BASE_URLS[@]}"; do
      echo "  下载 $f 从 $u"
      curl -s --noproxy '*' --max-time 30 -o "$f" "$u/$f" && [ -s "$f" ] && break
    done
  fi
  [ -s "$f" ] && echo "  OK: $f ($(wc -l < "$f") 行)" || { echo "  失败: $f"; exit 1; }
done

echo "=== 2. 编译 aarch64 共享库 ==="
gcc -O2 -fPIC -c -o open-simplex-noise.o open-simplex-noise.c
gcc -O2 -shared -o open-simplex-noise-arm64.so open-simplex-noise.o
file open-simplex-noise-arm64.so
ls -la open-simplex-noise-arm64.so

echo "=== 3. 验证可被 Python dlopen ==="
python3 - <<'PY'
from cffi import FFI
import os
ffi = FFI()
lib = ffi.dlopen(os.path.abspath('open-simplex-noise-arm64.so'))
ffi.cdef('''
int open_simplex_noise(int64_t seed, struct osn_context **ctx);
double open_simplex_noise4(const struct osn_context *ctx, double x, double y, double z, double w);
''')
seed = 123456
ctx = ffi.new('struct osn_context **')
assert lib.open_simplex_noise(seed, ctx) == 0
v = lib.open_simplex_noise4(ctx[0], 0.1, 0.2, 0.3, 0.4)
print(f"dlopen OK, noise4 返回值 = {v}")
PY
echo "=== 完成: $(pwd)/open-simplex-noise-arm64.so ==="