# Linux 长期运行与一键配置

Receiver 的局域网直传协议与操作系统无关：iPhone 使用标准 HTTP 上传端到端加密包，Receiver 使用 Python 验签、解密并幂等入库。自动发现使用 mDNS；macOS 对应 `dns-sd`，Linux 对应 Avahi 的 `avahi-publish-service`。

Linux 入口是 [`configure_receiver_linux.sh`](../scripts/configure_receiver_linux.sh)，面向以 systemd 为 PID 1 的发行版。它不会与 macOS 的 launchd 配置混用。

## 安装前预览

```bash
./scripts/configure_receiver_linux.sh install --dry-run
```

正式安装要求 Python 3.11+、`python3-venv`、`curl`、`sqlite3`、systemd 和 sudo。Avahi 不是数据传输必需项，但若想让 iPhone 自动发现 Receiver，应安装发行版的 Avahi 工具包：

```bash
# Debian / Ubuntu
sudo apt install python3-venv curl sqlite3 avahi-daemon avahi-utils

# Fedora
sudo dnf install python3 curl sqlite avahi avahi-tools
```

## 正式安装

```bash
./scripts/configure_receiver_linux.sh install
```

若主机启用了 firewalld 或 UFW，并希望脚本打开 Receiver 的 TCP 8787 端口：

```bash
./scripts/configure_receiver_linux.sh install --open-firewall
```

默认结构：

```text
/opt/health-tracker/
├── releases/<version>/     # root 所有、不可变版本
└── current -> releases/... # 原子切换和失败回滚

/var/lib/health-tracker/    # healthtracker 低权限账户所有
├── health.sqlite3
├── keys/
├── relay/
├── exports/
└── backups/automatic/
```

systemd 会分别管理 `health-tracker-receiver` Web API、`health-tracker-normalizer` 规整/面板物化 Worker 和 `health-tracker-cloud-relay` 云中继 Worker；每小时导出、每 5 分钟深度就绪检查，以及每天 03:15 的 SQLite 检查和 AES-256-GCM 加密备份由独立 timer 运行。日志直接进入 journald，不另行维护易失控的文本日志。

## 检查和维护

```bash
./scripts/configure_receiver_linux.sh check
./scripts/configure_receiver_linux.sh backup-now
journalctl -u health-tracker-receiver.service -f
journalctl -u health-tracker-normalizer.service -f
journalctl -u health-tracker-cloud-relay.service -f
```

首次安装会输出一次备份恢复密钥。必须将其保存在密码管理器或离线介质中；仅有 `.htbk` 文件而没有该密钥无法恢复。

## 局域网配对

Avahi 正常时，手机现有的 `_healthtracker._tcp.local.` 浏览逻辑会直接发现 Linux Receiver，不需要更新 iOS App。若路由器隔离了 mDNS、Linux 防火墙拦截组播或没有安装 Avahi，可以在手机中手动填写 `http://<Linux局域网IP>:8787`，配对和首次直传仍然有效。

管理面板继续只允许 Receiver 本机的 `http://127.0.0.1:8787/dashboard`，或经可信 Tailscale Serve 反向代理访问；局域网设备只能调用配对和加密数据接口。
