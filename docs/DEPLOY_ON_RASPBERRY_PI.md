# LumiCube Daemon – 树莓派部署与验证指南

本文档基于对 `lumicube-daemon` 源码的静态审查，描述如何在 **Raspberry Pi（Linux/ARM）** 上部署、运行并验证这个守护进程是否正常工作。

> 适用范围：你想在自己的树莓派（Pi 4 / Pi 3B+ 等）上跑通这个控制服务，并确认它能启动、监听端口、与硬件通信。

---

## 1. 它运行所需的平台与外部依赖（静态审查结论）

`Daemon.java` 在启动时按顺序拉起这些子系统，每项都有明确的平台耦合，**缺一不可**：

| 子系统 | 依赖的外部程序/设备 | 说明 |
|---|---|---|
| Redis（内嵌） | 打包进 JAR 的 `redis-server` + `redistimeseries.so`（`src/main/resources/META-INF/resources/redis/{arm,x64}/`） | 由 `RedisLauncher.start()` 解压到临时目录并自动启动，端口 `6380`。**Linux 专用二进制**，且需要 `libssl` 动态库。 |
| 串口/UAVCAN 节点 | 串口设备，默认 `/dev/ttyAMA0` | `jSerialComm`（`com.fazecast`）打开串口，波特率 **3,000,000**。没有硬件会抛异常/找不到端口。 |
| Python 服务 | `/usr/bin/python3` | `GlobalPythonService.start()` 用 `/usr/bin/python3` 启动 `service.py`，通过 Unix 域套接字 `/tmp/foundry_python_service.sock` 通信。 |
| 脚本执行器 | `/usr/bin/python3` + `foundry_api` + `noise/open-simplex-noise-*.so` | 用户脚本在此运行，JNI `.so` 也是 ARM 专用。 |
| Web / REST / WebSocket | 内嵌 Jetty + Jersey | 端口 `8686`；静态资源（前端 UI）打包在 JAR 的 `/META-INF/resources/static/`。 |
| TCP / 域套接字 | — | TCP 端口 `2020`；Unix 域套接字 `/tmp/foundry_daemon.sock`（Linux 专用）。 |
| 音频 | `/usr/bin/pacat`, `/usr/bin/pactl`（PulseAudio） | `VirtualMicrophone` 在**构造时**就会加载 PulseAudio 模块。若系统无 PulseAudio，启动会抛 `IllegalStateException`。`SpeakerThread` 驱动音箱。 |

**⚠️ 关键结论（能否正常运行的判断依据）：**

1. **它不能在 Windows / macOS 上运行。** 硬编码了 Linux 路径（`/tmp/...`）、Unix 域套接字、Linux 专用二进制与 JNI `.so`。
2. **即使没有连接真实 LumiCube 硬件，串口创建仍可能失败**（`SerialPort.getCommPorts()` 若无串口直接抛 `RuntimeException`）。这是“yields normally”的最小边界之一。
3. **音频部分是硬依赖**：构造函数中 `new VirtualMicrophone()` 会立刻操作 PulseAudio，若环境没有 PulseAudio，整个 daemon 无法构造。
4. 树莓派上**必须启用 UART 串口**（`/dev/ttyAMA0` 存在且可写），并关闭串口登录 Shell。

---

## 2. 推荐部署方式

> ⚠️ **官方下载站 `www.abstractfoundry.com` 已下线**（2026 年起无法访问），官方 `install.py`（下载预编译 AppImage）**已不可用**。请使用以下两种方式之一。

### 方式一：离线安装包（推荐，无需联网）

使用本仓库 `packaging/` 制作好的单文件自解压安装器（含全部依赖闭包 + Daemon JAR + systemd 服务配置）：

```bash
# 拷贝安装器到树莓派后执行（需普通用户 + sudo 权限）
chmod +x install-lumicube-offline.sh
./install-lumicube-offline.sh
```

自动完成：装依赖（.deb + wheels）→ 部署到 `~/AbstractFoundry/Daemon` → 配置 systemd 开机自启（含 linger）→ 启动验证。详见第 9 节。

> 注意：安装器末尾会启动服务并验证；若目标机未启用串口会给出提示。执行前请先连接硬件（或至少保证串口存在）。

### 方式二：源码构建 + systemd（联网构建，离线运行）

见第 3 节构建方式；构建产物（fat JAR）可离线部署，部署步骤见第 8 节。

---

## 3. 源码自行构建方式（可选，不推荐普通部署使用）

在树莓派（或任意 Linux）上用 Maven 构建：

```bash
sudo apt update
sudo apt install -y openjdk-21-jdk-headless maven
mvn package                      # 生成 target/Daemon-*.jar 与 zip
```

> 项目 `pom.xml` 目标是 **JDK 16**（`maven.compiler.source/target=16`），用 **JDK 21** 构建已验证通过（也可用 JDK 17+）。构建产物为 fat JAR；AppImage 打包（`build.sh` + Docker）在本仓库不作为主要交付方式。
> 构建不产生 ARM 专用 AppImage（那是 `build.sh` + Docker 的职责）；直接构建得到的 JAR 仍依赖外部的 `python3`、PulseAudio 和系统库。

从源码直接运行（需先满足全部外部依赖）：

```bash
java -cp "target/Daemon-1.9-SNAPSHOT-jar-with-dependencies.jar" com.abstractfoundry.daemon.Daemon /dev/ttyAMA0
```

---

## 4. 启动前的环境核查清单（不动手排查）

在树莓派 shell 中逐项确认，满足后才能进入“正常启动”：

```bash
# 1) 架构识别（应为 arm，用于选择正确的内嵌二进制）
uname -m

# 2) 串口设备是否启用（存在 /dev/ttyAMA0 且可写）
ls -l /dev/ttyAMA0
# 若未启用：编辑 /boot/config.txt 加 dtoverlay=miniuart-bt，并启用 UART、关闭串口登录 shell

# 3) Redis 依赖的系统库（内嵌 redis-server 需要 libssl）
ldd ~/AbstractFoundry/Daemon/Software/*.AppImage 2>/dev/null || echo "AppImage 未安装"
# AppImage 里应为 linux-arm 提供所需库；若临时目录解压的 redis-server 报缺库，装 libssl

# 4) Python3 存在
command -v python3 && python3 --version

# 5) PulseAudio 存在（VirtualMicrophone 硬依赖）
command -v pactl && command -v pacat && pactl info >/dev/null && echo "PulseAudio OK"
# 若无：sudo apt install -y pulseaudio

# 6) 端口可用（2020 / 8686 / 6380 未被占用）
ss -tlnp | grep -E ':(2020|8686|6380)\b' || echo "端口空闲"
```

---

## 5. 启动与验证（核心可运行性测试）

### 5.1 用服务方式启动

```bash
systemctl --user enable --now foundry-daemon.service
systemctl --user status foundry-daemon.service      # 应显示 active (running)
journalctl --user -u foundry-daemon -f               # 实时日志，观察报错
```

### 5.2 用前台方式启动（更直观切到调试）

```bash
# 停止服务，然后：
~/AbstractFoundry/Daemon/launch.sh /dev/ttyAMA0
```

观察日志中出现类似 `Starting daemon version X.Y.Z` 即进入主循环（`heartbeat.pulse()` 每 1 秒一次）。

### 5.3 通过外部接口做“存活/功能”验证

| 测试 | 命令 | 期望结果 |
|---|---|---|
| TCP 端口监听 | `ss -tlnp \| grep -E '2020\|8686'` | 两个端口都在 `LISTEN` |
| Redis 内嵌进程 | `ss -tlnp \| grep 6380` | Redis 在 6380 监听 |
| Python 服务套接字 | `ls -l /tmp/foundry_python_service.sock` | 文件存在 |
| Web 前端 | 浏览器打开 `http://<Pi-IP>`（或 8686） | 加载出 LumiCube 控制界面 |
| REST 接口 | `curl http://127.0.0.1:8686/api/v1/...` | 返回 JSON（见 REST 资源） |
| 视频/数据显示 | 观察日志无持续 `ERROR` 刷屏 | 心跳任务正常执行 |

---

## 6. “能否正常运行”的最短判定标准

满足以下全部条件，即可判定它**在树莓派上正常运行**：

1. 进程为 `active (running)` 且**不**反复 crash（systemd `Restart=always` 会让崩溃表现为“反复重启”，需查日志区分）。
2. 日志出现成功启动信息，且无连续的致命 `ERROR`（例如 Redis 缺库、Python 启动失败、串口打不开）。
3. TCP 2020 / 8686 在监听，Redis 6380 在监听，`/tmp/foundry_python_service.sock` 存在。
4. Web 界面可访问。

> 注意：**没有连接 LumiCube 硬件时**，UAVCAN 相关心跳任务（QueryNodeInfo 等）可能一直报“无响应”，这属于正常现象——硬件部分不会“正常”，但 daemon 主体（网络/Web/存储/Python）仍算运行中。

---

## 7. 已知痛点 / 排错提示（来自代码阅读）

- **VirtualMicrophone 是硬依赖**：没有 PulseAudio 直接启动失败。纯无音频环境可考虑在 `Daemon.java` 中把 `new VirtualMicrophone()` 改成可选/降级（需改源码）。
- **串口不存在会抛异常**：`SerialPort.getCommPorts()` 遍历时若 0 个端口直接 `RuntimeException`。确保接线且设备存在。
- **PulseAudio 的 `module-null-sink` / `module-remap-source`** 需要 pulse 服务已运行（`pactl info` 能通）。
- 内嵌 Redis 需要系统 `libssl`（`Runtime.getRuntime` 加载时依赖）。缺库时 Redis 进程起不来，`Store` 后续访问会报错。

---

## 8. 开机自启服务（已在 192.168.111.248 上完成配置）

为了让 daemon 在树莓派开机后自动运行，配置了 **systemd 用户级服务**（跟随 `illusorywhite` 用户会话启动）：

### 文件布局

| 路径 | 说明 |
|---|---|
| `~/AbstractFoundry/Daemon/Software/Daemon-1.9-SNAPSHOT.jar` | 从源码编译出的 fat JAR（27 MB），放到官方目录布局 |
| `~/AbstractFoundry/Daemon/launch.sh` | 启动脚本，`exec /usr/bin/java -Xmx1024m -jar .../Software/Daemon-1.9-SNAPSHOT.jar "$@"` |
| `~/.config/systemd/user/foundry-daemon.service` | systemd 用户单元 |
| `~/AbstractFoundry/Daemon/log-YYYY-MM-DD.log` | logback 按天滚动的运行日志 |

### systemd 单元内容

```ini
[Unit]
Description=Abstract Foundry Daemon
After=network.target pulseaudio.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
ExecStartPre=/bin/sleep 5
ExecStart=%h/AbstractFoundry/Daemon/launch.sh /dev/ttyAMA0
WorkingDirectory=%h/AbstractFoundry/Daemon
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
```

### 关键步骤（已执行）

```bash
# 启用 linger：让用户级服务在开机（无登录）时也能启动 —— 必须
loginctl enable-linger illusorywhite
# 重新加载 + 开机自启 + 立即启动
systemctl --user daemon-reload
systemctl --user enable foundry-daemon.service
systemctl --user start foundry-daemon.service
```

### 日常管理命令

```bash
systemctl --user status foundry-daemon     # 状态
systemctl --user restart foundry-daemon    # 重启
systemctl --user stop foundry-daemon       # 停止
journalctl --user -u foundry-daemon -f     # 实时日志（如 journal 持久化可用）
tail -f ~/AbstractFoundry/Daemon/log-*.log # 或直接看 logback 文件
```

> 注意：验证 `Linger=yes` 是否生效用 `loginctl show-user <用户名> | grep Linger`；若为 `no`，服务不会在纯开机（无用户登录）时启动。

### 扬声器啸叫修复（2026-09-03）

**现象**：开机后扬声器持续啸叫（麦克风采集 → 扬声器输出的正反馈回路）。

**根因**：`SpeakerThread` 会监控系统默认 sink 的 monitor（`pamon`），并把捕获的音频转发给 LumiCube 的 `speaker.data`。当树莓派上唯一的 PulseAudio/PipeWire sink 是 daemon 自己创建的虚拟麦克风 `null_sink` 时，`SpeakerThread` 捕获的其实是 **LumiCube 自己的麦克风输入**，再播放回 LumiCube 扬声器 → 麦克风再次采到 → 无限正反馈 = 啸叫。

**修复**（`SpeakerThread.java` + `Daemon.java`）：`SpeakerThread` 不再监控"默认 sink"，而是**自己创建专用的输出 sink**（`abstract_foundry.daemon.output.null_sink`）并设为默认：
- `speaker.play()` 的 ffplay 音频 → 输出到专用 sink → pamon 监控 → 转发到 cube 扬声器 ✅（能出声）
- 麦克风音频（`pacat` 推进麦克风 `null_sink`）**不会进入**专用输出 sink → 不再被转发回去 ✅（不啸叫）

同时保留 `FOUNDRY_SPEAKER_ENABLED` 环境变量开关（默认 `true`）：

```bash
# 需要禁用转发时（例如排查音频问题）
FOUNDRY_SPEAKER_ENABLED=false systemctl --user restart foundry-daemon
```

**最终验证（2026-09-03）**：`speaker.play("/home/illusorywhite/Music/Beyond.mp3")` 播放正常、无啸叫，daemon 全部子系统（Web/REST/Redis/Python/音频/串口）运行正常。

> 注：`pacat`（虚拟麦克风采集）仍正常工作，语音识别等功能不受影响。若未来接入真实声卡输出后想恢复"系统音频转发到 LumiCube"，保持 `FOUNDRY_SPEAKER_ENABLED=true` 即可（此时专用输出 sink 仍能隔离麦克风回路）。

---

## 9. 离线安装包（2026-09-03 ）

在树莓派 （Raspberry Pi 5 Model B Rev 1.0，**Debian GNU/Linux 13 (trixie)**（v13.1））上把已验证可用的完整环境打包成 **单文件自解压离线安装器**：

### 产物位置

| 路径 | 说明 |
|---|---|
| `dist/install-lumicube-offline.sh`（约 403 MB） | 单文件自解压离线安装器 |

### 包含内容（payload）

- **`debs/`（521 个 .deb）**：openjdk-21-jre、armhf 库（libc6/libgcc/libatomic/libstdc++）、bullseye 的 `libssl1.1:armhf`、ffmpeg、espeak/espeak-ng、pipewire-pulse、pulseaudio-utils、python3-flask/waitress/pil/numpy/psutil/alsaaudio/pyaudio/pip 等完整依赖闭包（已剔除基础系统核心包，目标机为同版 64 位 Raspberry Pi OS）。
- **`wheels/`（13 个）**：vosk、pyttsx3、precise-runner、cffi、pycparser、srt、websockets 及依赖（Python 3.13 / aarch64 兼容）。
- **`daemon/`**：`Daemon-1.9-SNAPSHOT.jar`（含全部 aarch64 适配与扬声器修复）。

### 使用方法（目标机完全离线）

```bash
# 1. 拷贝安装器到目标树莓派（U 盘/scp 均可）
scp install-lumicube-offline.sh pi@<目标IP>:~/

# 2. 执行安装（需普通用户 + sudo 权限；全程离线，无需联网）
chmod +x ~/install-lumicube-offline.sh
./install-lumicube-offline.sh
```

安装器自动完成：
1. 解压 payload（自解压，`exit 0` 前的脚本逻辑不会解析二进制数据）
2. 安装全部 .deb（自动启用 armhf 多架构；apt 本地闭包优先，dpkg 回退）
3. 离线安装 Python wheels
4. 部署到 `~/AbstractFoundry/Daemon` 官方目录布局
5. 配置 systemd 用户服务 `foundry-daemon.service` + 启用 `linger`（开机自启）
6. 启动服务并输出验证信息（服务状态 / 端口 / 日志 / 串口提示）

### 环境要求与注意

- 目标机需为 **64 位 ARM（aarch64/arm64）**，系统为 **Raspberry Pi OS（Debian 13 trixie）** 或兼容系统。
- 若目标机未启用 UART 串口，安装器会给出提示（`raspi-config` 或 `/boot/config.txt` 的 `dtoverlay=miniuart-bt`）。
- 安装器幂等，可重复执行；如需自定义串口设备，可用 `DAEMON_DEVICE=/dev/ttyAMA0 ./install-lumicube-offline.sh`。