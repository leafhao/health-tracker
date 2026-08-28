import Combine
import CryptoKit
import Foundation
import UIKit

struct NearbyReceiver: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: URL
}

@MainActor
final class NearbyReceiverDiscovery: NSObject, ObservableObject {
    @Published private(set) var receivers: [NearbyReceiver] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]

    func start() {
        stop()
        receivers = []
        errorMessage = nil
        isSearching = true
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_healthtracker._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser = nil
        services.values.forEach { $0.stop() }
        services.removeAll()
        isSearching = false
    }

    private func resolved(_ service: NetService) {
        guard let rawHost = service.hostName, service.port > 0 else { return }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = service.port
        guard let url = components.url else { return }
        UserDefaults.standard.set(
            url.absoluteString,
            forKey: HealthV2PairingService.lastNearbyBaseURLDefaultsKey
        )
        let receiver = NearbyReceiver(
            id: "\(service.name)|\(host)|\(service.port)",
            name: service.name,
            baseURL: url
        )
        receivers.removeAll { $0.id == receiver.id }
        receivers.append(receiver)
        receivers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension NearbyReceiverDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in self.isSearching = true }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in self.isSearching = false }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor in
            self.isSearching = false
            self.errorMessage = "无法搜索局域网 Receiver（\(errorDict)）"
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            self.services[ObjectIdentifier(service)] = service
            service.delegate = self
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            self.services.removeValue(forKey: ObjectIdentifier(service))
            self.receivers.removeAll { $0.name == service.name }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in self.resolved(sender) }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        Task { @MainActor in
            self.services.removeValue(forKey: ObjectIdentifier(sender))
            if self.receivers.isEmpty {
                self.errorMessage = "发现了 Receiver，但无法解析其局域网地址"
            }
        }
    }
}

private struct ReceiverIdentityResponse: Decodable {
    let ownerID: String
    let receiverKeyID: String
    let receiverPublicKeyBase64: String

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case receiverKeyID = "receiver_key_id"
        case receiverPublicKeyBase64 = "receiver_public_key_base64"
    }
}

private struct DeviceRegistrationRequest: Encodable {
    let ownerID: String
    let deviceID: String
    let displayName: String
    let signingKeyID: String
    let signingPublicKeyBase64: String

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case deviceID = "device_id"
        case displayName = "display_name"
        case signingKeyID = "signing_key_id"
        case signingPublicKeyBase64 = "signing_public_key_base64"
    }
}

private struct PersistedPairing: Codable {
    let ownerID: String
    let deviceID: String
    let receiverKeyID: String
    let receiverPublicKeyBase64: String
    let signingKeyID: String
    let receiverBaseURL: String?
}

private struct LocalPairingStartResponse: Decodable {
    let requestID: String
    let pollToken: String
    let status: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case pollToken = "poll_token"
        case status
        case expiresAt = "expires_at"
    }
}

private struct LocalPairingStatusResponse: Decodable {
    let status: String
}

private struct CloudBootstrapPayload: Encodable {
    let `protocol`: String
    let ownerID: String
    let deviceID: String
    let provider: String
    let endpoint: String
    let region: String
    let bucket: String
    let prefix: String
    let pathStyle: Bool
    let retentionDays: Int
    let accessKey: String
    let secretKey: String
    let receiptHMACKeyBase64: String
    let configuredAt: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case `protocol`, provider, endpoint, region, bucket, prefix, nonce
        case ownerID = "owner_id"
        case deviceID = "device_id"
        case pathStyle = "path_style"
        case retentionDays = "retention_days"
        case accessKey = "access_key"
        case secretKey = "secret_key"
        case receiptHMACKeyBase64 = "receipt_hmac_key_base64"
        case configuredAt = "configured_at"
    }
}

enum HealthV2PairingError: Error, LocalizedError {
    case noEndpoint
    case invalidIdentity
    case invalidResponse
    case http(Int, String)
    case rejected
    case expired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noEndpoint: return "没有可连接的接收端地址"
        case .invalidIdentity: return "接收端返回的加密公钥无效"
        case .invalidResponse: return "接收端返回了无效的配对响应"
        case .http(let status, let body): return "配对失败 HTTP \(status)：\(body.prefix(300))"
        case .rejected: return "Receiver 已拒绝这次配对请求"
        case .expired: return "配对请求已过期，请重新发起"
        case .unavailable: return "尚未完成加密同步配对"
        }
    }
}

@available(iOS 17.0, *)
actor HealthV2PairingService {
    static let shared = HealthV2PairingService()
    static let lastNearbyBaseURLDefaultsKey = "personalReceiver.v2.lastNearbyBaseURL"

    private let pairingDefaultsKey = "personalReceiver.v2.pairing"
    private let deviceIDDefaultsKey = "personalReceiver.v2.deviceID"
    private let signingPrivateKeyAccount = "healthV2DeviceSigningPrivateKey"
    private let receiptHMACKeyAccount = "healthV2CloudReceiptHMACKey"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func pair(config: ReceiverConfig) async throws -> HealthPairingMaterial {
        guard !config.baseURLs.isEmpty else { throw HealthV2PairingError.noEndpoint }
        var lastError: Error = HealthV2PairingError.noEndpoint
        for baseURL in config.baseURLs {
            do {
                return try await pair(baseURL: baseURL, pairingCode: config.pairingCode)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func pairNearby(
        baseURL: URL,
        statusChanged: @escaping @Sendable (String) async -> Void
    ) async throws -> HealthPairingMaterial {
        let receiver = try await fetchIdentity(baseURL: baseURL)
        let (registration, signingKeyID) = try await deviceRegistration(receiver: receiver)
        var startRequest = URLRequest(url: baseURL.appending(path: "api/v2/pairing/requests"))
        startRequest.httpMethod = "POST"
        startRequest.httpBody = try JSONEncoder().encode(registration)
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (startData, startResponse) = try await session.data(for: startRequest)
        try Self.requireSuccess(startResponse, data: startData)
        let started = try JSONDecoder().decode(LocalPairingStartResponse.self, from: startData)
        guard started.status == "pending" else { throw HealthV2PairingError.invalidResponse }
        await statusChanged("已发送请求，请在 Receiver 面板点击“允许配对”")

        for _ in 0..<300 {
            try Task.checkCancellation()
            var poll = URLRequest(
                url: baseURL.appending(path: "api/v2/pairing/requests/\(started.requestID)")
            )
            poll.timeoutInterval = 10
            poll.setValue(started.pollToken, forHTTPHeaderField: "X-Health-Pairing-Poll-Token")
            let (data, response) = try await session.data(for: poll)
            try Self.requireSuccess(response, data: data)
            switch try JSONDecoder().decode(LocalPairingStatusResponse.self, from: data).status {
            case "approved":
                return try persist(
                    receiver: receiver,
                    signingKeyID: signingKeyID,
                    baseURL: baseURL
                )
            case "rejected", "superseded":
                throw HealthV2PairingError.rejected
            case "expired":
                throw HealthV2PairingError.expired
            case "pending":
                try await Task.sleep(for: .seconds(2))
            default:
                throw HealthV2PairingError.invalidResponse
            }
        }
        throw HealthV2PairingError.expired
    }

    func load() throws -> (material: HealthPairingMaterial, signingPrivateKey: Data) {
        guard let data = UserDefaults.standard.data(forKey: pairingDefaultsKey),
              let persisted = try? JSONDecoder().decode(PersistedPairing.self, from: data),
              let receiverPublicKey = Data(base64Encoded: persisted.receiverPublicKeyBase64),
              let privateKey = Data(base64Encoded: try KeychainStore.read(account: signingPrivateKeyAccount))
        else { throw HealthV2PairingError.unavailable }
        return (
            HealthPairingMaterial(
                ownerID: persisted.ownerID,
                deviceID: persisted.deviceID,
                receiverKeyID: persisted.receiverKeyID,
                receiverPublicKey: receiverPublicKey,
                signingKeyID: persisted.signingKeyID
            ),
            privateKey
        )
    }

    var isPaired: Bool {
        (try? load()) != nil
    }

    func receiptHMACKey() throws -> Data {
        if let encoded = try? KeychainStore.read(account: receiptHMACKeyAccount),
           let existing = Data(base64Encoded: encoded), existing.count == 32 {
            return existing
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try KeychainStore.write(key.base64EncodedString(), account: receiptHMACKeyAccount)
        return key
    }

    func provisionCloudStorage(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        fallback: ReceiverConfig
    ) async throws {
        guard config.provider == .s3,
              let endpoint = config.normalizedEndpoint,
              config.isConfigured,
              credentials.isComplete(for: .s3) else {
            throw CloudStorageError.invalidConfiguration
        }
        let loaded = try load()
        let now = ISO8601DateFormatter.incrementalHealth.string(from: Date())
        let payload = CloudBootstrapPayload(
            protocol: "health-cloud-bootstrap/1",
            ownerID: loaded.material.ownerID,
            deviceID: loaded.material.deviceID,
            provider: "s3",
            endpoint: endpoint.absoluteString,
            region: config.region,
            bucket: config.bucket,
            prefix: config.prefix,
            pathStyle: config.pathStyle,
            retentionDays: config.retentionDays,
            accessKey: credentials.accessKey,
            secretKey: credentials.secretKey,
            receiptHMACKeyBase64: try receiptHMACKey().base64EncodedString(),
            configuredAt: now,
            nonce: UUID().uuidString.lowercased()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        let header = HealthSyncEnvelopeHeader(
            protocol: "health-envelope/1",
            batchID: "cloud-bootstrap-" + UUID().uuidString.lowercased(),
            deviceID: loaded.material.deviceID,
            sequence: 1,
            receiverKeyID: loaded.material.receiverKeyID,
            signingKeyID: loaded.material.signingKeyID,
            createdAt: now,
            contentType: "application/vnd.health-cloud-bootstrap+json;v=1",
            contentEncoding: "identity",
            plaintextSize: payloadData.count,
            paddingSize: (4_096 - payloadData.count % 4_096) % 4_096
        )
        let envelope = try HealthSyncEnvelopeSealer.seal(
            payload: payloadData,
            header: header,
            receiverPublicKey: loaded.material.receiverPublicKey,
            deviceSigningPrivateKey: loaded.signingPrivateKey
        )
        let body = try encoder.encode(envelope)
        let urls = directReceiverBaseURLs(fallback: fallback)
        guard !urls.isEmpty else { throw HealthV2PairingError.noEndpoint }
        var lastError: Error = HealthV2PairingError.noEndpoint
        for baseURL in urls {
            do {
                var request = URLRequest(url: baseURL.appending(path: "api/v2/cloud/bootstrap"))
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await session.data(for: request)
                try Self.requireSuccess(response, data: data)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func directReceiverBaseURLs(fallback: ReceiverConfig) -> [URL] {
        var urls: [URL] = []
        if let data = UserDefaults.standard.data(forKey: pairingDefaultsKey),
           let persisted = try? JSONDecoder().decode(PersistedPairing.self, from: data),
           let raw = persisted.receiverBaseURL,
           let url = URL(string: raw) {
            urls.append(url)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.lastNearbyBaseURLDefaultsKey),
           let url = URL(string: raw),
           !urls.contains(url) {
            urls.append(url)
        }
        for url in fallback.baseURLs where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }

    private func pair(baseURL: URL, pairingCode: String) async throws -> HealthPairingMaterial {
        let receiver = try await fetchIdentity(baseURL: baseURL)
        let (registration, signingKeyID) = try await deviceRegistration(receiver: receiver)
        var request = URLRequest(url: baseURL.appending(path: "api/v2/pairing/devices"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(registration)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pairingCode, forHTTPHeaderField: "X-Health-Pairing-Code")
        let (responseData, response) = try await session.data(for: request)
        try Self.requireSuccess(response, data: responseData)
        return try persist(
            receiver: receiver,
            signingKeyID: signingKeyID,
            baseURL: baseURL
        )
    }

    private func fetchIdentity(baseURL: URL) async throws -> ReceiverIdentityResponse {
        let identityURL = baseURL.appending(path: "api/v2/system/identity")
        let (identityData, identityResponse) = try await session.data(from: identityURL)
        try Self.requireSuccess(identityResponse, data: identityData)
        let receiver = try JSONDecoder().decode(ReceiverIdentityResponse.self, from: identityData)
        guard let receiverPublicKey = Data(base64Encoded: receiver.receiverPublicKeyBase64),
              receiverPublicKey.count == 32 else { throw HealthV2PairingError.invalidIdentity }
        return receiver
    }

    private func deviceRegistration(
        receiver: ReceiverIdentityResponse
    ) async throws -> (DeviceRegistrationRequest, String) {
        let signingKey: Curve25519.Signing.PrivateKey
        if let existing = try? KeychainStore.read(account: signingPrivateKeyAccount),
           let raw = Data(base64Encoded: existing),
           let restored = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            signingKey = restored
        } else {
            signingKey = Curve25519.Signing.PrivateKey()
            try KeychainStore.write(
                signingKey.rawRepresentation.base64EncodedString(),
                account: signingPrivateKeyAccount
            )
        }
        let publicKey = signingKey.publicKey.rawRepresentation
        let signingKeyID = "iphone-" + String(Self.hexDigest(publicKey).prefix(16))
        let deviceID = stableDeviceID()
        let displayName = await MainActor.run { UIDevice.current.name }
        let registration = DeviceRegistrationRequest(
            ownerID: receiver.ownerID,
            deviceID: deviceID,
            displayName: displayName,
            signingKeyID: signingKeyID,
            signingPublicKeyBase64: publicKey.base64EncodedString()
        )
        return (registration, signingKeyID)
    }

    private func persist(
        receiver: ReceiverIdentityResponse,
        signingKeyID: String,
        baseURL: URL
    ) throws -> HealthPairingMaterial {
        guard let receiverPublicKey = Data(base64Encoded: receiver.receiverPublicKeyBase64),
              receiverPublicKey.count == 32 else { throw HealthV2PairingError.invalidIdentity }
        let persisted = PersistedPairing(
            ownerID: receiver.ownerID,
            deviceID: stableDeviceID(),
            receiverKeyID: receiver.receiverKeyID,
            receiverPublicKeyBase64: receiver.receiverPublicKeyBase64,
            signingKeyID: signingKeyID,
            receiverBaseURL: baseURL.absoluteString
        )
        UserDefaults.standard.set(try JSONEncoder().encode(persisted), forKey: pairingDefaultsKey)
        return HealthPairingMaterial(
            ownerID: persisted.ownerID,
            deviceID: persisted.deviceID,
            receiverKeyID: persisted.receiverKeyID,
            receiverPublicKey: receiverPublicKey,
            signingKeyID: persisted.signingKeyID
        )
    }

    private func stableDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDDefaultsKey) {
            return existing
        }
        let value = "device-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: deviceIDDefaultsKey)
        return value
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw HealthV2PairingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HealthV2PairingError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
