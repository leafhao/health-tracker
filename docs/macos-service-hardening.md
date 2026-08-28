# macOS 长期运行与一键配置

项目提供 [configure_receiver_macos.zsh](../scripts/configure_receiver_macos.zsh)，用于把开发目录中的 Receiver 安装成版本化、可回滚的 macOS 服务。脚本不会默认修改电源设置。

## 只检查当前状态

```bash
./scripts/configure_receiver_macos.zsh check
```

检查内容包括：launchd 状态、深度就绪接口、SQLite `quick_check`、最新自动备份和接电睡眠设置。该命令不修改系统。

## 先预演

```bash
./scripts/configure_receiver_macos.zsh install --mode agent --dry-run
./scripts/configure_receiver_macos.zsh install --mode daemon --apply-power --dry-run
```

`--dry-run` 只说明将要执行的操作，不复制文件、不加载服务，也不调用 `sudo`。

## 个人电脑：用户登录后运行

```bash
./scripts/configure_receiver_macos.zsh install --mode agent
```

该模式安装到当前用户的 `~/Library/LaunchAgents`，具备：

- 登录后自动启动；
- Web API、规整/面板物化 Worker、云中继 Worker 分进程运行，各自退出后由 launchd 自动重启；
- 每 5 分钟深度就绪检测，连续两次失败后重启；
- 每小时刷新昨日 JSON；
- 每天 03:15 执行 SQLite 检查、WAL checkpoint、加密备份、备份保留和日志轮转。

注销用户或电脑整体睡眠时，LaunchAgent 不会继续提供服务。

## Mac mini：开机即运行

```bash
./scripts/configure_receiver_macos.zsh install --mode daemon --apply-power
```

该模式需要管理员权限，将服务安装到 `/Library/LaunchDaemons`。Receiver 本身仍以当前用户身份运行；watchdog 和维护任务保留系统权限，用于重启系统域服务和轮转其日志。

显式添加 `--apply-power` 后才会执行：

- 禁止接电时整机自动睡眠；
- 保留显示器休眠；
- 开启网络唤醒和 Power Nap；
- 开启断电恢复后自动开机。

不希望脚本修改电源设置时省略该参数。

## 版本化运行目录

安装不会让 launchd 直接引用 Git 工作区，而是创建：

```text
~/Library/Application Support/HealthTracker/runtime/
├── releases/<UTC时间>-<git版本>/
└── current -> releases/<当前版本>/
```

每个发布目录都有独立虚拟环境和 `requirements.lock.txt`。新版本通过深度就绪检测后才算安装成功；检测失败会把 `current` 切回旧版本并重新启动。

重复安装或更新使用同一条命令即可。

## 深度就绪检测

```bash
curl http://127.0.0.1:8787/api/v1/healthbeat/ready
```

该接口只允许 localhost，检查：

- SQLite 是否可读取；
- 规整 worker 心跳；
- S3 云中继 worker 心跳；
- 待规整任务数量；
- 待生成面板快照数量；
- 同步序列缺口。

HTTP `200` 表示 ready，`503` 表示进程仍在但内部服务不完整。

## 自动加密备份

首次安装会生成 32 字节备份密钥，并仅在首次创建时显示 Base64 恢复密钥。必须将恢复密钥保存到密码管理器；密钥丢失后无法在其他电脑恢复 `.htbk` 文件。

立即运行一次维护和备份：

```bash
./scripts/configure_receiver_macos.zsh backup-now
```

备份使用 SQLite 在线 backup API 创建一致性数据库副本，再连同 Receiver 私钥打包，并使用 AES-256-GCM 流式加密。自动备份默认保留 14 天。

验证备份：

```bash
RUNTIME="$HOME/Library/Application Support/HealthTracker/runtime/current"
KEY="$HOME/Library/Application Support/HealthTracker/keys/backup-encryption.key"
"$RUNTIME/.venv/bin/python" "$RUNTIME/scripts/secure_backup.py" verify \
  --key "$KEY" --input /path/to/health-tracker-xxx.htbk
```

恢复时先使用 `secure_backup.py decrypt` 解密为 portable ZIP，再用 `receiver.cli v2-restore` 恢复到一个新的空目录。不要覆盖正在运行的数据库。

## 安全边界

- Receiver 为手机配对与加密上传监听局域网端口，但 Dashboard 和 Agent API 仍有独立访问限制；
- 不要配置路由器公网端口映射或 Tailscale Funnel；
- 精确 GPS 和原始样本不会通过默认 Agent API 暴露；
- 自动备份的加密密钥不要和上传到云端的 `.htbk` 文件存放在同一云目录。
