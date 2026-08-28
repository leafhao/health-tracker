# 当前电脑上的 v2 验证

这套 Receiver 不依赖 Mac mini。应用代码无状态，所有需要迁移的内容都在一个数据目录中：

```text
HealthTracker/
├── health.sqlite3       # 原始事件、业务表、规整结果和同步状态
├── keys/                # Receiver HPKE 私钥（必须与数据库一起迁移）
└── relay/               # 本地 Relay 测试的 inbox、receipt、processed、quarantine
```

## 1. 启动当前电脑 Receiver

项目根目录执行：

```bash
python3 -m venv .venv
.venv/bin/pip install -r receiver/requirements.txt
export HEALTH_TRACKER_HOME="$PWD/.local-health-state"
export HEALTH_RECEIVER_DB="$HEALTH_TRACKER_HOME/health.sqlite3"
export HEALTH_RECEIVER_TOKEN_SHA256="$(`pwd`/.venv/bin/python -m receiver.cli hash-token '填入手机的原始Token')"
.venv/bin/python -m receiver.cli v2-init --data-root "$HEALTH_TRACKER_HOME"
.venv/bin/uvicorn receiver.app:app --host 0.0.0.0 --port 8787
```

`v2-init` 输出的是 Receiver 公钥，不含私钥。服务启动后可检查：

```bash
curl http://127.0.0.1:8787/api/v1/healthbeat/health
curl http://127.0.0.1:8787/api/v2/system/identity
```

## 2. iPhone 配对与同步

重新构建并安装 iOS 工程后：

1. 保留当前电脑的局域网或 Tailscale 地址与原始 Token，点击“保存并测试连接”。
2. 点击“启用端到端加密同步”。手机会生成 Ed25519 私钥并留在 Keychain，只把公钥注册到 Receiver。
3. 点击“执行加密增量同步”。首次会建立基线，后续只读取各类型 anchor 之后的 added/deleted 变更。
4. 在 Receiver 本机打开 `http://127.0.0.1:8787/dashboard`，或通过 Tailscale Serve HTTPS 地址以 Tailscale 身份进入；无需 Receiver 密码。

加密同步的 POST 不传健康明文，也不依赖 Bearer Token 来证明设备身份；Receiver 使用已注册 Ed25519 公钥验签，再用本机 HPKE 私钥解密。Token 只用于首次设备注册与管理接口。

## 3. 本地 Relay 消费测试

将 `.henv` 密文放入 `$HEALTH_TRACKER_HOME/relay/inbox/` 后运行：

```bash
.venv/bin/python -m receiver.cli v2-consume-once --data-root "$HEALTH_TRACKER_HOME"
.venv/bin/python -m receiver.cli v2-normalize-jobs --data-root "$HEALTH_TRACKER_HOME"
```

成功对象进入 `processed/` 并在 `receipts/` 生成回执；无效签名、损坏 JSON 或无法解密的对象进入 `quarantine/`，不会写入健康表。这一目录适配器与后续 S3 poller 使用相同的解密入库服务。

## 4. 备份、迁移与恢复

创建包含一致性 SQLite 快照和 Receiver 私钥的权限受限备份：

```bash
.venv/bin/python -m receiver.cli v2-backup \
  --data-root "$HEALTH_TRACKER_HOME" \
  --output ./health-tracker-backup.zip
```

在另一台 macOS/Linux 电脑安装相同代码和依赖后，恢复到一个新的空目录：

```bash
.venv/bin/python -m receiver.cli v2-restore \
  --archive ./health-tracker-backup.zip \
  --data-root /path/to/new/HealthTracker
```

恢复会拒绝非空目标、异常压缩包路径和未知格式，并验证数据库迁移与 Receiver 密钥匹配。备份内含健康数据和解密私钥，应像密码库一样保护；后续会再增加带口令的归档层。

## 5. 自动测试

```bash
.venv/bin/python -m unittest discover -s receiver/tests -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project 'ios/HealthBeat/Health Beat.xcodeproj' \
  -scheme 'Health Beat' -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

自动测试覆盖 Swift/Python HPKE 互操作、密文篡改、未知设备、重复批次、序列缺口、Relay 隔离、规整任务以及跨电脑备份恢复。真实 HealthKit 权限、数据量和后台唤醒仍需真机验收。

## 6. 后台同步与保留策略

iOS 使用三层触发：HealthKit Observer 近实时唤醒、`BGAppRefreshTask` 系统调度补漏、App 进入前台补漏。Observer 会合并短时间内同时变化的类型，只对变化流执行 anchor 查询；无论触发多少次，anchor 与稳定事件 ID 都能避免重复业务数据。iOS 不保证固定分钟级执行时间，因此界面中的“最近完成”和 Receiver 的 `last_seen_at` 才是实际新鲜度依据。

Relay 默认保留 14 天，可通过 Receiver 环境变量设置为 1–365 天：

```bash
export HEALTH_RELAY_RETENTION_DAYS=14
.venv/bin/python -m receiver.cli v2-retention-cleanup \
  --data-root "$HEALTH_TRACKER_HOME"
```

清理器只删除已有 committed receipt 的旧密文；没有回执的对象即使超期也保留。接入 S3 后采用双层策略：Receiver 收到并提交后立即/尽快删除云端 inbox 对象，Bucket Lifecycle 再以 N 天做硬上限；手机本地未确认副本不会按 N 天删除，所以 Receiver 离线超过保留期时仍可重传。
