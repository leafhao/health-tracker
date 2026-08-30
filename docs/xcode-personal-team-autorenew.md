# Mac mini + Xcode 自动续签

这是 HealthKit App 的推荐免费续签路径。它不会延长旧描述文件，而是在到期前由
Mac mini 使用 Xcode Automatic Signing 重新构建，再以相同 Team 与 Bundle ID
覆盖安装。正常的覆盖安装不会删除 App 沙盒、Keychain、HealthKit 授权或快捷指令绑定。

## 工作策略

- launchd 每 30 分钟运行一次轻量检查；
- 距描述文件到期超过 72 小时且 iOS 源码未变化时立即退出；
- 剩余不足 72 小时或 iOS 源码树变化时重新构建；
- 安装前强制验证 `healthkit` 和 `healthkit.background-delivery` entitlement；
- iPhone 不在线时保留签名产物，下次直接重试，不重复构建；
- 连续失败 3 次才发出 macOS 通知；
- 状态、到期时间与日志保存在
  `~/Library/Application Support/HealthTrackerSigner/`。

## 一次性准备

1. Mac mini 安装完整 Xcode。
2. 打开 Xcode → Settings → Accounts，登录用于 Personal Team 的 Apple ID。
3. 在 Xcode 中确认 Team 能显示，并允许 Xcode 创建 Apple Development 证书。
4. iPhone 用 USB 与 Mac mini 配对一次，在 Finder 开启“连接 Wi-Fi 时显示此 iPhone”。
5. iPhone 保持开发者模式开启；首次安装时解锁设备。

Apple ID 密码和二次验证码只交给 Xcode，本项目脚本不读取也不保存。

如果登录钥匙串不能被 launchd 稳定访问，可以使用独立的
`~/Library/Keychains/HealthTrackerSigner.keychain-db`。其随机密码仅保存在当前用户
可读的 `~/Library/Application Support/HealthTrackerSigner/keychain-password`，权限为
`0600`；脚本不会保存 Apple ID 密码。

## 安装

在 Mac mini 的仓库目录执行：

```zsh
IOS_DEVICE_ID='你的 iPhone UDID' \
DEVELOPMENT_TEAM='你的 Team ID' \
BUNDLE_IDENTIFIER='com.longfeihao.healthsync' \
./scripts/configure_ios_autorenew_macos.zsh install
```

安装前也可以单独检查一次性条件：

```zsh
IOS_DEVICE_ID='你的 iPhone UDID' \
./scripts/configure_ios_autorenew_macos.zsh preflight
```

查看或立即运行：

```zsh
./scripts/configure_ios_autorenew_macos.zsh status
./scripts/configure_ios_autorenew_macos.zsh run-now
tail -f "$HOME/Library/Application Support/HealthTrackerSigner/renewal.log"
```

## 更新 App 代码

脚本不会自动拉取 GitHub 的新代码，避免未经验证的提交自动覆盖正式 App。将已验证的
提交更新到 Mac mini 仓库后，下一次检查会发现 `ios/HealthBeat` 源码树改变并自动
构建、安装；只修改 Receiver 或文档不会浪费一次 iOS 重签。

## 无感使用的边界

免费 Personal Team 的描述文件仍只有 7 天。Mac mini 与 iPhone 应至少每 7 天有一次
可安装窗口。Apple ID 登录过期、二次验证、证书撤销、设备信任重置、开发者模式关闭，
以及手机长期不在同一局域网，仍可能需要人工恢复。脚本只做覆盖安装，绝不先卸载 App。
