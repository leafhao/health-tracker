# Health Tracker 系统架构 v2

## 1. 产品定义

Health Tracker 是一个独立、自托管的个人健康信息管理系统。AI Agent 不是系统核心，只是受限 API 的可选消费者。

系统由两个用户可见模块和一个传输中继组成：

```text
Apple Health / HealthKit
        ↓
iPhone Collector
  增量读取、持久队列、端侧加密、后台上传
        ↓
S3-compatible Relay（只看到密文）
        ↓
Receiver / Health Server
  拉取、验签、解密、幂等入库、规整、分析 API
        ↓
Dashboard / Export / Scoped API clients
```

系统不要求 iPhone 与接收器同时在线，也不要求接收器有公网 IP。Mac mini 只是接收器的一种部署环境；Linux、NAS 或其他长期在线电脑同样适用。

## 2. 核心原则

1. **先落盘，再推进游标**：HealthKit 变更只有在加密批次安全写入本地发件箱后，才提交新锚点。
2. **传输与业务解耦**：采集器只依赖 `SyncTransport`；首选 S3 中继，保留直连 Receiver 作为开发和应急适配器。
3. **中继零知识**：批次在 iPhone 上完成压缩、加密和签名；对象存储只保存随机名称的密文对象。
4. **原始层不可变、规整层可重建**：服务端保留规范化前的 HealthKit 事件和删除事件；任何规则升级都可以重新计算。
5. **幂等优先**：设备序列号、批次 ID、事件 ID 和 HealthKit UUID 分层去重，允许任意重试。
6. **单体优先、边界清晰**：首版使用模块化单体和 SQLite，不提前引入微服务；采集、消费、规整、API、Web 可以独立进程运行。
7. **隐私默认开启**：地图不默认调用第三方瓦片；AI Token 默认不能读取原始样本和精确轨迹。

## 3. iPhone Collector

### 3.1 HealthKit 增量读取

每个 HealthKit 样本流维护独立的 `HKQueryAnchor`：

- Quantity：心率、步数、距离、能量、HRV、VO₂ Max、跑步专项等。
- Category：睡眠等。
- Workout：训练记录；训练变化后再读取关联路线。
- Activity Summary：不支持普通样本锚点，按最近日期窗口使用确定性 ID 做 upsert。

一次采集事务：

```text
读取 committed anchor
    ↓
HKAnchoredObjectQuery（新增样本 + deletedObjects）
    ↓
生成 upsert/delete 事件
    ↓
分批、压缩、加密、签名
    ↓
原子写入 Outbox 文件 + proposed anchor
    ↓
提交 committed anchor
    ↓
后台上传 Outbox；上传成功后删除本地副本
```

如果 App 在提交锚点前崩溃，下次会重复读取；服务端幂等去重。如果 App 在提交后上传失败，密文仍在 Outbox，数据不会丢失。

### 3.2 后台策略

- App 启动最早阶段注册 `HKObserverQuery` 和 Background Delivery。
- Observer 只负责触发相应流的 anchored query，不回查全部类型和最近 7 天。
- 只要求在 iOS 给定时间内完成“读取变化并写入本地 Outbox”；网络上传与 Observer completion 解耦。
- 使用 background `URLSession` 从文件上传密文对象，让系统在 App 挂起后继续传输。
- `BGAppRefreshTask`、进入前台和手动同步作为补偿机制，不承诺固定时间运行。
- 每日执行轻量一致性扫描，检查序列缺口；每周执行有限窗口校验，不进行常态全量重传。

iOS 对后台调度拥有最终决定权，因此产品目标是“最终一致、无需日常人工干预”，不是承诺某分钟必定完成。

### 3.3 本地状态

建议使用一个轻量 SQLite 状态库，而不是把状态分散在 `UserDefaults` 和文件名中：

- `device_identity`
- `stream_anchors`
- `outbox_batches`
- `upload_attempts`
- `sync_runs`
- `transport_config`

密钥与 S3 Secret 存 Keychain，数据库仅保存 key ID。v2 Collector 最低支持 iOS 17，以直接使用 CryptoKit 的标准 RFC 9180 HPKE，避免自定义公钥加密组合。

### 3.4 传输接口

```swift
protocol SyncTransport {
    func probe() async throws -> TransportStatus
    func upload(file: URL, objectKey: String, checksum: String) async throws
    func listReceipts(after sequence: UInt64) async throws -> [BatchReceipt]
}
```

实现：

- `S3RelayTransport`：生产默认，通过数据胶囊或任意 S3 兼容存储。
- `DirectReceiverTransport`：开发、局域网诊断和应急恢复。
- 后续可增加 `iCloudDriveTransport`、`WebDAVTransport`，不影响采集器。

## 4. 密文中继

对象布局不暴露健康类型和真实日期：

```text
health-sync/
  inbox/<opaque-device-id>/<first>-<last>-<random-pack-id>.hpack
  receipts/<opaque-device-id>/<sequence>.json
  quarantine/<opaque-device-id>/<random-pack-id>.hpack
```

`health-relay-pack/1` 只负责传输聚合：手机将最多 64 个已经完成 HPKE 加密和
Ed25519 签名的独立 `.henv` 批次合并为一个目标约 8 MiB 的 `.hpack` 对象。
Receiver 拆包后仍逐批验签、解密、幂等入库并生成批次级 receipt。打包层不会
接触明文健康数据；旧版单个 `.henv` 对象继续兼容。

首次历史回溯按手机本地时区的自然月由近到远执行。每个月完成采集和本地密文
落盘后立即上传，并保存月级检查点；单月超过大小或批次数限制时拆为多个 Part。
月份分组只存在于手机本地 sidecar 和加密批次内容中，云端对象名使用随机 pack
ID，不暴露历史覆盖月份。日常增量按一次同步运行分组，不强行套用自然日边界，
以兼容补录、删除和跨日睡眠修订。

对象存储凭据应尽量只允许：

- iPhone：向自己的 `inbox/<device>/` 写入、读取自己的 receipts；不能读取其他设备或 processed 数据。
- Receiver：列举/读取 inbox，写 receipts 和 quarantine。

如果数据胶囊只提供账户级 Access Key，端到端加密仍能保护内容，但凭据泄漏可能导致密文被删除或制造垃圾对象。此时 Receiver 必须依靠批次序列缺口报警和本地/云端保留策略发现问题。

## 5. Receiver 模块

Receiver 采用模块化单体：

```text
health_server/
  domain/          # 事件、指标、睡眠、训练等领域模型
  crypto/          # 验签、解密、密钥轮换
  transports/      # S3、direct HTTP
  ingestion/       # 批次状态机、幂等写入、隔离区
  normalization/   # 单位、来源冲突、分钟/日聚合、睡眠会话
  analytics/       # HR zones、趋势、负荷、恢复等确定性计算
  api/             # 面板 API、导出 API、Agent API
  web/             # 独立前端静态资源
  workers/         # relay poller、normalize jobs、retention
```

首版仍可由一个安装包提供，但运行时分为：

- `health-api`：只服务 API 和前端。
- `health-normalizer`：执行规整任务，并刷新受影响日期的完整面板快照与全局数据可用性快照。
- `health-cloud-relay`：轮询对象存储、验证密文、解密并幂等入库。
- `health-maintenance`：备份、完整性检查和保留策略。

开发环境为方便调试可以让 API 内嵌两个后台循环；macOS/Linux 正式安装始终使用独立进程。各进程共享同机 SQLite WAL，不把 SQLite 放到网络文件系统，也不允许多台 Receiver 同时写入。

### 5.1 接收状态机

```text
discovered → downloading → verified → decrypted → committed → normalized
                         ↘ rejected / quarantined
```

`batch_id` 和 `(device_id, sequence)` 都是唯一键。数据库事务成功后才写 receipt；重复对象直接返回已有 receipt。

### 5.2 数据层

SQLite 仍是个人单用户部署的默认选择：无需数据库服务、备份简单、百万级样本足够。所有表从第一天包含 `owner_id`，以后可迁移 PostgreSQL，但当前不为多用户复杂度付费。

数据分层：

1. **控制层**：devices、keys、ingest_batches、stream_cursors、jobs、audit_log。
2. **原始层**：raw_events、quantity_samples、category_samples、workouts、route_points、activity_summaries、tombstones。
3. **规范层**：minute_metrics、daily_metrics、sleep_sessions、sleep_stages、normalized_workouts、workout_metrics、route_summaries。
4. **分析层**：heart_rate_zones、training_load、baselines、anomalies。只保存可解释的确定性结果，不保存 AI 结论。
5. **面板快照层**：`dashboard_day_snapshots` 和 `dashboard_global_snapshots`。面板按日访问只读取快照；输入变化通过去重任务队列刷新目标日及受其基线影响的后续日期。快照可从规范层重建，不是唯一数据源。

当前把路线点保存在 JSON blob 的方式需要改为 `route_points` 表，至少包含时间、经纬度、海拔、速度、精度和顺序索引。

### 5.3 规整规则注册表

规整行为不再散落在 Python 常量和 if/else 中。每个指标注册：

- HealthKit identifier
- canonical unit
- data kind：cumulative / discrete / category / correlation
- aggregation：sum / mean / min / max / latest / duration union
- source priority 和冲突策略
- dashboard group、显示单位和隐私等级

规整任务按受影响的日期和实体增量重算；规则版本写入结果，支持规则升级后批量重建。

## 6. API 边界

建议 v2 API：

- `GET /api/v2/health/days/{date}`：完整日视图。
- `GET /api/v2/health/series`：类型、时间范围、分辨率查询。
- `GET /api/v2/sleep/sessions`：主睡眠、午睡和阶段。
- `GET /api/v2/workouts`、`GET /api/v2/workouts/{id}`。
- `GET /api/v2/workouts/{id}/route`：需要单独的 route scope。
- `GET /api/v2/metrics/latest`：低频指标最近值。
- `GET /api/v2/system/sync-status`：设备、序列缺口、延迟和队列。
- `POST /api/v2/sync/batches`：可选直连传输。

访问令牌按 scope 划分：

- `read:summary`
- `read:series`
- `read:workouts`
- `read:routes`
- `read:raw`
- `sync:write`
- `admin`

未来给 AI Agent 的令牌默认只有 `read:summary` 和必要的聚合序列，不允许读取精确路线、原始 metadata 或管理接口。

## 7. Dashboard 信息架构

Dashboard 本身是完整健康客户端，不依赖 AI：

1. **总览**：日/周/月核心卡片、数据新鲜度、异常缺口。
2. **睡眠**：主睡眠、午睡、阶段、效率、时间规律、夜间心率/HRV/呼吸/腕温。
3. **活动**：步数、距离、能量、站立、楼层和时间趋势。
4. **训练**：训练列表、心率区间、配速/功率/步频、训练负荷。
5. **心肺与恢复**：静息心率、HRV、VO₂ Max、心率恢复、血氧、呼吸。
6. **路线**：训练轨迹、海拔曲线、分段；默认不请求第三方地图瓦片。
7. **数据质量**：来源覆盖、冲突、缺失时段、同步延迟和设备序列缺口。
8. **系统设置**：设备配对、密钥轮换、S3 状态、备份和 API Token。

前端从当前单文件 HTML 迁移为独立 TypeScript 应用；API 与 UI 分离，仍由 Receiver 静态托管，保持一键部署。

## 8. 部署与备份

- 原生 macOS：launchd 运行 API、worker 和维护任务。
- 通用部署：Docker Compose，挂载数据目录和密钥目录。
- SQLite 使用 WAL、定期 `VACUUM`/checkpoint、在线 backup API。
- 备份内容包括数据库、设备注册表和 Receiver 私钥；备份本身再次加密。
- S3 inbox 是传输缓冲，不是唯一备份。

## 9. 不在首阶段实现

- 医疗诊断或自动治疗建议。
- 多租户 SaaS、支付、团队协作。
- 依赖大模型生成基础健康指标。
- 将原始明文健康数据上传到任何第三方 AI 或对象存储。
