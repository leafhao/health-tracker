import Foundation

enum CloudStorageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case s3
    case webDAV = "webdav"
    case directDebug = "direct_debug"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .s3: return "S3 兼容存储"
        case .webDAV: return "WebDAV"
        case .directDebug: return "直连接收器（调试）"
        }
    }
}

struct CloudStorageConfig: Codable, Equatable, Sendable {
    var provider: CloudStorageProvider = .s3
    var endpoint = ""
    var region = "us-east-1"
    var bucket = ""
    var prefix = "health-tracker"
    var pathStyle = true
    var retentionDays = 14

    private static let defaultsKey = "personalReceiver.v2.cloudStorageConfig"

    static func load() -> CloudStorageConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(CloudStorageConfig.self, from: data)
        else { return CloudStorageConfig() }
        return config
    }

    func save(credentials: CloudStorageCredentials) throws {
        guard 1...365 ~= retentionDays else { throw CloudStorageError.invalidRetention }
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        try credentials.save(for: provider)
    }

    var normalizedEndpoint: URL? {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let value = raw.contains("://") ? raw : "https://\(raw)"
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    var isConfigured: Bool {
        guard normalizedEndpoint != nil else { return false }
        switch provider {
        case .s3: return !region.isEmpty && !bucket.isEmpty
        case .webDAV, .directDebug: return true
        }
    }

    var usesCSTCloudCompatibility: Bool {
        normalizedEndpoint?.host?.caseInsensitiveCompare("s3.cstcloud.cn") == .orderedSame
    }
}

struct CloudStorageCredentials: Equatable, Sendable {
    var username = ""
    var password = ""
    var accessKey = ""
    var secretKey = ""

    private enum Account {
        static let webDAVUsername = "cloud.webdav.username"
        static let webDAVPassword = "cloud.webdav.password"
        static let s3AccessKey = "cloud.s3.accessKey"
        static let s3SecretKey = "cloud.s3.secretKey"
    }

    static func load(for provider: CloudStorageProvider) -> CloudStorageCredentials {
        var value = CloudStorageCredentials()
        switch provider {
        case .s3:
            value.accessKey = (try? KeychainStore.read(account: Account.s3AccessKey)) ?? ""
            value.secretKey = (try? KeychainStore.read(account: Account.s3SecretKey)) ?? ""
        case .webDAV:
            value.username = (try? KeychainStore.read(account: Account.webDAVUsername)) ?? ""
            value.password = (try? KeychainStore.read(account: Account.webDAVPassword)) ?? ""
        case .directDebug:
            break
        }
        return value
    }

    func save(for provider: CloudStorageProvider) throws {
        switch provider {
        case .s3:
            try KeychainStore.write(accessKey, account: Account.s3AccessKey)
            try KeychainStore.write(secretKey, account: Account.s3SecretKey)
        case .webDAV:
            try KeychainStore.write(username, account: Account.webDAVUsername)
            try KeychainStore.write(password, account: Account.webDAVPassword)
        case .directDebug:
            break
        }
    }

    func isComplete(for provider: CloudStorageProvider) -> Bool {
        switch provider {
        case .s3: return !accessKey.isEmpty && !secretKey.isEmpty
        case .webDAV: return !username.isEmpty && !password.isEmpty
        case .directDebug: return true
        }
    }
}

enum CloudStorageError: Error, LocalizedError {
    case invalidConfiguration
    case invalidRetention
    case missingCredentials
    case invalidResponse
    case http(Int, String)
    case rateLimited(Date)
    case signing(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "云存储配置不完整"
        case .invalidRetention: return "保留天数必须在 1–365 天之间"
        case .missingCredentials: return "云存储凭据不完整"
        case .invalidResponse: return "云存储返回了无效响应"
        case .http(let status, let body): return "云存储 HTTP \(status)：\(body.prefix(300))"
        case .rateLimited(let retryAt):
            return "云存储正在限流，已暂停上传并将在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后自动重试"
        case .signing(let message): return "S3 请求签名失败：\(message)"
        }
    }
}
