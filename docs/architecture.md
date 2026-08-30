# 技术架构

> 本文记录当前可运行的 v1 直连架构，仅用于迁移和回溯。新的产品边界、密文中继和增量同步设计见 [系统架构 v2](system-architecture-v2.md)。

## 目标

- 免费运行，使用 Mac mini + Xcode Personal Team 自动覆盖安装，并允许手机离线后重试。
- 不把数据库账号保存在 iPhone。
- 不把 MySQL/SQLite 端口暴露给手机或互联网。
- 每条 HealthKit 样本保留 UUID、类型、数值、单位、起止时间、来源和设备，能够去重和补传。
- 睡眠跨日，按“入睡夜晚”归属；锻炼按实际起止时间归属。
- Hermes 默认分析昨天完整数据，并在数据尚未同步完整时延迟分析。

## iPhone 端

以 `ios/HealthBeat` 为底座，保留 HealthKit 查询、权限、数据模型和后台观察逻辑，移除以下非必要模块：

- MySQL 直连和数据库密码配置。
- 作者的 iCloud Container。
- Clinical Health Records 权限。
- 后台定位、围栏、位置日志和相关 UI。
- Live Activity、Widget 和 Workout 写入能力（首版不需要）。
- 药物、视力、ECG 等首版不分析的数据，可在权限页面暂时关闭，但数据库协议保留扩展空间。

新增或改造：

- `ReceiverConfig`：Receiver 主 URL、备用 URL和短时一次性配对码。
- 一次性配对码临时存入 Keychain，成功后立即删除；Receiver 不维护第二套管理员密码。
- `EndpointSelector`：局域网探测优先，失败后使用 Tailscale；缓存最近成功地址。
- 持久化上传队列：HealthKit 数据先落盘，再推进读取游标。
- 上传前先将完整 JSON 批次原子写入 Application Support；网络失败不丢批次，下次前台或 HealthKit 唤醒时继续。
- 恢复时回查最近 7 天；服务端依靠 UUID 幂等去重。
- 同步状态：最后采集时间、最后上传时间、待上传批次数、签名剩余天数提示。

## 地址切换

不读取 Wi-Fi SSID，也不依赖定位权限。

1. 当前有 Wi-Fi 时，先以 1 秒超时请求局域网 `/health`。
2. 局域网失败时请求 Tailscale `/health`。
3. 将成功地址缓存 10 分钟。
4. 上传过程中连接失败，使用同一批次切换另一个地址重试。
5. 两个地址都失败时保留本地队列，等待下次 HealthKit 唤醒、App 启动或定时重试。

两个 URL 必须指向 Mac mini 上同一个 Receiver 和同一个 SQLite 文件。

## Mac mini 接收端

建议首版使用 Python FastAPI + SQLite：

- 监听 `127.0.0.1:8787` 和局域网接口。
- Tailscale 通过 Mac mini 的 `100.x` 地址访问同一个端口。
- 网页管理使用 Receiver 本机 / Tailscale 身份；手机使用一次性配对码；旧 Bearer Token 仅保留给 v1 兼容接口。
- 每次最多接受 500 条记录。
- 使用 UUID 主键和 UPSERT 保证重复上传安全。
- SQLite 开启 WAL、foreign keys 和 busy timeout。
- 每日任务生成 `exports/health-YYYY-MM-DD.json`。
- Receiver 超过 36 小时没有收到数据时通知用户。

首版不需要公网 IP，也不开放数据库端口。若未来需要避免 iPhone Tailscale 后台限制，可在 Receiver 前增加 Cloudflare Tunnel，iPhone 只使用一个 HTTPS URL。

## 每日分析边界

- 普通指标：目标日期 `00:00:00` 至次日 `00:00:00`。
- 睡眠：读取目标日期前一天 `18:00` 至目标日期当天 `18:00`，归入前夜主睡眠和当天午睡，并排除下一晚睡眠。
- 锻炼：以锻炼开始时间归属目标日期，同时保留跨日结束时间。
- 心率区间：使用锻炼起止时间筛选原始心率样本。
- Hermes 运行前检查 `last_sample_at` 和 `last_upload_at`；若手机当天尚未解锁同步，则延后执行。

## 可靠性原则

- Personal Team 描述文件到期不会导致 HealthKit 原始数据丢失；App 会停止运行，Mac mini
  恢复覆盖安装后由本地队列和 HealthKit 回查补齐。
- iPhone 端队列和 HealthKit 回查共同负责恢复。
- 服务端所有写入幂等，重复上传不增加重复记录。
- SQLite 每日快照备份；JSON 是分析产物，不是唯一数据源。
