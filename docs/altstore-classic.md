# 使用 AltStore Classic 续签 iPhone App

AltStore Classic 可以使用自己的 Apple ID 重新签名并安装 IPA。免费 Apple ID 安装的 App 通常 7 天到期，AltStore 会在后台尝试通过 AltServer 刷新；它不是永久签名，也不能保证每次后台刷新成功。

官方资料：

- [macOS 安装 AltStore](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)
- [AltServer 工作方式](https://faq.altstore.io/altstore-classic/altserver)
- [AltStore 刷新与快捷指令](https://faq.altstore.io/altstore-classic/your-altstore)
- [App ID 与数量限制](https://faq.altstore.io/altstore-classic/app-ids)

## 使用前的重要结论

1. 先用 Xcode 真机安装并验证 HealthKit、后台刷新、配对、首次同步和增量同步。
2. AltServer 安装在长期在线的 Mac mini；编译 IPA 可以在另一台装有 Xcode 的 Mac 完成。
3. AltStore 会重新签名 IPA。HealthKit 和 `com.apple.developer.healthkit.background-delivery` 是否被当前 AltStore 版本完整保留，必须以真机结果为准。AltStore 上游在 2026 年仍有关于“重签时保留 HealthKit capability”的改进讨论，因此本项目把 AltStore 标记为实验性续签路径。
4. 使用与 Xcode 测试时相同的 Apple ID 和 Bundle ID，最有利于保留 Keychain 配置；切换身份后仍应准备重新授权和重新配对。
5. 在 AltStore 版完成全部验证前，不要删除可工作的 Xcode 版，也不要等到现有签名到期才迁移。

## 一、Mac mini 安装 AltServer

1. 从 AltStore 官方网站下载 AltServer for macOS，放入 `/Applications`。
2. 启动 AltServer，并允许“登录时打开”。它是菜单栏 App，当前用户需保持登录。
3. 第一次用 USB 连接并解锁 iPhone，在 Finder 中选择设备，启用“连接 Wi‑Fi 时显示此 iPhone”。
4. 在 AltServer 菜单选择 **Install AltStore → 你的 iPhone**，按提示登录 Apple ID。
5. iPhone 进入“设置 → 通用 → VPN 与设备管理”信任该开发者；iOS 16+ 还需要“设置 → 隐私与安全性 → 开发者模式”。
6. 确保 Mac mini 与 iPhone 在同一可互访局域网，或同步时临时用 USB 连接。

如果 AltStore 自身过期，可以在 AltServer 菜单中直接重新安装覆盖，通常不需要先删除 AltStore。

## 二、构建 IPA

推荐先在 Xcode 的 **Signing & Capabilities** 选择自己的 Team 和唯一 Bundle ID，再运行：

```bash
DEVELOPMENT_TEAM='你的 Team ID' \
BUNDLE_IDENTIFIER='你的唯一 Bundle ID' \
./scripts/build_ios_ipa.zsh
```

输出位于 `build/ipa/HealthTracker.ipa`。IPA、描述文件和构建目录已被 `.gitignore` 排除，不要提交到 GitHub。

也可以在 Xcode 中选择真机目标，执行 **Product → Archive**，再从 Organizer 导出 Development IPA。

## 三、手机使用 AltStore 安装

1. 在 iPhone 打开 AltStore → **My Apps**。
2. 点击左上角 `+`，从“文件”选择 `HealthTracker.ipa`。
3. 完成安装后打开“健康同步”。若系统重新请求健康权限，逐项允许。
4. 检查“设置 → 通用 → 后台 App 刷新”中是否出现并启用“健康同步”。
5. 检查手机 App 是否仍显示已配对、S3/WebDAV 凭据是否存在；缺失时重新配置或重新配对。

## 四、必须完成的验证

- App 能打开并弹出/读取 HealthKit 授权。
- 首页可以完成一次手动增量同步，Receiver 数据库新增记录。
- 锁屏或切换 App 后，后台上传能继续；强制划掉 App 后不作保证。
- iPhone 后台刷新列表仍有“健康同步”。
- Receiver 的设备、序列号、S3 receipt 和面板新鲜度连续。
- AltStore 中 Health Tracker 的到期日能在 AltServer 在线时成功刷新。

任何一项失败，都应回到 Xcode 安装路径；不要把“App 能启动”误判成 HealthKit 后台能力完整。

## 五、保持自动刷新

- Mac mini 启动后保持 AltServer 运行。
- Finder Wi‑Fi 同步保持开启。
- iPhone 和 Mac mini 定期处于同一局域网；不同网络时 AltServer 无法正常发现设备。
- AltStore 设置中启用 Background Refresh，也可使用 AltStore 提供的“Refresh Apps”快捷指令做个人自动化补偿。
- 免费 Apple ID 通常最多同时启用 3 个侧载 App（AltStore 本身也占一个），并受 App ID 数量限制。
- 每隔几天查看一次 AltStore 的剩余天数；自动刷新失败时在同网或 USB 状态下手动 **Refresh All**。
