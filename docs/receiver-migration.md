# Receiver 迁移

Receiver 状态不仅是 SQLite。迁移必须同时带走数据库和 Receiver 私钥，否则已配对手机产生的密文无法在新机器解密。

## 安全迁移流程

### 1. 在旧 Receiver 创建便携备份

```bash
ROOT="$HOME/Library/Application Support/HealthTracker"
RUNTIME="$ROOT/runtime/current"
"$RUNTIME/.venv/bin/python" -m receiver.cli v2-backup \
  --data-root "$ROOT" \
  --output "$HOME/Desktop/health-tracker-portable.zip"
```

该 ZIP 包含一致性 SQLite 快照和 `keys/`。它是高敏感明文备份，只应通过可信局域网/加密磁盘传输，并在迁移后安全删除。

### 2. 在新 Receiver 安装代码但不要开始手机重配对

```bash
git clone https://github.com/leafhao/health-tracker.git
cd health-tracker
python3 -m venv .venv
.venv/bin/pip install -r receiver/requirements.txt
```

### 3. 恢复到新的空数据目录

```bash
ROOT="$HOME/Library/Application Support/HealthTracker"
test ! -e "$ROOT" || mv "$ROOT" "$ROOT.pre-migration-$(date +%Y%m%d-%H%M%S)"

.venv/bin/python -m receiver.cli v2-restore \
  --archive "$HOME/Desktop/health-tracker-portable.zip" \
  --data-root "$ROOT"
```

`v2-restore` 拒绝覆盖非空目录。保留旧目录直到新 Receiver 完成验证。

### 4. 安装常驻服务

```bash
./scripts/configure_receiver_macos.zsh install --mode agent
# 常开 Mac mini 最终可改为：
./scripts/configure_receiver_macos.zsh install --mode daemon --apply-power
```

### 5. 验证后再停旧 Receiver

```bash
./scripts/configure_receiver_macos.zsh check
curl http://127.0.0.1:8787/api/v1/healthbeat/ready
```

还需人工确认：

- `/dashboard` 能打开并显示最近一个月的睡眠、活动和锻炼。
- Receiver key ID 与旧机一致，手机仍显示已配对。
- `pending_normalization_jobs` 和 `sequence_gaps` 为 0，数据库 `quick_check` 为 `ok`。
- 手机完成一轮增量同步后，新 Receiver 的数据新鲜度前进。
- S3/WebDAV 密文中继由新 Receiver 拉取并写回 receipt。
- 生成一次新的加密备份并保存恢复密钥。

验证完成后才能卸载旧机 launchd 服务。不要同时清空旧数据；至少保留一份加密备份度过观察期。

## 迁移后的地址变化

迁移保留相同 Receiver 私钥和设备注册信息，因此加密身份不变。Bonjour 会广播新机器的局域网地址；日常云中继不依赖旧 IP。若手机仍保留手动直连地址，可以在 App 中重新选择自动发现的新 Receiver，但不应重新生成 Receiver 身份。
