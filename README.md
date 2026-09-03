# lumicube-daemon

**LumiCube 服务（树莓派）** —— Abstract Foundry LumiCube 智能 LED 立方体的树莓派守护进程。

[![Maven build](https://github.com/abstractfoundry/lumicube-daemon/actions/workflows/maven-package.yml/badge.svg)](https://github.com/abstractfoundry/lumicube-daemon/actions/workflows/maven-package.yml)

本仓库为 [abstractfoundry/lumicube-daemon](https://github.com/abstractfoundry/lumicube-daemon) 的延续版本，在其基础上：

- **适配 64 位 ARM（aarch64）树莓派**（Pi 5 / 64 位系统）
- **修复官方下载站下线后无法安装的问题**，提供源码构建 + 离线安装包两种部署方式
- 包含完整的部署、排错与离线打包文档

---

## 功能概览

LumiCube daemon 是运行在树莓派上的后台服务，负责：

- 通过**串口 / UAVCAN** 与 LumiCube 硬件通信（波特率 3,000,000）
- 提供 **Web 界面 / REST API / WebSocket / TCP(2020) / 域套接字** 多个接入点
- **内嵌 Redis + RedisTimeSeries**（端口 6380）做数据存储与时序数据
- **Python 脚本服务**：用户可通过 Web 界面编写并运行 Python 脚本控制设备
- **音频**：虚拟麦克风（采集 cube 麦克风）、扬声器（播放系统音频到 cube）、语音识别
- **开机自启**：systemd 用户服务

---

## 构建可运行的程序

### 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| JDK | **21**（或 17+） | 项目 `pom.xml` 目标是 Java 16，用 JDK 21 构建已验证通过 |
| Maven | 3.9+ | 构建工具 |
| 系统 | Linux（树莓派 arm64 最佳） | 编译出的 JAR 强依赖 Linux 路径与二进制 |

### 构建步骤

```bash
# 1. 安装工具链（树莓派 Debian/Ubuntu 示例）
sudo apt update
sudo apt install -y openjdk-21-jdk-headless maven

# 2. 构建
mvn -DskipTests package

# 产物：
#   target/Daemon-1.9-SNAPSHOT.jar            —— 27MB fat jar（含全部依赖）
#   target/Daemon-1.9-SNAPSHOT.zip            —— 含 lib/ 依赖的 zip
```

> 网络说明：Maven 需要从中央仓库拉依赖。若走代理，请确保 `http_proxy`/`https_proxy` 环境变量指向可用的代理；国内可用阿里云镜像（见 `packaging/` 注释）。

### 运行

```bash
# 前台运行（第一个参数为串口设备）
java -Xmx1024m -jar target/Daemon-1.9-SNAPSHOT.jar /dev/ttyAMA0

# 环境变量
#   FOUNDRY_SPEAKER_ENABLED=true   启用系统音频→LumiCube 扬声器转发（默认 true）
```

启动后：
- Web 界面：`http://<树莓派IP>`（80 端口被 iptables 转发到 8686）
- Redis：`127.0.0.1:6380`
- Python 服务：`/tmp/foundry_python_service.sock`

---

## 目录结构

```
lumicube-daemon/
├── src/main/java/          # Java 源码（核心）
├── src/main/resources/     # 内嵌资源（Redis 二进制、Python 库、Web 前端）
├── src/test/java/          # 单元测试
├── pom.xml                 # Maven 构建
├── build.sh                # AppImage 打包脚本（需 Docker，非主要交付方式）
├── docs/
│   └── DEPLOY_ON_RASPBERRY_PI.md   # 树莓派部署/验证/排错手册
├── packaging/              # 离线安装包制作工具
│   ├── install-lumicube-offline.sh # 自解压安装脚本模板
│   ├── collect_debs.sh     # 收集 .deb 依赖闭包
│   ├── assemble_installer.sh       # 组装单文件安装器
│   ├── verify_installer.sh / dryrun_installer.sh  # 校验脚本
├── tools/
│   ├── deploy_on_pi.sh     # 树莓派部署辅助（环境核查/启停/验证）
│   ├── dsh_ssh.py          # 开发用 SSH 辅助（paramiko）
│   └── cleanup_pi.sh       # 清理树莓派临时文件
└── dist/                   # 构建产物（离线安装包等，不入库）
```

---

## 在树莓派上部署

### 方式一：离线安装包（推荐，无需联网）

见 [packaging/](packaging/) 与 `docs/DEPLOY_ON_RASPBERRY_PI.md` 第 9 节。

```bash
chmod +x install-lumicube-offline.sh
./install-lumicube-offline.sh     # 自动安装依赖+配置开机自启+启动
```

### 方式二：源码构建 + systemd 开机自启

详见 `docs/DEPLOY_ON_RASPBERRY_PI.md`，核心步骤：

```bash
# 1. 源码构建（见上）
# 2. 部署到官方目录
mkdir -p ~/AbstractFoundry/Daemon/Software
cp target/Daemon-1.9-SNAPSHOT.jar ~/AbstractFoundry/Daemon/Software/

# 3. 注册 systemd 用户服务（含开机自启）
mkdir -p ~/.config/systemd/user
# 创建 foundry-daemon.service（内容见文档）
loginctl enable-linger "$USER"          # 关键：开机无登录也启动
systemctl --user daemon-reload
systemctl --user enable --now foundry-daemon
```

---

## 架构与适配说明

本仓库相对上游的关键改动（均在 `src/main/java/com/abstractfoundry/daemon/`）：

| 文件 | 改动 |
|---|---|
| `utility/Platform.java` | 识别 `aarch64`/`arm64` 为 ARM 平台（原判断只认 `arm`，aarch64 会误判为 x64） |
| `redis/RedisLauncher.java` | 启动内嵌 Redis 前 `chmod a+x`（部分文件系统 `setExecutable` 不生效导致 RedisTimeSeries 加载失败） |
| `python/service/GlobalPythonService.java` | 用纯 JDK `UnixDomainSocketAddress` 实现 Python 服务客户端（Jersey/Jetty 客户端在 JDK21 下 connector 初始化失败） |
| `server/WebServer.java` | 注册 Jackson JSON provider（否则 REST API 全部 500） |
| `audio/SpeakerThread.java` | 创建**专用输出 sink** 而非监控默认 sink，避免"麦克风→扬声器"啸叫回路 |
| `Daemon.java` | 增加 `FOUNDRY_SPEAKER_ENABLED` 开关，`SpeakerThread` 默认开启但走专用 sink |

### 内嵌二进制说明

- `src/main/resources/META-INF/resources/redis/{arm,x64}/` 内嵌 **32 位 ARM** 的 redis-server 与 RedisTimeSeries——在 64 位系统上需要 armhf 多架构库（`libc6:armhf` 等）与 `libssl1.1:armhf`（bullseye 版），离线包已内置。
- `src/main/resources/META-INF/resources/python/noise/` 为 arm/x64 的 JNI `.so`。

---

## 已知问题 / 注意事项

- **官方 `install.py` 依赖的 `www.abstractfoundry.com` 已下线**，请使用本仓库的离线安装包或源码构建。
- 扬声器啸叫问题已在 `SpeakerThread` 修复（专用 sink），若仍异常可用 `FOUNDRY_SPEAKER_ENABLED=false` 关闭转发排查。
- 无 LumiCube 硬件时，UAVCAN 心跳任务会报"无响应"，属正常现象；daemon 主体（Web/存储/Python）不受影响。

---

## 版权

本仓库代码源自 [Abstract Foundry Limited](https://github.com/abstractfoundry/lumicube) 的 LumiCube 项目（Copyright © 2022），见 `licenseheader.txt`。
