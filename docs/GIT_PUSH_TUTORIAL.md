# Git 推送 GitHub 教程（本机已验证流程）

> 适用环境：Windows + Git for Windows + GitHub 仓库 `SillusoryWhite/lumicube-daemon-2026-rebuild`
> 本教程基于 2026-09 实际完成推送时踩过的坑整理，**照抄即可成功**。

---

## 0. 一次性环境准备（已配置，换新电脑才需要）

| 配置项 | 命令 | 说明 |
|---|---|---|
| Git 安装 | 官网/镜像下载 `Git-x.y.z-64-bit.exe` 安装 | 本机装在 `G:\Program Files\Git\` |
| 用户信息 | `git config --global user.name "SillusoryWhite"`<br>`git config --global user.email "你的邮箱"` | 提交时署名 |
| **梯子代理** | `git config --global http.proxy http://127.0.0.1:7897`<br>`git config --global https.proxy http://127.0.0.1:7897` | 走系统梯子（本机 7897 端口） |
| **TLS 后端** | `git config --global http.sslBackend openssl` | ⚠️ 关键！默认 schannel 在代理下报 `SEC_E_NO_CREDENTIALS`，必须切 openssl |
| 凭据 | 见下方"认证方式" | HTTPS 用 PAT，或改 SSH |

> 可用 `git config --global --list` 查看当前配置。

---

## 1. 认证方式（二选一）

### 方式 A：HTTPS + Personal Access Token（本次使用）

1. GitHub → Settings → Developer settings → **Personal access tokens**
2. **Fine-grained tokens**：Repository access 选目标仓库，Permissions → **Contents: Read and write**（只读无法 push，403 拒绝）
   — 或 **Tokens (classic)**：勾选 `repo` 权限
3. 生成 `ghp_...` / `github_pat_...` 开头的 token
4. 推送时用它当密码。**token 是敏感信息：用完请到 token 页撤销**

### 方式 B：SSH（免密，推荐长期使用）

```bash
ssh-keygen -t ed25519 -C "你的邮箱"          # 生成密钥
# 公钥内容复制到 GitHub → Settings → SSH and GPG keys
git remote set-url origin git@github.com:SillusoryWhite/lumicube-daemon-2026-rebuild.git
```

---

## 2. 日常更新流程（修改代码后推送）

在项目目录 `E:\lumicube\lumicube-daemon-main` 打开终端：

```bash
# ① 查看改动
git status

# ② 添加改动（. 表示全部；或指定文件 git add src/xxx.java）
git add .

# ③ 提交（-m 写本次改动说明）
git commit -m "更新说明：修复了xxx / 新增了xxx"

# ④ 推送（首次或换分支用 -u 建立跟踪）
git push origin main
# 之后可直接 git push
```

> 提示：本机 git 在 `G:\Program Files\Git\cmd\git.exe`，若提示找不到 git，可用全路径或把 `G:\Program Files\Git\cmd` 加入系统 PATH。

---

## 3. 新仓库/新电脑首次推送

```bash
git init
git add .
git commit -m "Initial commit 首次提交项目"
git branch -M main
git remote add origin https://github.com/SillusoryWhite/lumicube-daemon-2026-rebuild.git
git push -u origin main
```

---

## 4. 特殊情况处理

### 4.1 远程已有内容，本地想覆盖（本次场景）

```bash
# 警告：会删除远程历史！仅当远程内容确定可丢弃时使用
git push origin main --force
```

### 4.2 远程和本地历史不一致（non-fast-forward 报错）

```bash
git fetch origin          # 拉取远程
git pull origin main --rebase   # 把本地提交变基到远程之上
# 解决冲突后：
git push origin main
```

### 4.3 大文件（>100MB 会被 GitHub 拒绝）

- 本仓库的 `dist/install-lumicube-offline.sh`（403MB）已被 `.gitignore` 排除，**不要**提交
- 发布用 GitHub **Release**：仓库 → Releases → Create a new release → 拖文件上传（单文件上限 2GB）

---

## 5. 常见报错对照表

| 报错 | 原因 | 解决 |
|---|---|---|
| `schannel: SEC_E_NO_CREDENTIALS` | TLS 后端与代理冲突 | `git config --global http.sslBackend openssl` |
| `Permission ... denied` / 403 | token 无写权限 | Fine-grained token 把 Contents 设为 Read and write；或换 classic token 勾 repo |
| `failed to push some refs` / non-fast-forward | 远程有本地没有的提交 | `git pull origin main --rebase` 后再 push |
| `fatal: unable to access ... 403` | 代理没开 / token 失效 | 确认梯子已开、token 未过期未撤销 |
| `error: RPC failed; HTTP 413/curl 56` | 文件过大 | 用 .gitignore 排除大文件，大文件走 Release |
| `could not lock config file ... Permission denied` | 沙箱/权限限制 | 用管理员终端执行 git config |

---

## 6. 安全提醒

- **token 一旦出现在聊天/日志中，立即撤销**：https://github.com/settings/tokens
- 别把 token 写进仓库文件或 `.gitconfig` 的 URL 里（本次推送用了临时带 token 的 URL，完成后已还原为干净地址）
- 长期维护建议改用 **SSH 密钥**（第 1 节方式 B），一劳永逸且不出现在 URL 中
