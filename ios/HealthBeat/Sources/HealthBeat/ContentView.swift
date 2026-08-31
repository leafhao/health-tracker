import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SyncHomeView(
                openCloudSettings: { selectedTab = 1 },
                openAppSettings: { selectedTab = 2 }
            )
                .tabItem { Label("首页", systemImage: "heart.text.square.fill") }
                .tag(0)
            CloudStorageSettingsView()
                .tabItem { Label("云存储", systemImage: "externaldrive.connected.to.line.below.fill") }
                .tag(1)
            HealthSyncSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(.green)
    }
}

private struct SyncHomeView: View {
    @ObservedObject private var sync = PersonalHealthSyncService.shared
    let openCloudSettings: () -> Void
    let openAppSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if sync.isV2Paired,
                       !sync.isInitialDirectBootstrapComplete,
                       sync.initialDirectTotalBatches > 0 {
                        initialDirectProgressCard
                    } else {
                        queueCards
                    }
                    actionCard
                    backgroundCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("健康同步")
            .refreshable { await sync.refreshCloudStatus() }
        }
    }

    private var initialDirectProgressCard: some View {
        let total = max(sync.initialDirectTotalBatches, 1)
        let fraction = min(
            1,
            max(0, Double(sync.initialDirectCompletedBatches) / Double(total))
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("首次局域网直传", systemImage: "iphone.and.arrow.forward")
                    .font(.headline)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            ProgressView(value: fraction)
                .tint(.green)
            HStack {
                Text("已确认 \(sync.initialDirectCompletedBatches.formatted()) / \(sync.initialDirectTotalBatches.formatted()) 个批次")
                Spacer()
                Text("剩余约 \(sync.initialDirectRemainingPacks) 包")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("保持 App 在前台并连接 Receiver 所在局域网；中断后会从未确认批次继续。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: sync.cloudProviderName == "未配置" ? "icloud.slash" : "icloud.and.arrow.up.fill")
                    .font(.title2)
                    .foregroundStyle(sync.cloudProviderName == "未配置" ? .orange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sync.cloudProviderName).font(.headline)
                    Text(sync.cloudStatusMessage).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(sync.cloudProviderName == "未配置" ? Color.orange : Color.green)
                    .frame(width: 10, height: 10)
            }
            Divider()
            LabeledContent("端到端加密", value: sync.isV2Paired ? "HPKE + Ed25519" : "未配对")
            if let date = sync.lastSyncDate {
                LabeledContent("最近完成", value: date.formatted(date: .abbreviated, time: .shortened))
            } else if !sync.isV2Paired {
                Button(action: openAppSettings) {
                    Label("完成端到端加密配对", systemImage: "key.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                LabeledContent("最近完成", value: "尚无记录")
            }
            LabeledContent("当前状态", value: sync.statusMessage)
        }
        .cardStyle()
    }

    private var queueCards: some View {
        HStack(spacing: 12) {
            queueMetric(
                value: sync.awaitingCloudPacks,
                title: "待上传密文包",
                subtitle: "包含 \(sync.awaitingCloudUpload) 个批次",
                color: .blue,
                icon: "arrow.up.circle.fill"
            )
            queueMetric(value: sync.awaitingReceiver, title: "待确认", subtitle: "已在云端", color: .purple, icon: "checkmark.icloud.fill")
        }
    }

    private func queueMetric(value: Int, title: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(value)").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var actionCard: some View {
        VStack(spacing: 12) {
            if sync.cloudProviderName == "未配置" {
                Button(action: openCloudSettings) {
                    Label("配置云存储", systemImage: "externaldrive.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if !sync.isInitialDirectBootstrapComplete,
                       !sync.isInitialHistoryRangeConfirmed {
                        openAppSettings()
                    } else {
                        Task { await sync.syncIncrementalEncrypted() }
                    }
                } label: {
                    HStack {
                        Label(
                            !sync.isInitialDirectBootstrapComplete
                                ? (sync.isInitialHistoryRangeConfirmed
                                    ? "继续首次局域网直传"
                                    : "设置首次同步范围")
                                : (sync.needsHistoricalBackfill ? "开始首次历史同步" : "立即增量同步"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        Spacer()
                        if sync.isSyncing { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sync.isSyncing || !sync.isV2Paired)
            }
            if let error = sync.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("后台同步已启用", systemImage: "clock.arrow.2.circlepath").font(.headline)
            Text("HealthKit 变化唤醒、系统后台刷新和进入前台三层补漏。iOS 决定具体运行时间，未完成批次始终保留在本机。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

private struct CloudStorageSettingsView: View {
    @ObservedObject private var sync = PersonalHealthSyncService.shared
    @State private var config = CloudStorageConfig.load()
    @State private var credentials = CloudStorageCredentials()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("存储类型") {
                    Picker("协议", selection: $config.provider) {
                        ForEach([CloudStorageProvider.s3, .webDAV]) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: config.provider) { _, provider in
                        credentials = CloudStorageCredentials.load(for: provider)
                    }
                }

                if config.provider == .s3 { s3Section }
                if config.provider == .webDAV { webDAVSection }
                Section("数据保留") {
                    Stepper("已确认密文保留 \(config.retentionDays) 天", value: $config.retentionDays, in: 1...365)
                    Text("该值会交给后续的 Receiver 云端清理任务使用。尚未收到可信回执的密文不会仅因到期而删除，避免电脑离线时丢数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await sync.saveAndTestCloud(config: config, credentials: credentials) }
                    } label: {
                        HStack {
                            Text("保存并测试连接")
                            Spacer()
                            if sync.isTestingCloud { ProgressView() }
                        }
                    }
                    .disabled(sync.isTestingCloud || validationIssue != nil)
                    if let validationIssue {
                        Label(validationIssue, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("状态", value: sync.cloudStatusMessage)
                    if let error = sync.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("云存储")
            .onAppear {
                guard !loaded else { return }
                loaded = true
                config = CloudStorageConfig.load()
                if config.provider == .directDebug {
                    config.provider = .s3
                }
                credentials = CloudStorageCredentials.load(for: config.provider)
            }
        }
    }

    private var s3Section: some View {
        Section("S3 兼容存储") {
            TextField("Endpoint，例如 s3.example.com", text: $config.endpoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Region", text: $config.region).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Bucket", text: $config.bucket).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("目录前缀", text: $config.prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Access Key", text: $credentials.accessKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Secret Key", text: $credentials.secretKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Path-style 地址", isOn: $config.pathStyle)
            if config.usesCSTCloudCompatibility {
                Label("已自动启用数据胶囊 Rclone 兼容模式", systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            Text("适用于数据胶囊、MinIO、Cloudflare R2 和多数 S3 兼容服务。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var webDAVSection: some View {
        Section("WebDAV") {
            TextField("WebDAV 目录 URL", text: $config.endpoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("目录前缀", text: $config.prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("用户名", text: $credentials.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("密码 / App Password", text: $credentials.password)
        }
    }

    private var validationIssue: String? {
        guard config.normalizedEndpoint != nil else { return "请填写有效的 Endpoint" }
        switch config.provider {
        case .s3:
            if config.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 Region" }
            if config.bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 Bucket" }
            if credentials.accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 Access Key" }
            if credentials.secretKey.isEmpty { return "请填写 Secret Key" }
        case .webDAV:
            if credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写用户名" }
            if credentials.password.isEmpty { return "请填写密码或 App Password" }
        case .directDebug:
            return "直连仅在高级调试中配置"
        }
        return nil
    }

}

private struct HealthSyncSettingsView: View {
    @ObservedObject private var sync = PersonalHealthSyncService.shared
    @StateObject private var discovery = NearbyReceiverDiscovery()
    @State private var localURL = ""
    @State private var remoteURL = ""
    @State private var pairingCode = ""
    @State private var loaded = false
    @State private var showManualPairing = false
    @State private var showReceiverSearch = false
    @State private var showInitialSyncSetup = false

    private var needsInitialSync: Bool {
        !sync.isInitialDirectBootstrapComplete || sync.needsHistoricalBackfill
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("健康权限") {
                    Text("只读取睡眠、锻炼、心率、活动、身体成分、VO₂ Max 和跑步专项指标，不会写入健康数据。App 更新后请点一次下方按钮，以授权新增的数据类型。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("申请或更新读取权限") { Task { await sync.requestHealthAuthorization() } }
                }

                Section("数据同步") {
                    if needsInitialSync && sync.initialDirectTotalBatches == 0 {
                        Label("首次同步前请确认历史范围", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("历史范围越长，HealthKit 原始样本越多。建议先同步最近一年；首次完成后只传增量数据。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Picker(
                        "首次历史范围",
                        selection: Binding(
                            get: { sync.initialHistoryRange },
                            set: { sync.setInitialHistoryRange($0) }
                        )
                    ) {
                        ForEach(InitialHistoryRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .disabled(
                        sync.isSyncing
                            || (!sync.isInitialDirectBootstrapComplete
                                && sync.initialDirectTotalBatches > 0)
                    )
                    Text(sync.initialHistoryRange.workloadDescription)
                        .font(.footnote)
                        .foregroundStyle(sync.initialHistoryRange == .all ? .orange : .secondary)
                    LabeledContent("历史回溯", value: sync.historicalSyncMessage)
                    LabeledContent("后续同步", value: "仅传增量变更")
                    Button(needsInitialSync ? "开始或继续首次同步" : "所选历史范围已覆盖") {
                        if sync.initialDirectTotalBatches == 0
                            || sync.isInitialDirectBootstrapComplete {
                            showInitialSyncSetup = true
                        } else {
                            Task { await sync.syncIncrementalEncrypted(allowHistoricalBackfill: true) }
                        }
                    }
                    .disabled(sync.isSyncing || !sync.isV2Paired || !needsInitialSync)
                    if !sync.isInitialDirectBootstrapComplete,
                       sync.initialDirectTotalBatches > 0 {
                        ProgressView(
                            value: Double(sync.initialDirectCompletedBatches),
                            total: Double(max(sync.initialDirectTotalBatches, 1))
                        )
                        LabeledContent(
                            "首次直传",
                            value: "\(sync.initialDirectCompletedBatches) / \(sync.initialDirectTotalBatches) 批次"
                        )
                    }
                    Text("历史批次生成期间会锁定范围，避免中途修改。完成后可以继续扩展到更早范围；已覆盖月份不会重复入库。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("后台增量同步由 HealthKit 变化唤醒、系统后台刷新和进入前台补漏共同完成。iOS 决定实际运行时机，因此这些机制不是可精确调整的定时配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("状态", value: sync.isV2Paired ? "已配对" : "未配对")
                    LabeledContent("协议", value: "HPKE + Ed25519")
                    if sync.isV2Paired && !showReceiverSearch {
                        HStack {
                            Label("已配对 Receiver", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("更换或重新配对") {
                                showReceiverSearch = true
                                discovery.start()
                            }
                        }
                        LabeledContent("配对状态", value: sync.receiverStatusMessage)
                    } else if discovery.receivers.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("附近 Receiver")
                                Text(discovery.isSearching ? "正在局域网中自动发现…" : "暂未发现")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if discovery.isSearching {
                                ProgressView()
                            } else {
                                Button("重新搜索") { discovery.start() }
                            }
                        }
                    } else {
                        ForEach(discovery.receivers) { receiver in
                            Button {
                                Task {
                                    await sync.pairNearby(receiver)
                                    if sync.isV2Paired {
                                        showReceiverSearch = false
                                        discovery.stop()
                                    }
                                }
                            } label: {
                                HStack {
                                    Label(receiver.name, systemImage: "desktopcomputer.and.macbook")
                                    Spacer()
                                    Text(sync.isV2Paired ? "重新配对" : "请求配对")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(sync.isSyncing)
                        }
                        Button("重新搜索附近 Receiver") { discovery.start() }
                            .disabled(sync.isSyncing)
                    }
                    if !sync.isV2Paired || showReceiverSearch {
                        LabeledContent("配对进度", value: sync.receiverStatusMessage)
                        Text("点击附近 Receiver 后，请回到 Receiver 本机管理页确认一次。成功后日常同步只经过云存储，不再依赖局域网或 Tailscale。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let discoveryError = discovery.errorMessage {
                        Text(discoveryError).font(.footnote).foregroundStyle(.orange)
                    }
                    DisclosureGroup("无法自动发现？使用手动配对", isExpanded: $showManualPairing) {
                        TextField("局域网 URL", text: $localURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("备用 URL", text: $remoteURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("一次性配对码（XXXX-XXXX-XXXX）", text: $pairingCode)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("保存并完成安全配对") {
                            Task { await sync.saveAndPair(localURL: localURL, remoteURL: remoteURL, pairingCode: pairingCode) }
                        }
                        LabeledContent("连接状态", value: sync.receiverStatusMessage)
                        Text("配对码来自 Receiver 管理网页，不是管理员密码、SHA-256、S3 Access Key 或 Secret。配对成功后 App 会自动删除它。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("这里只用于首次密钥配对和故障排查，不参与之后的 S3 日常同步。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = sync.errorMessage, !sync.isV2Paired {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                } header: {
                    Text("端到端加密")
                } footer: {
                    Text("Bonjour 只用于首次发现设备，不携带密钥或健康数据；真正授权由 Receiver 本机确认。")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showInitialSyncSetup) {
                InitialSyncSetupView(sync: sync)
            }
            .onChange(of: sync.isV2Paired) { wasPaired, isPaired in
                if !wasPaired,
                   isPaired,
                   needsInitialSync,
                   sync.initialDirectTotalBatches == 0 {
                    showInitialSyncSetup = true
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let receiver = sync.currentConfig
                localURL = receiver.localURL
                remoteURL = receiver.remoteURL
                pairingCode = receiver.pairingCode
                showManualPairing = false
                showReceiverSearch = !sync.isV2Paired
                if showReceiverSearch {
                    discovery.start()
                }
            }
            .onDisappear { discovery.stop() }
        }
    }
}

private struct InitialSyncSetupView: View {
    @ObservedObject var sync: PersonalHealthSyncService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("首次同步可能耗时较长", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("手机会读取所选范围内的睡眠、锻炼、心率、活动和跑步指标，通过当前局域网安全传给 Receiver。历史越长，原始样本和处理时间越多。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("选择历史范围") {
                    Picker(
                        "首次历史范围",
                        selection: Binding(
                            get: { sync.initialHistoryRange },
                            set: { sync.setInitialHistoryRange($0) }
                        )
                    ) {
                        ForEach(InitialHistoryRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(sync.initialHistoryRange.workloadDescription)
                        .font(.footnote)
                        .foregroundStyle(sync.initialHistoryRange == .all ? .orange : .secondary)
                }

                Section {
                    Button {
                        dismiss()
                        Task {
                            await sync.startConfirmedInitialSync()
                        }
                    } label: {
                        Label(
                            "开始同步：\(sync.initialHistoryRange.displayName)",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sync.isSyncing || !sync.isV2Paired)

                    Button("稍后再同步", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("数据在局域网中仍采用端到端加密。首次同步完成后，后续只同步新增和变更记录。")
                }
            }
            .navigationTitle("首次同步")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
