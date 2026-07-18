import Darwin
import Foundation

enum AgentClientError: LocalizedError {
    case connectionNotConfigured
    case invalidConnection(String)
    case invalidResponse
    case httpStatus(Int, String)
    case missingCheckpoint

    var errorDescription: String? {
        switch self {
        case .connectionNotConfigured:
            return "CHECKPOINT's local memory isn't ready."
        case .invalidConnection(let reason):
            return "The local memory connection is invalid: \(reason)"
        case .invalidResponse:
            return "Local memory returned an unreadable response."
        case .httpStatus(let status, let message):
            return "Local memory returned \(status): \(message)"
        case .missingCheckpoint:
            return "Local memory did not return the saved checkpoint."
        }
    }
}

struct AgentConnection: Codable, Equatable, Sendable {
    let baseURL: URL
    let token: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case port
        case token
    }

    init(baseURL: URL, token: String) throws {
        guard Self.isLoopback(baseURL) else {
            throw AgentClientError.invalidConnection("only a loopback HTTP URL is allowed")
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.invalidConnection("the bearer token is empty")
        }
        self.baseURL = baseURL
        self.token = token
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let token = try values.decode(String.self, forKey: .token)
        let url: URL
        if let decodedURL = try values.decodeIfPresent(URL.self, forKey: .baseURL) {
            url = decodedURL
        } else {
            let port = try values.decode(Int.self, forKey: .port)
            guard (1...65_535).contains(port), let constructed = URL(string: "http://127.0.0.1:\(port)") else {
                throw AgentClientError.invalidConnection("the port is out of range")
            }
            url = constructed
        }
        try self.init(baseURL: url, token: token)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(token, forKey: .token)
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil else {
            return false
        }
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

enum AgentConnectionStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Checkpoint", isDirectory: true)
            .appendingPathComponent("agent-connection.json", isDirectory: false)
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL = defaultURL
    ) throws -> AgentConnection {
        if let rawURL = environment["CHECKPOINT_AGENT_URL"], let url = URL(string: rawURL) {
            guard let token = environment["CHECKPOINT_AGENT_TOKEN"] else {
                throw AgentClientError.invalidConnection("CHECKPOINT_AGENT_TOKEN is missing")
            }
            return try AgentConnection(baseURL: url, token: token)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentClientError.connectionNotConfigured
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 65_536 else {
            throw AgentClientError.invalidConnection("the connection file is not a small regular file")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard ownerID == getuid(), let permissions, permissions & 0o077 == 0 else {
            throw AgentClientError.invalidConnection("the connection file must be owned by this user with user-only permissions")
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try JSONDecoder().decode(AgentConnection.self, from: data)
    }
}

protocol AgentServicing: Sendable {
    func health() async throws -> HealthResponse
    func providerStatus() async throws -> ProviderConfigurationResponse
    func sendTurn(
        text: String,
        modality: TurnModality,
        allowPublicEnrichment: Bool
    ) async throws -> TurnResponse
    func listCheckpoints() async throws -> [CheckpointRecord]
    func createCheckpoint(_ request: CreateCheckpointRequest) async throws -> CheckpointRecord
    func decideProposal(id: String, decision: ProposalDecision) async throws -> TurnResponse
    func configureProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse
    func configurePresentProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse
    func removeProvider(_ provider: ProviderKind) async throws -> ProviderConfigurationResponse
    func saveObservation(_ observation: ObservationUploadRequest) async throws -> ObservationUploadResponse
    func enrich(_ request: EnrichmentUploadRequest) async throws -> EnrichmentUploadResponse
    func eraseRecent(minutes: Int) async throws -> EraseRecentMemoryResponse
    func listMemoryItems(limit: Int, before: String?, beforeID: String?) async throws -> MemoryItemsPage
    func listMemoryEnrichments(limit: Int, before: String?, beforeID: String?) async throws -> MemoryEnrichmentsPage
    func listMemorySubjects(limit: Int) async throws -> MemorySubjectsPage
    func memoryStats() async throws -> MemoryStats
    func deleteMemoryItem(id: String) async throws -> MemoryDeleteResponse
}

extension AgentServicing {
    func configurePresentProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse {
        try await configureProviders(credentials)
    }

    func removeProvider(_ provider: ProviderKind) async throws -> ProviderConfigurationResponse {
        _ = provider
        return try await configureProviders(ProviderCredentials())
    }

    // Defaults keep lightweight test and preview clients source compatible. The
    // authenticated URLSession client below provides the persistent library.
    func listMemoryItems(limit: Int, before: String?, beforeID: String?) async throws -> MemoryItemsPage {
        _ = limit
        _ = before
        _ = beforeID
        return MemoryItemsPage()
    }

    func listMemoryEnrichments(
        limit: Int,
        before: String?,
        beforeID: String?
    ) async throws -> MemoryEnrichmentsPage {
        _ = limit
        _ = before
        _ = beforeID
        return MemoryEnrichmentsPage()
    }

    func listMemorySubjects(limit: Int) async throws -> MemorySubjectsPage {
        _ = limit
        return MemorySubjectsPage()
    }

    func memoryStats() async throws -> MemoryStats {
        MemoryStats()
    }

    func deleteMemoryItem(id: String) async throws -> MemoryDeleteResponse {
        MemoryDeleteResponse(observationID: id, deleted: false, checkpointDeleted: false)
    }
}

struct PresentProviderCredentials: Encodable {
    let credentials: ProviderCredentials

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProviderCredentials.CodingKeys.self)
        try values.encodeIfPresent(credentials.brightDataAPIKey, forKey: .brightDataAPIKey)
        try values.encodeIfPresent(credentials.mossProjectID, forKey: .mossProjectID)
        try values.encodeIfPresent(credentials.mossProjectKey, forKey: .mossProjectKey)
        try values.encodeIfPresent(credentials.openAIAPIKey, forKey: .openAIAPIKey)
        try values.encodeIfPresent(credentials.liveKitURL, forKey: .liveKitURL)
        try values.encodeIfPresent(credentials.liveKitAPIKey, forKey: .liveKitAPIKey)
        try values.encodeIfPresent(credentials.liveKitAPISecret, forKey: .liveKitAPISecret)
        try values.encodeIfPresent(credentials.liveKitSandboxID, forKey: .liveKitSandboxID)
        try values.encodeIfPresent(credentials.liveKitAgentName, forKey: .liveKitAgentName)
    }
}

private struct ProviderRemovalRequest: Encodable {
    let provider: ProviderKind

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: ProviderCredentials.CodingKeys.self)
        switch provider {
        case .brightData:
            try values.encodeNil(forKey: .brightDataAPIKey)
        case .moss:
            try values.encodeNil(forKey: .mossProjectID)
            try values.encodeNil(forKey: .mossProjectKey)
        case .liveKit:
            try values.encodeNil(forKey: .liveKitURL)
            try values.encodeNil(forKey: .liveKitAPIKey)
            try values.encodeNil(forKey: .liveKitAPISecret)
            try values.encodeNil(forKey: .liveKitSandboxID)
            try values.encodeNil(forKey: .liveKitAgentName)
        case .openAI:
            try values.encodeNil(forKey: .openAIAPIKey)
        }
    }
}

struct LocalSubjectUpload: Codable, Equatable, Sendable {
    let canonicalName: String
    let kind: String
    let keywords: [String]
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case canonicalName = "canonical_name"
        case kind
        case keywords
        case confidence
    }

    init(
        canonicalName: String,
        kind: String,
        keywords: [String] = [],
        confidence: Double
    ) {
        self.canonicalName = canonicalName
        self.kind = kind
        self.keywords = keywords
        self.confidence = confidence
    }
}

struct InferredIntentUpload: Codable, Equatable, Sendable {
    let summary: String
    let confidence: Double
}

struct ObservationUploadRequest: Codable, Equatable, Sendable {
    let checkpointID: String?
    let id: String
    let capturedAt: String
    let applicationName: String
    let appBundleID: String?
    let windowTitle: String?
    let documentResource: String?
    let extractedText: String?
    let extractionMethod: String
    let subjects: [LocalSubjectUpload]
    let likelyIntent: InferredIntentUpload?
    let allowPublicEnrichment: Bool

    enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case id
        case capturedAt = "captured_at"
        case applicationName = "application_name"
        case appBundleID = "app_bundle_id"
        case windowTitle = "window_title"
        case documentResource = "document_resource"
        case extractedText = "extracted_text"
        case extractionMethod = "extraction_method"
        case subjects
        case likelyIntent = "likely_intent"
        case allowPublicEnrichment = "allow_public_enrichment"
    }

    init(observation: WorkspaceObservation, allowPublicEnrichment: Bool = false) {
        checkpointID = nil
        id = observation.id
        capturedAt = ISO8601DateFormatter().string(from: observation.capturedAt)
        applicationName = observation.applicationName.prefixCharacters(255)
        appBundleID = observation.bundleID?.prefixCharacters(255)
        windowTitle = observation.windowTitle?.prefixCharacters(500)
        documentResource = observation.document?.prefixCharacters(2_000)
        extractedText = observation.extractedText?.prefixCharacters(20_000)
        extractionMethod = observation.extractionMethod.rawValue
        let structured = observation.extraction?.structuredSubjects ?? []
        if structured.isEmpty {
            subjects = (observation.extraction?.subjects ?? [observation.applicationName])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniquedCaseInsensitively()
                .prefix(12)
                .map {
                    LocalSubjectUpload(
                        canonicalName: $0.prefixCharacters(160),
                        kind: "other",
                        keywords: [],
                        confidence: 0.8
                    )
                }
        } else {
            var seen: Set<String> = []
            subjects = structured.filter {
                seen.insert($0.canonicalName.lowercased()).inserted
            }.prefix(12).map {
                LocalSubjectUpload(
                    canonicalName: $0.canonicalName.prefixCharacters(160),
                    kind: $0.kind.rawValue,
                    keywords: Array($0.keywords.prefix(8)).map { $0.prefixCharacters(80) },
                    confidence: min(1, max(0, $0.confidence))
                )
            }
        }
        likelyIntent = observation.extraction?.likelyIntent.map {
            InferredIntentUpload(summary: $0.prefixCharacters(500), confidence: 0.7)
        }
        self.allowPublicEnrichment = allowPublicEnrichment
    }
}

struct ObservationUploadResponse: Codable, Equatable, Sendable {
    let id: String
    let checkpointID: String
    let contentHash: String
    let nodeIDs: [String]
    let evidenceID: String
    var enrichment: EnrichmentUploadResponse? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case checkpointID = "checkpoint_id"
        case contentHash = "content_hash"
        case nodeIDs = "node_ids"
        case evidenceID = "evidence_id"
        case enrichment
    }
}

struct PublicEnrichmentCandidateUpload: Codable, Equatable, Sendable {
    let canonicalName: String
    let kind: String
    let query: String

    enum CodingKeys: String, CodingKey {
        case canonicalName = "canonical_name"
        case kind
        case query
    }
}

struct EnrichmentUploadRequest: Codable, Equatable, Sendable {
    let checkpointID: String
    let observationID: String?
    let candidate: PublicEnrichmentCandidateUpload
    let allowPublicEnrichment: Bool

    enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case observationID = "observation_id"
        case candidate
        case allowPublicEnrichment = "allow_public_enrichment"
    }

    init(
        checkpointID: String,
        observationID: String? = nil,
        candidate: PublicEnrichmentCandidateUpload,
        allowPublicEnrichment: Bool = false
    ) {
        self.checkpointID = checkpointID
        self.observationID = observationID
        self.candidate = candidate
        self.allowPublicEnrichment = allowPublicEnrichment
    }
}

struct PublicSourceUploadResponse: Codable, Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String?
}

struct EnrichmentUploadResponse: Codable, Equatable, Sendable {
    let jobID: String
    let status: String
    let policy: String
    let policyReason: String
    let outboundQuery: String?
    let sources: [PublicSourceUploadResponse]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case policy
        case policyReason = "policy_reason"
        case outboundQuery = "outbound_query"
        case sources
    }
}

struct EraseRecentMemoryRequest: Codable, Equatable, Sendable {
    let minutes: Int
}

struct EraseRecentMemoryResponse: Codable, Equatable, Sendable {
    let observations: Int
    let nodes: Int
    let edges: Int
    let evidence: Int
    let enrichmentJobs: Int
    let sourceVersions: Int

    enum CodingKeys: String, CodingKey {
        case observations
        case nodes
        case edges
        case evidence
        case enrichmentJobs = "enrichment_jobs"
        case sourceVersions = "source_versions"
    }
}

enum SafePublicEnrichmentCandidateFactory {
    private static let privateSuffixes = [
        ".local", ".internal", ".lan", ".home", ".corp", ".intranet",
        ".test", ".invalid", ".example", ".onion",
    ]

    /// Prefer one typed public subject, then fall back to a public HTTPS hostname.
    /// Local keywords, paths, titles, extracted text, intent, query strings,
    /// fragments, and credentials never enter the outbound candidate.
    static func candidate(for observation: WorkspaceObservation) -> PublicEnrichmentCandidateUpload? {
        let allowedKinds = Set([
            "technology", "product", "company", "public_documentation", "academic_topic",
        ])
        let structuredSubjects = observation.extraction?.structuredSubjects ?? []
        let eligibleSubjects = structuredSubjects.filter {
            allowedKinds.contains($0.kind.rawValue) && $0.confidence >= 0.75
        }
        if let subject = eligibleSubjects.max(by: { $0.confidence < $1.confidence }) {
            let name = subject.canonicalName
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .prefixCharacters(160)
            if !name.isEmpty {
                let suffix: String
                switch subject.kind.rawValue {
                case "company":
                    suffix = "official company information latest"
                case "academic_topic":
                    suffix = "recent academic research overview"
                case "product":
                    suffix = "official product information latest"
                case "technology", "public_documentation":
                    suffix = "official documentation latest"
                default:
                    return nil
                }
                return PublicEnrichmentCandidateUpload(
                    canonicalName: name,
                    kind: subject.kind.rawValue,
                    query: "\(name) \(suffix)".prefixCharacters(240)
                )
            }
        }

        guard let raw = observation.document,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let rawHost = components.host?.lowercased(),
              rawHost.contains("."),
              !rawHost.hasSuffix("."),
              rawHost != "localhost",
              !privateSuffixes.contains(where: rawHost.hasSuffix),
              !isIPAddress(rawHost) else {
            return nil
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        return PublicEnrichmentCandidateUpload(
            canonicalName: host,
            kind: "public_documentation",
            query: "\(host) official documentation latest"
        )
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }
}

actor URLSessionAgentClient: AgentServicing {
    private let connection: AgentConnection
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(connection: AgentConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    func health() async throws -> HealthResponse {
        let data = try await request(path: "health", method: "GET")
        return try decode(HealthResponse.self, from: data)
    }

    func providerStatus() async throws -> ProviderConfigurationResponse {
        let data = try await request(path: "providers", method: "GET")
        return try decode(ProviderConfigurationResponse.self, from: data)
    }

    func sendTurn(
        text: String,
        modality: TurnModality,
        allowPublicEnrichment: Bool
    ) async throws -> TurnResponse {
        let body = try encoder.encode(
            TurnRequest(
                text: text,
                modality: modality,
                allowPublicEnrichment: allowPublicEnrichment
            )
        )
        let data = try await request(path: "turn", method: "POST", body: body)
        return try decode(TurnResponse.self, from: data)
    }

    func configureProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse {
        let body = try encoder.encode(credentials)
        let data = try await request(path: "providers/configure", method: "POST", body: body)
        return try decode(ProviderConfigurationResponse.self, from: data)
    }

    func configurePresentProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse {
        let body = try encoder.encode(PresentProviderCredentials(credentials: credentials))
        let data = try await request(path: "providers/configure", method: "POST", body: body)
        return try decode(ProviderConfigurationResponse.self, from: data)
    }

    func removeProvider(_ provider: ProviderKind) async throws -> ProviderConfigurationResponse {
        let body = try encoder.encode(ProviderRemovalRequest(provider: provider))
        let data = try await request(path: "providers/configure", method: "POST", body: body)
        return try decode(ProviderConfigurationResponse.self, from: data)
    }

    func saveObservation(_ observation: ObservationUploadRequest) async throws -> ObservationUploadResponse {
        let body = try encoder.encode(observation)
        let data = try await request(path: "observations", method: "POST", body: body)
        return try decode(ObservationUploadResponse.self, from: data)
    }

    func enrich(_ enrichment: EnrichmentUploadRequest) async throws -> EnrichmentUploadResponse {
        let body = try encoder.encode(enrichment)
        let data = try await request(path: "enrichments", method: "POST", body: body)
        return try decode(EnrichmentUploadResponse.self, from: data)
    }

    func eraseRecent(minutes: Int) async throws -> EraseRecentMemoryResponse {
        let body = try encoder.encode(EraseRecentMemoryRequest(minutes: minutes))
        let data = try await request(path: "memory/erase-recent", method: "POST", body: body)
        return try decode(EraseRecentMemoryResponse.self, from: data)
    }

    func listMemoryItems(
        limit: Int,
        before: String?,
        beforeID: String?
    ) async throws -> MemoryItemsPage {
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        if let before = before?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
            if let beforeID = beforeID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !beforeID.isEmpty {
                query.append(URLQueryItem(name: "before_id", value: beforeID))
            }
        }
        let data = try await request(path: "memory/items", method: "GET", queryItems: query)
        return try decode(MemoryItemsPage.self, from: data)
    }

    func listMemoryEnrichments(
        limit: Int,
        before: String?,
        beforeID: String?
    ) async throws -> MemoryEnrichmentsPage {
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        if let before = before?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
            if let beforeID = beforeID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !beforeID.isEmpty {
                query.append(URLQueryItem(name: "before_id", value: beforeID))
            }
        }
        let data = try await request(path: "memory/enrichments", method: "GET", queryItems: query)
        return try decode(MemoryEnrichmentsPage.self, from: data)
    }

    func listMemorySubjects(limit: Int) async throws -> MemorySubjectsPage {
        let query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        let data = try await request(path: "memory/subjects", method: "GET", queryItems: query)
        return try decode(MemorySubjectsPage.self, from: data)
    }

    func memoryStats() async throws -> MemoryStats {
        let data = try await request(path: "memory/stats", method: "GET")
        return try decode(MemoryStats.self, from: data)
    }

    func deleteMemoryItem(id: String) async throws -> MemoryDeleteResponse {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw AgentClientError.invalidResponse
        }
        let data = try await request(path: "memory/items/\(encodedID)", method: "DELETE")
        if data.isEmpty {
            return MemoryDeleteResponse(observationID: id, deleted: true, checkpointDeleted: false)
        }
        return try decode(MemoryDeleteResponse.self, from: data)
    }

    func listCheckpoints() async throws -> [CheckpointRecord] {
        let data = try await request(path: "checkpoints", method: "GET")
        if let records = try? decoder.decode([CheckpointRecord].self, from: data) {
            return records
        }
        struct Envelope: Decodable { let checkpoints: [CheckpointRecord] }
        return try decode(Envelope.self, from: data).checkpoints
    }

    func createCheckpoint(_ checkpoint: CreateCheckpointRequest) async throws -> CheckpointRecord {
        let body = try encoder.encode(checkpoint)
        let data = try await request(path: "checkpoints", method: "POST", body: body)
        if let record = try? decoder.decode(CheckpointRecord.self, from: data) {
            return record
        }
        struct Envelope: Decodable { let checkpoint: CheckpointRecord? }
        guard let record = try decode(Envelope.self, from: data).checkpoint else {
            throw AgentClientError.missingCheckpoint
        }
        return record
    }

    func decideProposal(id: String, decision: ProposalDecision) async throws -> TurnResponse {
        let body = try encoder.encode(ProposalDecisionRequest(decision: decision))
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await request(
            path: "proposals/\(encodedID)/decision",
            method: "POST",
            body: body
        )
        return try decode(TurnResponse.self, from: data)
    }

    private func request(
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        let base = connection.baseURL.appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { throw AgentClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let raw = String(data: data.prefix(1_024), encoding: .utf8) ?? "Request failed"
            throw AgentClientError.httpStatus(response.statusCode, raw)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AgentClientError.invalidResponse
        }
    }
}

private extension String {
    func prefixCharacters(_ maximum: Int) -> String {
        String(prefix(maximum))
    }
}

private extension Sequence where Element == String {
    func uniquedCaseInsensitively() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
