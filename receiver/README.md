# Health Tracker Receiver

Receiver 与具体电脑无关，可运行在当前 Mac、Mac mini、Linux 或 NAS。v2 已包含加密直连、设备注册、事件入库、规整任务、可移植备份，以及 S3 数据胶囊的自动拉取与认证回执闭环。完整本机验证见 [本机 v2 验证](../docs/local-v2-validation.md)。

Receiver 接收 iPhone 上传的 HealthKit JSON，使用 SQLite 保存原始层，并生成去重后的规范化层、Hermes 按日数据和健康面板。数据库端口不会暴露给手机。

v2 的核心状态默认集中在 `~/Library/Application Support/HealthTracker`（可用 `HEALTH_TRACKER_HOME` 覆盖）。迁移不要只复制 SQLite：必须使用 `v2-backup` 同时带走数据库和 Receiver HPKE 私钥，再用 `v2-restore` 恢复。

## 推荐：Mac mini 一键安装

先把整个 `health_tracker` 项目复制或克隆到 Mac mini，然后在 Mac mini 的终端进入项目目录执行：

```bash
zsh scripts/configure_receiver_macos.zsh install --mode agent
```

脚本会：

- 检查 Python 3.11+ 并创建 `.venv`。
- 安装 Receiver 依赖并初始化 SQLite。
- 保留一枚不对外显示的随机 v1 兼容凭据；新管理和配对流程不再复用它。
- 安装并启动 Web API、规整/面板物化、云中继三个独立常驻进程，并通过 Bonjour 在局域网广播。
- 安装每小时刷新昨天 JSON 的 `com.longfeihao.health-daily-export` 服务。
- 打开无密码管理面板；手机配对由本机面板确认，不再依赖 Tailscale。

若提示 Python 版本太低，先安装 Homebrew Python：

```bash
brew install python@3.12
```

检查运行状态：

```bash
curl http://127.0.0.1:8787/api/v1/healthbeat/health
launchctl print gui/$(id -u)/com.longfeihao.health-receiver
launchctl print gui/$(id -u)/com.longfeihao.health-normalizer
launchctl print gui/$(id -u)/com.longfeihao.health-cloud-relay
```

重新运行安装脚本会更新依赖、备份旧 plist 并重启服务，不会改变 Receiver 加密私钥或已注册设备。

## 开发环境启动

在项目根目录执行：

```bash
python3 -m venv .venv
.venv/bin/pip install -r receiver/requirements.txt
openssl rand -hex 32
.venv/bin/python -m receiver.cli hash-token '上一步生成的原始Token'
```

最后两步仅为尚未迁移的 v1 API 生成兼容凭据；不要把它当成管理员密码或手机配对码。Receiver 配置其 SHA-256 散列即可。

```bash
HEALTH_RECEIVER_TOKEN_SHA256='Token的SHA-256散列' \
HEALTH_RECEIVER_DB='/绝对路径/health.sqlite3' \
.venv/bin/uvicorn receiver.app:app --host 0.0.0.0 --port 8787
```

上面的开发启动方式会在 Web 进程内嵌后台循环，便于单命令调试。正式安装会设置
`HEALTH_RECEIVER_WORKERS_EXTERNAL=1`，并分别运行：

```bash
.venv/bin/python -m receiver.worker normalization --data-root '/数据目录'
.venv/bin/python -m receiver.worker cloud-relay --data-root '/数据目录'
```

这样长耗时规整、历史面板回填或云端暂时限流不会阻塞 HTTP API，也能由 launchd/systemd
分别重启。三个进程共用同一台机器上的 SQLite WAL 数据库；当前架构不支持多主机同时写这份数据库。

浏览器访问 `http://Mac地址:8787/api/v1/healthbeat/health`，应返回 `{"status":"ok", ...}`。不要把 8787 端口映射到公网；家庭局域网与 Tailscale 地址会进入同一个服务。

## 数据规整

原始表按 HealthKit UUID 幂等写入，完整保留，便于以后调整规则。分析不直接把 Apple Watch、iPhone 和第三方 App 的重叠样本相加，而是写入单独的规范化表：

- 步数、距离、能量、楼层等累计指标拆分到分钟，重叠分钟按 Apple Watch、iPhone、第三方来源的优先级选择。
- 心率等离散指标按分钟归并，同时保留样本数、最小值和最大值。
- 睡眠按 HealthKit 语义自动降级：任何来源的 Core/Deep/REM 分期拥有其完整睡眠会话；`Asleep Unspecified` 只补充不与分期会话重叠的睡眠（例如 AutoSleep 午睡）。没有分期设备时，未分期数据仍可独立形成主睡眠；规则不依赖特定设备、App 名称或语言。跨夜主睡眠和当天午睡分别统计。
- VO₂ Max、心率恢复、体重和体脂率等低频指标使用目标日期结束前的最近一次有效测量。
- BMI 优先读取 HealthKit；缺失时按最近体重和身高计算。去脂体重优先读取 HealthKit；缺失时按最近体重和体脂率计算。结果保留测量时间和来源标记。
- 锻炼关联训练期间的心率、跑步功率、步频、距离、配速、楼层和路线爬升。

手动规整某一天或日期范围：

```bash
.venv/bin/python -m receiver.cli normalize \
  --database '/绝对路径/health.sqlite3' \
  --date 2026-08-27 \
  --timezone Asia/Shanghai

.venv/bin/python -m receiver.cli normalize \
  --database '/绝对路径/health.sqlite3' \
  --from-date 2026-08-21 --to-date 2026-08-27
```

数据写入后由后台任务重建受影响日期的物化汇总和完整面板 JSON 快照。目标日变化时，依赖其 28 日基线的后续日期也会进入去重队列。全局“数据可用性”另有版本化快照；日面板请求只读取这些已计算结果和少量同步状态，避免切换日期时扫描原始样本。所有快照都能从规范化表重新生成，不是唯一数据源。

## 健康数据面板

在接收端电脑打开 `http://127.0.0.1:8787/dashboard` 即可直接进入。远程访问使用 Tailscale Serve 的 `https://你的设备名.你的Tailnet.ts.net/dashboard`，Receiver 根据 Tailscale 注入的用户身份授权，无需第二套密码。普通局域网地址不能访问管理页。面板展示：

- 睡眠总量、结构占比、主睡眠、午睡、标准睡眠效率、连续率和 14/30/90 天趋势
- 只在主睡眠时间窗内计算的心率、HRV、呼吸率、血氧和腕温，避免被白天样本稀释
- 步数、距离、能量、锻炼分钟、站立、楼层
- 真实 24 小时时间轴的日内心率、静息心率、HRV、血氧、呼吸、VO₂ Max 和心率恢复
- 近 28 天个人基线、可解释恢复信号、入睡/起床规律性
- 训练时长、距离、配速、心率、个体化心率储备区间、路线爬升、跑步功率和步频
- 按心率区间分钟数加权的每日训练负荷、近 7 日累计以及相对前期基线
- iPhone 上报的设备与采集能力，用于区分“不支持”“尚未申请权限”和“支持但暂无样本”
- 已接收类型、来源数量、数据新鲜度，以及“当天未测量”和“从未收到”的区别

训练心率区间不会假装读取 Apple Watch 的私有区间设置：Receiver 使用近 90 天实测最高心率和近 28 天静息心率中位数计算五级心率储备区间；历史不足时自动隐藏区间，不影响其他训练信息。

Receiver 监听局域网接口以便 iPhone 完成首次配对，但管理面板仍只信任 Receiver 本机访问，或来自 localhost 代理且匹配所有者的 Tailscale 身份头。局域网客户端只能访问公开身份、发起短期配对请求及加密批次接口。旧 v1 数据 API 暂时继续使用独立兼容 Token。不要配置 Tailscale Funnel，也不要将 8787 映射到公网。

## 本机 Agent API

同一台电脑上的 Agent 使用以下只读接口，无需 Token：

```text
GET http://127.0.0.1:8787/api/v1/agent/catalog
GET http://127.0.0.1:8787/api/v1/agent/context/2026-08-27
GET http://127.0.0.1:8787/api/v1/agent/series/hrv_sdnn_ms?from_date=2026-08-01&to_date=2026-08-27
```

接口强制要求客户端和 URL 都是 localhost；局域网地址与 Tailscale 域名即使能访问 Dashboard，也不能调用 Agent API。字段来源、计算口径、意义、缺失原因和使用边界见 [Agent API 文档](../docs/agent-api.md)，也可以由 Agent 直接读取 `catalog` 获得机器可读定义。

## macOS 长期运行

推荐使用一键配置脚本先检查和预演：

```bash
./scripts/configure_receiver_macos.zsh check
./scripts/configure_receiver_macos.zsh install --mode daemon --apply-power --dry-run
```

个人电脑可选择 `--mode agent`；长期无人值守的 Mac mini 选择 `--mode daemon`。脚本提供版本化运行目录、失败回滚、深度就绪检测、watchdog、每日 AES-256-GCM 加密备份、数据库维护和日志轮转。只有显式添加 `--apply-power` 才会修改系统电源设置。完整说明见 [macOS 长期运行文档](../docs/macos-service-hardening.md)。

## Linux 长期运行

systemd Linux 使用独立入口，避免把 launchd 和 systemd 分支混在同一个脚本中：

```bash
./scripts/configure_receiver_linux.sh install --dry-run
./scripts/configure_receiver_linux.sh install
```

Linux 版使用 `/opt/health-tracker` 的版本化只读运行目录、`/var/lib/health-tracker` 的持久数据目录和专用 `healthtracker` 低权限账户。安装 Avahi 后，iPhone 可沿用现有 Bonjour/mDNS 自动发现；没有 Avahi 时仍可通过局域网 IP 手动配对。完整说明见 [Linux 长期运行文档](../docs/linux-service-hardening.md)。

## 配置 iPhone App

- 确保 iPhone 与 Receiver 在同一个可互访的局域网。
- 打开 App 的“设置 → 端到端加密”，选择自动发现的 Receiver 并点击“请求配对”。
- 回到 Receiver 本机管理面板，对显示的 iPhone 点击“允许配对”。

Bonjour 仅广播 Receiver 名称、端口和公钥标识，不携带任何秘密或健康数据。配对请求 10 分钟过期，批准时绑定手机的 Ed25519 公钥；成功后日常 S3 密文同步只使用手机设备密钥和 Receiver HPKE 公钥，不再需要局域网、Tailscale、地址或配对码。若路由器禁用了 mDNS，可展开手机和面板中的手动配对备用入口。

## 生成 Hermes 每日文件

例如生成 2026-08-27 的文件：

```bash
.venv/bin/python -m receiver.cli export \
  --database '/绝对路径/health.sqlite3' \
  --date 2026-08-27 \
  --timezone Asia/Shanghai \
  --output 'exports/health-2026-08-27.json'
```

文件中：

- `normalized.quantity_minutes` 是按分钟、来源优先级去重后的分析数据。
- `normalized.daily_summary`、`normalized.sleep_summary` 和 `normalized.workouts` 可直接供 Hermes 生成日报。
- 顶层 `quantity_minutes` 继续保留原始样本的分钟分组，兼容旧消费者。
- `workouts` 只包含目标日期开始的锻炼；距离、时长、能量和元数据保留。
- `sleep_samples` 使用“前一日 18:00 到目标日 18:00”，包含前夜主睡眠和当天午睡。
- `freshness` 可供 Hermes 判断手机是否刚同步，避免用不完整数据生成日报。

省略 `--date` 时会自动选择上海时区的昨天；配合 `--output-dir exports` 会自动生成文件名。因此定时任务可以直接执行：

```bash
.venv/bin/python -m receiver.cli export \
  --database '/绝对路径/health.sqlite3' \
  --timezone Asia/Shanghai \
  --output-dir '/绝对路径/exports'
```

## launchd 常驻

复制 [health-receiver.plist.example](health-receiver.plist.example)，将其中三个 `__...__` 占位符替换为绝对路径、数据库路径和 v1 兼容凭据散列，再保存到 `~/Library/LaunchAgents/com.longfeihao.health-receiver.plist`。服务必须只监听 localhost；安装脚本会记录可信 Tailscale 登录名。另一个 [health-daily-export.plist.example](health-daily-export.plist.example) 每小时覆盖生成昨天的 JSON，以便晚到的后台数据被补入。加载前先用 `plutil -lint` 检查。

## 验证

```bash
.venv/bin/python -m unittest discover -s receiver/tests -v
```

真机验证仍必须进行：模拟器没有你的真实 Apple Health 数据，也不能证明 iOS 实际的后台唤醒频率。
