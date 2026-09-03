# LumiCube Daemon —— 离线安装包制作

本目录包含把 LumiCube daemon 打包成**单文件自解压离线安装器**的工具。

## 产物

运行完整流程后得到 `install-lumicube-offline.sh`（约 400MB），它是**自解压脚本**：

- 头部 = bash 安装逻辑（`install-lumicube-offline.sh` 模板）
- 尾部 = payload.tar.gz（二进制追加在标记行 `# __PAYLOAD_BELOW__` 之后）

在目标树莓派上 `./install-lumicube-offline.sh` 即可完全离线安装。

## 制作流程（三步）

在**联网**的、与目标机同版本（Debian 13 trixie / arm64）的机器上执行：

```bash
export WORK=/tmp/lumicube-offline-build
mkdir -p "$WORK/wheels"

# 1) 收集 .deb 依赖闭包（openjdk/armhf库/ffmpeg/espeak/python包等，约 500 个包）
WORK=$WORK ./collect_debs.sh

# 2) 收集 pip wheels（vosk/pyttsx3/precise-runner/cffi 等）
pip download --dest "$WORK/wheels" \
    vosk pyttsx3 precise-runner cffi pycparser srt websockets \
    --break-system-packages

# 3) 组装单文件安装器（需提供构建好的 Daemon fat JAR）
WORK=$WORK \
DAEMON_JAR=/path/to/target/Daemon-1.9-SNAPSHOT.jar \
./assemble_installer.sh
# 产出: $WORK/install-lumicube-offline.sh
```

> 注意：`pip download` 若在目标 python 版本（3.13 / aarch64）环境执行会得到兼容 wheels；不要打包 PyAudio 源码包（`assemble_installer.sh` 会自动剔除，由系统 `python3-pyaudio` 提供）。

## 校验

```bash
# 干跑：仅验证自解压与 payload 结构，不安装
./dryrun_installer.sh  <installer>          # 或参考其逻辑
# 完整验证（标记行/魔数/头部语法/payload 列表）
./verify_installer.sh  <installer>
```

## 离线安装器内部结构（payload）

```
payload/
├── debs/      # 全部 .deb（含 :armhf 变体 + bullseye libssl1.1）
├── wheels/    # pip wheels（Python 3.13 aarch64）
└── daemon/    # Daemon-1.9-SNAPSHOT.jar（fat jar）
```

安装逻辑（模板 `install-lumicube-offline.sh`）依次完成：解压 → 装 .deb（自动 `dpkg --add-architecture armhf`）→ 装 wheels → 部署到 `~/AbstractFoundry/Daemon` → 配置 systemd 用户服务 + `linger` 开机自启 → 启动验证。
