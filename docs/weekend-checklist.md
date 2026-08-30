# 周末执行清单

## 需要用户完成

- [x] 在用于编译的 Mac 安装完整 Xcode，并首次启动完成组件安装。
- [x] 准备自己的 Apple ID/Personal Team，并在 Xcode 中完成登录和双重认证。
- [ ] iPhone 与编译 Mac 通过数据线完成“信任此电脑”。
- [ ] iPhone 开启开发者模式。
- [x] 在 Mac mini 安装完整 Xcode，并配置 Personal Team 自动续签任务。
- [ ] 确认 iPhone 和 Mac mini 日常处于同一家庭 Wi-Fi。
- [ ] 确认 iPhone 与 Mac mini 的 Tailscale 登录到同一 tailnet。

## Codex 执行顺序

### A. 精简并构建 iOS App

- [x] 从上游 HealthBeat 创建改造分支，并将最终工作树迁入 `ios/HealthBeat`。
- [x] 更换 Bundle ID 和显示名称。
- [x] 从主 App 编译目标移除作者 iCloud Container、Clinical Records、定位、Widget 和无关模块。
- [x] 保留只读 HealthKit 与 Background Delivery。
- [x] 使用 HTTP Receiver，解除 MySQL 前置依赖。
- [x] 增加双地址探测、Keychain Token 和持久化上传队列。
- [x] iOS 26.5 模拟器构建并启动成功，检查最终 entitlements。
- [ ] 选择开发团队后构建真机包。
- [ ] 通过 Xcode 首次安装，完成 HealthKit 权限授权。

### B. 部署 Mac mini Receiver

- [x] 在当前开发目录创建 Python 虚拟环境并通过测试。
- [x] Receiver 可自动初始化 SQLite 数据库。
- [x] 管理页使用 Receiver 本机 / Tailscale 身份，并由面板生成短时单次手机配对码。
- [x] 配置 launchd 常驻运行 Receiver。
- [ ] 配置 macOS 防火墙，仅允许 Receiver 端口。
- [ ] 验证局域网地址和 Tailscale 地址都能访问 `/health`。

### C. 端到端验证

- [ ] 手动同步最近 1 天。
- [ ] 对照 Health App 检查睡眠、心率、步数、能量和锻炼数量。
- [ ] 验证 VO₂ Max 和跑步专项指标。
- [x] 自动测试已验证相同 UUID 重传只保留一条。
- [ ] 关闭 Wi-Fi，验证 Tailscale 回退。
- [ ] 同时断开两个地址，验证 iPhone 队列保留；恢复后补传。
- [ ] 将 App 放入后台并锁屏，验证 HealthKit 后台更新。
- [x] 用 Xcode Automatic Signing 覆盖安装，确认 HealthKit 授权和后台能力仍保留。

### D. Hermes 接入

- [ ] 生成昨天的规范 JSON。
- [ ] 增加数据新鲜度检查。
- [ ] 输出睡眠、训练、心率区间、恢复和运动量建议。
- [ ] 超过 36 小时无同步时报警，不生成误导性日报。

## 验收标准

- 连续 7～10 天无需手工导出。
- 至少完成一次 Mac mini 无线覆盖安装，并验证续签状态记录正常。
- 任意 48 小时断网后能自动补齐，无重复记录。
- 昨日 JSON 与 Health App 关键汇总一致。
- App、Receiver 和 Hermes 均不记录明文 Token 或数据库密码。
