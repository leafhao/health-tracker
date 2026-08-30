# 上游源码锁定与改造入口

## 选定底座

- Repository: `https://github.com/kempu/HealthBeat`
- Current checkout: `ios/HealthBeat`
- Reviewed commit: `df07606`（2026-05-12，Add EA backend as parallel sync destination alongside MySQL）
- License: MIT，见 `ios/HealthBeat/LICENSE.md`

最初的改造分支是 `codex/http-sqlite-receiver`。迁入 `health_tracker` 时已去除嵌套 `.git`，改由本仓库统一管理；上游基线提交固定为：

```bash
df07606de30f90073c6676f926d8987a0d9a2489
```

## 已确认可复用的文件

- `Models/HealthDataType.swift`：HealthKit 类型、单位和权限集合。
- `Models/BackendRows.swift`：HTTP/数据库共用的 Codable 行模型。
- `Services/HealthKitService.swift`：查询、分页和 HealthKit 数据读取。
- `Services/BackgroundSyncManager.swift`：ObserverQuery 与后台触发。
- `Services/BackendWriter.swift`：HTTP Writer 协议和所有实体写入方法。
- `Services/EAService.swift`：Bearer Token、JSON 分批、重试和健康检查。
- `Services/SyncService.swift`：当前同步主流程，也是解除 MySQL 依赖的主要改造点。

## 已发现的上游问题

- `MySQLConfig` 将数据库密码编码后放入 `UserDefaults`，并可能通过 iCloud 配置同步，不符合本项目安全要求。
- `EAConfig` 的 Token 同样保存在 `UserDefaults`，必须迁移到 Keychain。
- HTTP Writer 当前仅在 MySQL 写入成功后执行，不能单独作为主后端。
- `EAService` 使用 ephemeral `URLSession` 和内存请求体，App 被挂起后不适合作为可靠的长任务上传。
- 原项目启用了作者的 iCloud Container、Clinical Health Records、后台定位和 Widget，个人签名时应删除。
- 原项目后台任务受锁屏 HealthKit 加密限制；必须依赖解锁后回补，不能承诺精确同步时间。
- 跑步功率、速度、步幅、垂直振幅和触地时间存在；没有独立 Running Cadence 类型，首版需研究由步数时间序列或锻炼统计派生。

## 不采用的候选

- `healthkit-cli`：指标覆盖有限，日报最低/最高心率尚未完成，后台通知不主动持久化完整数据。
- `healthkit-graphql-bridge`：更偏前台按需查询，不适合作为静默增量同步底座。
- `health-auto-export-server`：只是 Health Auto Export 的接收端，仍依赖付费 iOS App。

这些仓库仅用于调研，没有复制进当前项目；需要时可依据名称重新获取上游版本。

## 首版范围

必须完成：

- Quantity samples
- Sleep category samples
- Workouts
- Workout routes
- Activity summaries
- UUID 幂等写入
- 7 天回补
- 局域网/Tailscale 地址回退
- Xcode Personal Team 覆盖安装后的 HealthKit 权限验证

后续再做：ECG、药物、视力、位置围栏、营养和完整历史回填 UI。
