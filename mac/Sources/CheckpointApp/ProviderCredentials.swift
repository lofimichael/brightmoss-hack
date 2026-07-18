import Foundation
import Security

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case brightData
    case moss
    case liveKit
    case openAI

    var id: String { rawValue }

    var name: String {
        switch self {
        case .brightData: return "Bright Data"
        case .moss: return "Moss"
        case .liveKit: return "LiveKit"
        case .openAI: return "OpenAI"
        }
    }

    var purpose: String {
        switch self {
        case .brightData: return "Adds fresh public context"
        case .moss: return "Adds local semantic retrieval"
        case .liveKit: return "Adds Cloud voice and remote rooms"
        case .openAI: return "Optional cloud reasoning"
        }
    }

    var officialURL: URL {
        switch self {
        case .brightData: return URL(string: "https://brightdata.com/cp/setting/users")!
        case .moss: return URL(string: "https://portal.usemoss.dev")!
        case .liveKit: return URL(string: "https://cloud.livekit.io")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var fields: [ProviderCredentialField] {
        switch self {
        case .brightData: return [.brightDataAPIKey]
        case .moss: return [.mossProjectID, .mossProjectKey]
        case .liveKit:
            return [
                .liveKitSandboxID, .liveKitAgentName, .liveKitURL,
                .liveKitAPIKey, .liveKitAPISecret,
            ]
        case .openAI: return [.openAIAPIKey]
        }
    }

    var connectionLabel: String {
        switch self {
        case .brightData, .openAI: return "API key"
        case .moss: return "Moss connection"
        case .liveKit: return "LiveKit connection"
        }
    }

    var connectionPlaceholder: String {
        switch self {
        case .brightData, .openAI: return "Paste API key"
        case .moss: return "Paste .env pair or Moss CLI profile JSON"
        case .liveKit: return "Paste token-server ID or exported .env block"
        }
    }

    var connectionGuidance: String {
        switch self {
        case .brightData:
            return "One key. Used only after you allow public enrichment."
        case .moss:
            return "Moss requires both Project ID and Project Key. Paste the two-line .env pair or CLI profile JSON once; CHECKPOINT separates and saves them securely."
        case .liveKit:
            return "For the hackathon frontend, paste the token-server ID; the agent name defaults to checkpoint. A Cloud worker can instead use one exported LIVEKIT_URL/API_KEY/API_SECRET block."
        case .openAI:
            return "One key. Optional; local Apple understanding remains the default."
        }
    }
}

enum ProviderCredentialField: String, CaseIterable, Sendable {
    case brightDataAPIKey = "bright_data_api_key"
    case mossProjectID = "moss_project_id"
    case mossProjectKey = "moss_project_key"
    case openAIAPIKey = "openai_api_key"
    case liveKitURL = "livekit_url"
    case liveKitAPIKey = "livekit_api_key"
    case liveKitAPISecret = "livekit_api_secret"
    case liveKitSandboxID = "livekit_sandbox_id"
    case liveKitAgentName = "livekit_agent_name"

    var label: String {
        switch self {
        case .brightDataAPIKey: return "API key"
        case .mossProjectID: return "Project ID"
        case .mossProjectKey: return "Project key"
        case .openAIAPIKey: return "API key"
        case .liveKitURL: return "Server URL"
        case .liveKitAPIKey: return "API key"
        case .liveKitAPISecret: return "API secret"
        case .liveKitSandboxID: return "Sandbox ID"
        case .liveKitAgentName: return "Agent name"
        }
    }

    var isLiveKitAdvanced: Bool {
        switch self {
        case .liveKitURL, .liveKitAPIKey, .liveKitAPISecret: return true
        default: return false
        }
    }
}

enum CredentialStoreError: LocalizedError {
    case unreadable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The saved connection could not be read."
        case .keychain:
            return "The connection could not be saved securely."
        }
    }
}

protocol CredentialStoring: Sendable {
    func value(for field: ProviderCredentialField) throws -> String?
    func set(_ value: String, for field: ProviderCredentialField) throws
    func remove(_ field: ProviderCredentialField) throws
}

final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let service: String

    init(service: String = "app.checkpoint.provider-credentials") {
        self.service = service
    }

    func value(for field: ProviderCredentialField) throws -> String? {
        var query = baseQuery(field)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.unreadable
        }
        return value
    }

    func set(_ value: String, for field: ProviderCredentialField) throws {
        let data = Data(value.utf8)
        let query = baseQuery(field)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    func remove(_ field: ProviderCredentialField) throws {
        let status = SecItemDelete(baseQuery(field) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(_ field: ProviderCredentialField) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field.rawValue,
        ]
    }
}

final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderCredentialField: String] = [:]

    func value(for field: ProviderCredentialField) throws -> String? {
        lock.withLock { values[field] }
    }

    func set(_ value: String, for field: ProviderCredentialField) throws {
        lock.withLock { values[field] = value }
    }

    func remove(_ field: ProviderCredentialField) throws {
        _ = lock.withLock { values.removeValue(forKey: field) }
    }
}

struct ProviderCredentials: Codable, Equatable, Sendable {
    var brightDataAPIKey: String?
    var mossProjectID: String?
    var mossProjectKey: String?
    var openAIAPIKey: String?
    var liveKitURL: String?
    var liveKitAPIKey: String?
    var liveKitAPISecret: String?
    var liveKitSandboxID: String?
    var liveKitAgentName: String?

    enum CodingKeys: String, CodingKey {
        case brightDataAPIKey = "bright_data_api_key"
        case mossProjectID = "moss_project_id"
        case mossProjectKey = "moss_project_key"
        case openAIAPIKey = "openai_api_key"
        case liveKitURL = "livekit_url"
        case liveKitAPIKey = "livekit_api_key"
        case liveKitAPISecret = "livekit_api_secret"
        case liveKitSandboxID = "livekit_sandbox_id"
        case liveKitAgentName = "livekit_agent_name"
    }

    init(store: CredentialStoring) throws {
        brightDataAPIKey = try store.value(for: .brightDataAPIKey)
        mossProjectID = try store.value(for: .mossProjectID)
        mossProjectKey = try store.value(for: .mossProjectKey)
        openAIAPIKey = try store.value(for: .openAIAPIKey)
        liveKitURL = try store.value(for: .liveKitURL)
        liveKitAPIKey = try store.value(for: .liveKitAPIKey)
        liveKitAPISecret = try store.value(for: .liveKitAPISecret)
        liveKitSandboxID = try store.value(for: .liveKitSandboxID)
        liveKitAgentName = try store.value(for: .liveKitAgentName)
    }

    init(
        brightDataAPIKey: String? = nil,
        mossProjectID: String? = nil,
        mossProjectKey: String? = nil,
        openAIAPIKey: String? = nil,
        liveKitURL: String? = nil,
        liveKitAPIKey: String? = nil,
        liveKitAPISecret: String? = nil,
        liveKitSandboxID: String? = nil,
        liveKitAgentName: String? = nil
    ) {
        self.brightDataAPIKey = brightDataAPIKey
        self.mossProjectID = mossProjectID
        self.mossProjectKey = mossProjectKey
        self.openAIAPIKey = openAIAPIKey
        self.liveKitURL = liveKitURL
        self.liveKitAPIKey = liveKitAPIKey
        self.liveKitAPISecret = liveKitAPISecret
        self.liveKitSandboxID = liveKitSandboxID
        self.liveKitAgentName = liveKitAgentName
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(brightDataAPIKey, forKey: .brightDataAPIKey)
        try values.encode(mossProjectID, forKey: .mossProjectID)
        try values.encode(mossProjectKey, forKey: .mossProjectKey)
        try values.encode(openAIAPIKey, forKey: .openAIAPIKey)
        try values.encode(liveKitURL, forKey: .liveKitURL)
        try values.encode(liveKitAPIKey, forKey: .liveKitAPIKey)
        try values.encode(liveKitAPISecret, forKey: .liveKitAPISecret)
        try values.encode(liveKitSandboxID, forKey: .liveKitSandboxID)
        try values.encode(liveKitAgentName, forKey: .liveKitAgentName)
    }
}

struct ProviderConfigurationResponse: Codable, Equatable, Sendable {
    // Current helper capability response. Values are intentionally status
    // labels rather than credential echoes.
    var brightData: String?
    var brightDataMode: String?
    var moss: String?
    var planner: String?
    var voice: String?
    var localRetrieval: Bool?

    // Kept optional for compatibility with an earlier helper/test fixture.
    var status: String?
    var brightDataConfigured: Bool?
    var mossConfigured: Bool?
    var liveKitConfigured: Bool?
    var openAIConfigured: Bool?

    enum CodingKeys: String, CodingKey {
        case brightData = "bright_data"
        case brightDataMode = "bright_data_mode"
        case moss
        case planner
        case voice
        case localRetrieval = "local_retrieval"
        case status
        case brightDataConfigured = "bright_data_configured"
        case mossConfigured = "moss_configured"
        case liveKitConfigured = "livekit_configured"
        case openAIConfigured = "openai_configured"
    }
}

struct ProviderDraft: Equatable, Sendable {
    var connectionCode = ""
    var values: [ProviderCredentialField: String] = [:]

    subscript(field: ProviderCredentialField) -> String {
        get { values[field, default: ""] }
        set { values[field] = newValue }
    }
}

enum ProviderSetupError: LocalizedError, Equatable {
    case invalidMossConnection
    case mossProjectIDRequired
    case invalidLiveKitConnection

    var errorDescription: String? {
        switch self {
        case .invalidMossConnection:
            return "That Moss connection could not be read. Paste both MOSS_PROJECT_ID and MOSS_PROJECT_KEY, or a Moss CLI profile."
        case .mossProjectIDRequired:
            return "Moss also requires the Project ID. Paste it together with the key; CHECKPOINT cannot derive it from the key."
        case .invalidLiveKitConnection:
            return "That LiveKit connection could not be read. Paste a token-server ID or the exported LIVEKIT_URL, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET block."
        }
    }
}

private struct MossConnection {
    let projectID: String
    let projectKey: String

    static func parse(_ raw: String, existingProjectID: String?) throws -> MossConnection {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 8_192 else {
            throw ProviderSetupError.invalidMossConnection
        }

        if let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)),
           let pair = pair(in: object, depth: 0) {
            return MossConnection(projectID: pair.0, projectKey: pair.1)
        }

        let values = dotenvValues(input)
        if let projectID = firstValue(in: values, keys: ["MOSS_PROJECT_ID", "PROJECT_ID"]),
           let projectKey = firstValue(in: values, keys: ["MOSS_PROJECT_KEY", "PROJECT_KEY"]) {
            return MossConnection(projectID: projectID, projectKey: projectKey)
        }

        // A raw project key is valid only when an operator or earlier setup has
        // already provisioned its independent project ID. Moss does not encode
        // or expose a supported way to infer the ID from the key.
        if let existingProjectID = normalized(existingProjectID),
           !input.contains("=") && !input.contains("\n") && !input.hasPrefix("{") {
            return MossConnection(projectID: existingProjectID, projectKey: input)
        }

        if !input.contains("=") && !input.contains("\n") && !input.hasPrefix("{") {
            throw ProviderSetupError.mossProjectIDRequired
        }
        throw ProviderSetupError.invalidMossConnection
    }

    private static func pair(in object: Any, depth: Int) -> (String, String)? {
        guard depth <= 8, let dictionary = object as? [String: Any] else { return nil }
        var normalizedDictionary: [String: Any] = [:]
        for (key, value) in dictionary where normalizedDictionary[key.lowercased()] == nil {
            normalizedDictionary[key.lowercased()] = value
        }
        let idKeys = ["project_id", "projectid", "moss_project_id"]
        let keyKeys = ["project_key", "projectkey", "moss_project_key"]
        let projectID = idKeys.compactMap { normalized(normalizedDictionary[$0] as? String) }.first
        let projectKey = keyKeys.compactMap { normalized(normalizedDictionary[$0] as? String) }.first
        if let projectID, let projectKey { return (projectID, projectKey) }

        for value in dictionary.values {
            if let nested = pair(in: value, depth: depth + 1) { return nested }
        }
        return nil
    }
}

private struct LiveKitConnection {
    let sandboxID: String?
    let agentName: String
    let url: String?
    let apiKey: String?
    let apiSecret: String?

    static func parse(_ raw: String) throws -> LiveKitConnection {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 16_384 else {
            throw ProviderSetupError.invalidLiveKitConnection
        }

        var values = dotenvValues(input)
        if let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)),
           let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if let value = value as? String { values[key.uppercased()] = value }
            }
        }

        let sandboxID = firstValue(in: values, keys: ["LIVEKIT_SANDBOX_ID", "LIVEKIT_TOKEN_SERVER_ID", "SANDBOX_ID"])
        let agentName = firstValue(in: values, keys: ["LIVEKIT_AGENT_NAME", "AGENT_NAME"]) ?? "checkpoint"
        let url = firstValue(in: values, keys: ["LIVEKIT_URL", "URL"])
        let apiKey = firstValue(in: values, keys: ["LIVEKIT_API_KEY", "API_KEY"])
        let apiSecret = firstValue(in: values, keys: ["LIVEKIT_API_SECRET", "API_SECRET"])

        if sandboxID != nil || url != nil || apiKey != nil || apiSecret != nil {
            let hasAnyCloudValue = url != nil || apiKey != nil || apiSecret != nil
            guard !hasAnyCloudValue || (url != nil && apiKey != nil && apiSecret != nil) else {
                throw ProviderSetupError.invalidLiveKitConnection
            }
            return LiveKitConnection(
                sandboxID: sandboxID,
                agentName: agentName,
                url: url,
                apiKey: apiKey,
                apiSecret: apiSecret
            )
        }

        // A single opaque value is the development token-server/Sandbox ID.
        guard !input.contains("=") && !input.contains("\n") && !input.hasPrefix("{") else {
            throw ProviderSetupError.invalidLiveKitConnection
        }
        return LiveKitConnection(
            sandboxID: input,
            agentName: "checkpoint",
            url: nil,
            apiKey: nil,
            apiSecret: nil
        )
    }
}

private func dotenvValues(_ input: String) -> [String: String] {
    var values: [String: String] = [:]
    for rawLine in input.components(separatedBy: .newlines) {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("export ") { line.removeFirst("export ".count) }
        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        if !key.isEmpty, !value.isEmpty { values[key] = value }
    }
    return values
}

private func firstValue(in values: [String: String], keys: [String]) -> String? {
    keys.compactMap { normalized(values[$0]) }.first
}

private func normalized(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

@MainActor
final class ProviderCredentialManager: ObservableObject {
    @Published private(set) var connectedProviders: Set<ProviderKind> = []
    @Published private(set) var operatorProvidedProviders: Set<ProviderKind> = []
    @Published private(set) var statusMessage: String?

    private let store: CredentialStoring
    private let defaults: UserDefaults

    init(
        store: CredentialStoring = KeychainCredentialStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        migrateOperatorEnvironment(environment)
        refreshStatus()
    }

    func isConnected(_ provider: ProviderKind) -> Bool {
        connectedProviders.contains(provider)
    }

    func save(_ draft: ProviderDraft, for provider: ProviderKind) throws {
        var replacedValue = false
        let connectionCode = draft.connectionCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !connectionCode.isEmpty {
            try saveConnectionCode(connectionCode, for: provider)
            replacedValue = true
        }
        for field in provider.fields {
            let value = draft[field].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            try store.set(value, for: field)
            replacedValue = true
        }
        if replacedValue {
            defaults.removeObject(forKey: operatorMarkerKey(provider))
        }
        statusMessage = "Connection saved securely."
        refreshStatus()
    }

    private func saveConnectionCode(_ code: String, for provider: ProviderKind) throws {
        switch provider {
        case .brightData:
            try store.set(code, for: .brightDataAPIKey)
        case .openAI:
            try store.set(code, for: .openAIAPIKey)
        case .moss:
            let connection = try MossConnection.parse(
                code,
                existingProjectID: try store.value(for: .mossProjectID)
            )
            try store.set(connection.projectID, for: .mossProjectID)
            try store.set(connection.projectKey, for: .mossProjectKey)
        case .liveKit:
            let connection = try LiveKitConnection.parse(code)
            if let sandboxID = connection.sandboxID {
                try store.set(sandboxID, for: .liveKitSandboxID)
            } else {
                // A Cloud credential bundle is a replacement, not an
                // additive edit. Do not let an older Sandbox ID silently win
                // when the voice client next reads the Keychain.
                try store.remove(.liveKitSandboxID)
            }
            try store.set(connection.agentName, for: .liveKitAgentName)
            if let url = connection.url,
               let apiKey = connection.apiKey,
               let apiSecret = connection.apiSecret {
                try store.set(url, for: .liveKitURL)
                try store.set(apiKey, for: .liveKitAPIKey)
                try store.set(apiSecret, for: .liveKitAPISecret)
            } else {
                // Likewise, switching back to a token-server ID removes the
                // previous worker credentials instead of leaving two
                // contradictory connection modes in the Keychain.
                try store.remove(.liveKitURL)
                try store.remove(.liveKitAPIKey)
                try store.remove(.liveKitAPISecret)
            }
        }
    }

    func remove(_ provider: ProviderKind) throws {
        for field in provider.fields {
            try store.remove(field)
        }
        defaults.removeObject(forKey: operatorMarkerKey(provider))
        statusMessage = "Connection removed."
        refreshStatus()
    }

    func snapshot() throws -> ProviderCredentials {
        try ProviderCredentials(store: store)
    }

    func wasProvidedByOperator(_ provider: ProviderKind) -> Bool {
        operatorProvidedProviders.contains(provider)
    }

    private func migrateOperatorEnvironment(_ environment: [String: String]) {
        let mappings: [(String, ProviderCredentialField, ProviderKind)] = [
            ("BRIGHT_DATA_API_KEY", .brightDataAPIKey, .brightData),
            ("MOSS_PROJECT_ID", .mossProjectID, .moss),
            ("MOSS_PROJECT_KEY", .mossProjectKey, .moss),
            ("OPENAI_API_KEY", .openAIAPIKey, .openAI),
            ("LIVEKIT_URL", .liveKitURL, .liveKit),
            ("LIVEKIT_API_KEY", .liveKitAPIKey, .liveKit),
            ("LIVEKIT_API_SECRET", .liveKitAPISecret, .liveKit),
            ("LIVEKIT_SANDBOX_ID", .liveKitSandboxID, .liveKit),
            ("LIVEKIT_AGENT_NAME", .liveKitAgentName, .liveKit),
        ]

        for (environmentName, field, provider) in mappings {
            guard let value = Self.migratableValue(environment[environmentName]) else { continue }
            do {
                if try store.value(for: field) == nil {
                    try store.set(value, for: field)
                    defaults.set(true, forKey: operatorMarkerKey(provider))
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
        operatorProvidedProviders = Set(
            ProviderKind.allCases.filter { defaults.bool(forKey: operatorMarkerKey($0)) }
        )
    }

    private static func migratableValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let lowered = value.lowercased()
        let placeholderFragments = ["your-", "placeholder", "change-me", "changeme", "replace-me", "$(", "${"]
        guard !placeholderFragments.contains(where: lowered.contains),
              !(value.hasPrefix("<") && value.hasSuffix(">")) else {
            return nil
        }
        return value
    }

    private func operatorMarkerKey(_ provider: ProviderKind) -> String {
        "checkpoint.operatorProvided.\(provider.rawValue)"
    }

    private func refreshStatus() {
        do {
            let credentials = try snapshot()
            var connected: Set<ProviderKind> = []
            if credentials.brightDataAPIKey.isPresent { connected.insert(.brightData) }
            if credentials.mossProjectID.isPresent && credentials.mossProjectKey.isPresent {
                connected.insert(.moss)
            }
            let sandboxVoice = credentials.liveKitSandboxID.isPresent && credentials.liveKitAgentName.isPresent
            let agentVoice = credentials.liveKitURL.isPresent
                && credentials.liveKitAPIKey.isPresent
                && credentials.liveKitAPISecret.isPresent
            if sandboxVoice || agentVoice { connected.insert(.liveKit) }
            if credentials.openAIAPIKey.isPresent { connected.insert(.openAI) }
            connectedProviders = connected
            operatorProvidedProviders = Set(
                ProviderKind.allCases.filter { defaults.bool(forKey: operatorMarkerKey($0)) }
            )
        } catch {
            connectedProviders = []
            statusMessage = error.localizedDescription
        }
    }
}

private extension Optional where Wrapped == String {
    var isPresent: Bool {
        guard let value = self else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
