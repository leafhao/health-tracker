# Health Tracker iPhone Collector

这是 Health Tracker 的 iPhone 采集端。当前 Xcode target 只读 HealthKit，把变化写入本地持久队列，使用 Receiver 公钥做 HPKE 加密并用手机 Ed25519 身份签名，再通过局域网直传或 S3/WebDAV 密文中继发送。

旧版 Health Beat 的 MySQL、iCloud 备份、位置分类等源码仍保留用于历史回溯，但不在当前 **Health Beat** target 的 Sources Build Phase 中，也不是当前产品路径。

## 当前同步范围

- 睡眠分析及分期
- 锻炼、路线和活动圆环
- 心率、静息心率、HRV、血氧、呼吸、腕温、VO₂ Max 和心率恢复
- 步数、距离、能量、锻炼分钟、站立和楼层
- 跑步功率、速度、步幅、垂直振幅、触地时间等专项指标
- 设备与权限能力说明，帮助 Receiver 区分“不支持”和“暂无数据”

App 不申请 HealthKit 写权限。

## 构建要求

- iOS 17.6+
- Xcode 16+
- 真机和自己的 Apple ID/Developer Team
- 已运行的 Health Tracker Receiver

## Xcode 安装

1. 打开 `Health Beat.xcodeproj`。
2. 选择 **Health Beat → Signing & Capabilities**。
3. 选择自己的 Team，并把 Bundle Identifier 改为唯一值。
4. 确认 HealthKit、HealthKit Background Delivery 和 Background Fetch capability 存在。
5. 连接并解锁 iPhone，选择真机后 Build & Run。
6. 按系统提示允许读取需要的 Apple Health 数据。

后台任务和后台 URLSession 标识会从 `PRODUCT_BUNDLE_IDENTIFIER` 派生，不需要手工同步修改硬编码字符串。

## 首次设置

1. Receiver 与 iPhone 位于同一局域网。
2. App 进入“设置 → 端到端加密”，选择自动发现的 Receiver 并请求配对。
3. 在 Receiver 本机 Dashboard 批准请求。
4. App 选择首次历史范围。开发验证建议最近 30 天；个人正式使用通常最近一年即可。
5. 完成首次局域网直传后，再配置 S3/WebDAV 做日常密文增量中继。

首次历史同步使用稳定批次和后台 `URLSession` 文件上传。锁屏或切换 App 后，已提交给系统的上传任务可以继续；强制划掉 App 后不保证继续。只有 Receiver 返回 `committed` 回执，手机才删除本地批次。

## 后台执行

- HealthKit Observer：数据变化时请求系统唤醒。
- BGAppRefreshTask：由 iOS 自主安排补漏。
- 进入前台：节流执行补偿同步。
- Outbox：网络失败、限流或进程中断时保留密文批次。

iOS 不承诺固定调度时间。请在系统“后台 App 刷新”中启用“健康同步”，且不要从多任务界面强制划掉 App。

## AltStore

AltStore Classic 安装会重新签名 IPA，可能影响 HealthKit/后台 entitlement。完整步骤和强制验证清单见仓库根目录 [AltStore 文档](../../docs/altstore-classic.md)。在 AltStore 真机验证成功前，Xcode 安装是基准路径。

## 隐私

- S3/WebDAV 凭据和设备私钥保存在 Keychain。
- 云端对象内容在上传前已经完成 HPKE 加密；云服务无法解读健康明文。
- App 不会把健康数据发送给 AI 服务。
- 不要提交 IPA、描述文件、Keychain 导出、真实 Endpoint 凭据或调试健康数据。

## License

MIT。此工程最初基于 Klemens Arro 的 Health Beat 项目演进，原版权声明见 [LICENSE.md](LICENSE.md)。
