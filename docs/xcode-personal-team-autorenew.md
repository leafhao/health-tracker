# Mac mini + Xcode 自动续签

这是 HealthKit App 的推荐免费续签路径。它不会延长旧描述文件，而是在到期前由
Mac mini 使用 Xcode Automatic Signing 重新构建，再以相同 Team 与 Bundle ID
覆盖安装。正常的覆盖安装不会删除 App 沙盒、Keychain、HealthKit 授权或快捷指令绑定。

Mac mini 是签名与自动续签的主机，GitHub 只同步代码。方案不需要在手机或电脑安装额外的
重签工具，也不把 Apple ID 密码交给项目脚本。

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

## 多台开发 Mac 使用同一证书

需要在另一台 Mac 构建或通过 USB 安装时，应共享 Mac mini 当前有效的 Apple Development
身份，而不是让每台电脑各自创建证书：

1. 在 Mac mini 的“钥匙串访问 → 登录 → 我的证书”中找到当前 Apple Development 证书，
   展开并确认它带有私钥。
2. 只选择该证书和对应私钥，导出为设置了强随机密码的临时 `.p12`。
3. 点对点传到另一台自己的 Mac，并导入该电脑的“登录”钥匙串。
4. 在两台电脑分别运行下面的命令，确认目标身份的 SHA-1 指纹完全一致：

   ```zsh
   security find-identity -v -p codesigning \
     "$HOME/Library/Keychains/login.keychain-db"
   ```

5. 用 Xcode Automatic Signing 完成一次真机构建，并用 `codesign -dvv` 核对实际产物使用
   的身份；验证后立即删除两端临时 `.p12`、密码和导出目录。

不要把 `.p12`、私钥密码、描述文件或 Keychain 导出物提交到 Git/GitHub，也不要通过公共
网盘或聊天工具长期保存。Mac mini 应作为证书来源和续签权威；其他 Mac 不应随意创建、
删除或撤销证书。正常的 7 天描述文件刷新不会改变证书，只有证书被撤销或 Xcode 自动创建
了新证书时，才需要重新同步身份。

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

推荐在开发 Mac 完成修改和测试后推送 GitHub，再由 Mac mini 拉取已确认的提交。脚本故意
不自动 `git pull`，避免未经验证的远端提交直接覆盖手机上的正式 App。

## 网络与无线安装边界

- iPhone 与 Mac mini 第一次必须通过 USB 完成信任和配对。
- 日常无线覆盖安装依赖 Finder Wi-Fi 同步、Bonjour/mDNS 与 CoreDevice 本地网络隧道；
  两台设备必须处于可互访的同一局域网。
- Tailscale 可以用于 SSH 管理 Mac mini、同步 Git 仓库、读取日志和构建产物，但通常不
  转发 Bonjour/CoreDevice，不能把异地 iPhone 变成可无线安装的本地设备。
- 异地更新时，可让 Mac mini 先完成签名构建，再把已签名 App 安全传给身边的共享证书
  开发 Mac，通过 USB 覆盖安装。

## 无感使用的边界

免费 Personal Team 的描述文件仍只有 7 天。Mac mini 与 iPhone 应至少每 7 天有一次
可安装窗口。Apple ID 登录过期、二次验证、证书撤销、设备信任重置、开发者模式关闭，
以及手机长期不在同一局域网，仍可能需要人工恢复。脚本只做覆盖安装，绝不先卸载 App。
