# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。产品版本、加密同步协议版本和数据库迁移版本彼此独立。

## [Unreleased]

### Changed

- 长期安装方案统一为 Mac mini + Xcode Personal Team 自动续签；移除第三方重签实验路径，
  补充多 Mac 共享同一签名证书与无线安装边界说明。

## [0.1.0-beta.1] - 2026-08-29

首个公开测试版本，面向自托管、单用户的 Apple Health 数据管理场景。

### Added

- iOS HealthKit 增量采集、首次局域网历史直传和系统后台文件上传。
- S3/WebDAV 密文中继，手机端加密签名，Receiver 端验证、解密、去重和确认。
- 局域网自动发现与一次性安全配对。
- 睡眠、午睡、活动、生命体征、训练、心率区间、跑步指标和轨迹规整。
- 物化健康面板、个人基线趋势和本机只读 Agent API。
- macOS/Linux 版本化 Receiver 安装、深度就绪检查、回滚、Watchdog 和加密备份。
- 快捷指令“立即增量同步”动作，可用于充电、到家、公司或 Wi-Fi 自动化保底。

### Changed

- 自动化与 HealthKit Observer 的重叠触发会合并，并在当前任务结束后补查一次。
- 面板训练名称使用中文展示，原始 HealthKit 类型继续保留在数据库和 API 中。

### Known limitations

- iOS 最终决定 HealthKit 后台交付和 BGAppRefresh 的运行时间，不能保证固定时刻执行。
- Personal Team 描述文件只有 7 天，iPhone 仍需定期与续签 Mac 形成一次 USB 或同局域网
  无线覆盖安装窗口。
- 当前健康规则用于个人记录和趋势参考，不构成医疗诊断或训练处方。

[Unreleased]: https://github.com/leafhao/health-tracker/compare/v0.1.0-beta.1...HEAD
[0.1.0-beta.1]: https://github.com/leafhao/health-tracker/releases/tag/v0.1.0-beta.1
