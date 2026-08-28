# Health Tracker 重构路线

## Phase 0：协议和安全基线

- [x] 确立 Collector / Relay / Receiver / Dashboard 边界。
- [x] 定义端到端加密 Envelope 和增量事件 Batch。
- [x] 为 Envelope 与 Batch 建立 JSON Schema。
- [ ] 在数据胶囊账户中确认 S3 endpoint、region、path-style、Access Key 权限、对象版本和生命周期能力。
- [x] 使用 RFC 9180 固定测试向量完成 Swift CryptoKit HPKE 与 Python `cryptography` 的跨语言加解密测试。

完成标准：同一测试批次在 iPhone 端加密、Python 端验签解密；任何一字节篡改都会失败。

## Phase 1：真正的 iPhone 增量采集

- [x] 将 `PersonalHealthSyncService` 拆出 Collector、AnchorStore、Outbox、Transport 与配对服务。
- [x] 每个 HealthKit 类型使用 `HKAnchoredObjectQuery`，记录 added samples 和 deleted objects。
- [x] 使用原子文件保存不可变密文 Outbox 和 per-stream anchors；先写 Outbox、后推进 anchor。
- [x] Observer 合并并精确传递变化类型；另用 BGAppRefresh 和前台进入补漏。
- [x] Activity Summary 使用最近日期窗口确定性 upsert。
- 保留“重建最近 N 天”作为修复工具，不再作为日常同步算法。

完成标准：反复同步零新增时产生 0 个健康事件；删除 HealthKit 样本能生成 tombstone；任意阶段杀掉 App 后不会漏数。

## Phase 2：S3 密文中继

- 实现 `S3RelayTransport` 和 SigV4。
- 使用 background URLSession 从加密文件上传。
- [x] 设备私钥存 Keychain，Receiver 公钥与非秘密配对信息持久化。
- [x] Receiver 实现通用消费器、receipt 和 quarantine；当前用本地文件 Relay 做等价测试。
- [x] 保留 `DirectReceiverTransport` 供当前电脑真机验证。

完成标准：关闭 Receiver 一天不影响手机采集；Receiver 恢复后自动追平；对象存储中不存在可识别健康明文。

## Phase 3：Receiver 数据平台

- [x] 引入版本化迁移和可移植状态目录。
- [x] 增加 devices、keys、ingest_batches、raw_events、tombstones、jobs。
- [x] 把 v2 workout route JSON 拆为 route_points。
- 将规整规则迁移到指标注册表。
- [x] 按受影响日期生成并执行规整任务；旧面板 API 暂时保留请求时修复能力。
- 增加数据质量、来源冲突、序列缺口和规则版本。

完成标准：重复、乱序、延迟、删除和规则升级都有自动测试；API 请求不承担重计算任务。

## Phase 4：完整健康 Dashboard

- 独立 TypeScript 前端和版本化 API client。
- 完成总览、睡眠、活动、训练、恢复、路线、数据质量和系统设置页面。
- [x] 路线默认使用无第三方请求的本地 SVG 隐私预览。
- 支持桌面和手机响应式布局。

完成标准：不用 AI 即可浏览完整健康历史、训练详情、趋势和同步质量。

## Phase 5：开放接口与运维

- 建立 scope Token、审计日志和可撤销设备/API 凭据。
- 提供 OpenAPI、JSON/CSV/Parquet 导出。
- 增加 SQLite 在线备份、加密归档、保留策略和恢复演练。
- 提供 launchd 与 Docker Compose 两种部署。

完成标准：新机器可以从备份恢复；第三方只拿到被授权的数据范围。

## 迁移策略

现有 HTTP Receiver 和 SQLite 不立即删除：

1. v1 direct upload 与 v2 relay 并行。
2. v2 批次写入新的控制/原始表，同时适配现有 typed tables。
3. 新规整器与现有日报对比至少 7 天。
4. Dashboard 切到 v2 API。
5. 确认数据一致后，再将 v1 标记为只读兼容层。

该策略允许手机和服务端分别升级，避免一次性重写导致真实健康数据断档。
