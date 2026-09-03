#!/usr/bin/env python3
"""
LumiCube 部署用 SSH helper —— 基于 paramiko 的受控远程执行工具。

用法:
  python dsh_ssh.py run "<command>"             # 在远端执行命令，返回 stdout+stderr
  python dsh_ssh.py put <local> <remote>         # 上传本地文件到远端
  python dsh_ssh.py fetch <remote> [<local>]     # 下载远端文件到本地(可选路径)

环境变量(避免密码硬编码在命令历史):
  DSH_PI_HOST    默认 192.168.111.248
  DSH_PI_USER    默认 illusoryWhite
  DSH_PI_PASS    密码(必填)

示例:
  set DSH_PI_PASS=xxx
  python dsh_ssh.py run "uname -a"
  python dsh_ssh.py put deploy_on_pi.sh /home/illusoryWhite/deploy_on_pi.sh
"""
import os, sys, io, argparse
import paramiko
import posixpath

# Windows 控制台默认 GBK 编码，遇到非 ASCII/二进制输出会崩溃；强制 UTF-8 输出。
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HOST = os.environ.get("DSH_PI_HOST", "192.168.111.248")
USER = os.environ.get("DSH_PI_USER", "illusoryWhite")
PASS = os.environ.get("DSH_PI_PASS", "")

def connect():
    if not PASS:
        sys.stderr.write("ERROR: 未设置环境变量 DSH_PI_PASS (密码)\n")
        sys.exit(2)
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS,
              timeout=20, look_for_keys=False, allow_agent=False)
    return c

def run(cmd):
    c = connect()
    try:
        stdin, stdout, stderr = c.exec_command(cmd, timeout=300)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        print(out, end="")
        if err.strip():
            sys.stderr.write(err)
        return code
    finally:
        c.close()

def put(local, remote):
    c = connect()
    try:
        c.open_sftp().put(local, remote)
        return 0
    finally:
        c.close()

def fetch(remote, local):
    c = connect()
    try:
        sftp = c.open_sftp()
        if local:
            sftp.get(remote, local)
        else:
            data = io.BytesIO()
            sftp.getfo(remote, data)
            sys.stdout.buffer.write(data.getvalue())
        return 0
    except FileNotFoundError:
        sys.stderr.write(f"ERROR: 远端不存在 {remote}\n")
        return 1
    finally:
        c.close()

def main():
    ap = argparse.ArgumentParser(description="LumiCube SSH helper")
    ap.add_argument("op", choices=["run", "put", "fetch"], help="操作")
    ap.add_argument("a", help=argparse.SUPPRESS)
    ap.add_argument("b", nargs="?", default=None, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.op == "run":
        sys.exit(run(args.a) or 0)
    elif args.op == "put":
        sys.exit(put(args.a, args.b))
    elif args.op == "fetch":
        sys.exit(fetch(args.a, args.b))

if __name__ == "__main__":
    main()