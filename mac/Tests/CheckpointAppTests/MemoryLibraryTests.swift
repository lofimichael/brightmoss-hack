import Foundation
import XCTest
@testable import CheckpointApp

final class MemoryLibraryTests: XCTestCase {
    func testMemoryDTOsDecodeStructuredIntentAndMissingOptionalFields() throws {
        let json = Data(
            """
            {
              "items": [{
                "id": "observation-1",
                "checkpoint_id": "ambient-2026-07-18",
                "captured_at": "2026-07-18T21:30:00Z",
                "application_name": "Safari",
                "likely_intent": {"summary": "Read LiveKit docs", "confidence": 0.9},
                "subjects": [{
                  "canonical_name": "LiveKit",
                  "kind": "technology",
                  "keywords": ["realtime", "voice"],
                  "confidence": 0.94
                }],
                "public_sources": [{
                  "title": "LiveKit documentation",
                  "url": "https://docs.livekit.io"
                }],
                "provenance": ["local", "moss", "bright_data"],
                "enrichment_status": "complete",
                "outbound_query": "LiveKit official documentation latest"
              }],
              "total": 12
            }
            """.utf8
        )

        let page = try JSONDecoder().decode(MemoryItemsPage.self, from: json)

        XCTAssertEqual(page.total, 12)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.likelyIntent, "Read LiveKit docs")
        XCTAssertEqual(item.subjects.first?.keywords, ["realtime", "voice"])
        XCTAssertEqual(item.publicSources.first?.title, "LiveKit documentation")
        XCTAssertNil(item.windowTitle)
        XCTAssertNil(item.documentLabel)
    }

    func testObservationUploadCarriesExplicitEnrichmentConsent() throws {
        let observation = WorkspaceObservation(
            id: "observation-consent",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            applicationName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "LiveKit",
            document: "https://docs.livekit.io",
            artifactIDs: []
        )

        let upload = ObservationUploadRequest(
            observation: observation,
            allowPublicEnrichment: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any]
        )

        XCTAssertEqual(object["allow_public_enrichment"] as? Bool, true)
        XCTAssertNotNil(object["extraction_method"] as? String)
        XCTAssertNotNil(object["subjects"] as? [[String: Any]])

        let enrichment = EnrichmentUploadRequest(
            checkpointID: "checkpoint-1",
            candidate: PublicEnrichmentCandidateUpload(
                canonicalName: "LiveKit",
                kind: "technology",
                query: "LiveKit official documentation latest"
            )
        )
        let enrichmentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(enrichment)) as? [String: Any]
        )
        XCTAssertEqual(enrichmentObject["allow_public_enrichment"] as? Bool, false)
    }

    func testExpandedKnowledgeDTOIncludesEveryAttemptAndSafeOrigin() throws {
        let json = Data(
            """
            {
              "items": [
                {
                  "id": "job-complete",
                  "job_id": "job-complete",
                  "checkpoint_id": "ambient-2026-07-18",
                  "checkpoint_title": "Daily memory",
                  "observation_id": "observation-1",
                  "checked_at": "2026-07-18T21:40:00Z",
                  "public_subject": "LiveKit",
                  "outbound_query": "LiveKit official documentation latest",
                  "status": "complete",
                  "policy": "allowed",
                  "policy_reason": "public_subject_allowed",
                  "sources": [{
                    "title": "LiveKit docs",
                    "url": "https://docs.livekit.io/",
                    "snippet": "Realtime voice documentation"
                  }],
                  "source_count": 3,
                  "captured_at": "2026-07-18T21:39:00Z",
                  "application_name": "Safari",
                  "window_title": "LiveKit Docs",
                  "document_label": "docs.livekit.io"
                },
                {
                  "id": "job-rejected",
                  "job_id": "job-rejected",
                  "checkpoint_id": "ambient-2026-07-18",
                  "checkpoint_title": "Daily memory",
                  "observation_id": null,
                  "checked_at": "2026-07-18T21:38:00Z",
                  "public_subject": "[rejected]",
                  "outbound_query": "[rejected]",
                  "status": "rejected",
                  "policy": "rejected",
                  "policy_reason": "private_subject",
                  "sources": [],
                  "source_count": 0,
                  "captured_at": null,
                  "application_name": null,
                  "window_title": null,
                  "document_label": null
                }
              ],
              "total": 9
            }
            """.utf8
        )

        let page = try JSONDecoder().decode(MemoryEnrichmentsPage.self, from: json)

        XCTAssertEqual(page.total, 9)
        XCTAssertEqual(page.items.map(\.status), ["complete", "rejected"])
        XCTAssertEqual(page.items.first?.sourceCount, 3)
        XCTAssertEqual(page.items.first?.sources.first?.snippet, "Realtime voice documentation")
        XCTAssertEqual(page.items.first?.applicationName, "Safari")
        XCTAssertTrue(page.items.first?.addedKnowledge == true)
        XCTAssertFalse(page.items.last?.addedKnowledge == true)
    }

    func testEnrichmentActivityUsesTheSubjectActuallySentPublicly() {
        let subjects = [
            AmbientSubject(
                canonicalName: "Project Cormorant",
                kind: .project,
                keywords: ["private"],
                confidence: 0.95
            ),
            AmbientSubject(
                canonicalName: "LiveKit",
                kind: .technology,
                keywords: ["voice"],
                confidence: 0.8
            ),
        ]

        XCTAssertEqual(
            EnrichmentActivitySubjectResolver.label(
                for: subjects,
                outboundQuery: "LiveKit official documentation latest"
            ),
            "LiveKit"
        )
        XCTAssertEqual(
            EnrichmentActivitySubjectResolver.label(
                for: subjects,
                outboundQuery: "an unrelated public query"
            ),
            "public topic"
        )
    }

    func testURLSessionClientLoadsAndDeletesPersistentMemories() async throws {
        let requestRecorder = MemoryRequestRecorder()
        MemoryLibraryURLProtocol.handler = { request in
            requestRecorder.append(request)
            let path = request.url?.path ?? ""
            let body: String
            switch (request.httpMethod, path) {
            case ("GET", "/memory/items"):
                body = #"{"items":[{"id":"one","application_name":"Xcode"}],"total":1}"#
            case ("GET", "/memory/enrichments"):
                body = #"{"items":[{"id":"job-one","job_id":"job-one","status":"rate_limited","checked_at":"2026-07-18T20:00:00Z","source_count":0}],"total":1}"#
            case ("GET", "/memory/subjects"):
                body = #"{"subjects":[],"total":0}"#
            case ("GET", "/memory/stats"):
                body = #"{"total_memories":1,"total_subjects":0,"enriched_memories":0,"public_sources":0,"categories":{}}"#
            case ("DELETE", "/memory/items/one"):
                body = #"{"observation_id":"one","deleted":true,"checkpoint_deleted":false}"#
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        defer { MemoryLibraryURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryLibraryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = try AgentConnection(
            baseURL: URL(string: "http://127.0.0.1:8765")!,
            token: "test-token"
        )
        let client = URLSessionAgentClient(connection: connection, session: session)

        let page = try await client.listMemoryItems(
            limit: 37,
            before: "cursor value",
            beforeID: "item-cursor"
        )
        let enrichments = try await client.listMemoryEnrichments(
            limit: 19,
            before: "knowledge cursor",
            beforeID: "job-cursor"
        )
        _ = try await client.listMemorySubjects(limit: 24)
        let stats = try await client.memoryStats()
        let deletion = try await client.deleteMemoryItem(id: "one")

        XCTAssertEqual(page.items.first?.id, "one")
        XCTAssertEqual(enrichments.items.first?.status, "rate_limited")
        XCTAssertEqual(stats.totalMemories, 1)
        XCTAssertTrue(deletion.deleted)
        let captured = requestRecorder.snapshot()
        let itemRequest = try XCTUnwrap(captured.first { $0.url?.path == "/memory/items" })
        let components = try XCTUnwrap(URLComponents(url: itemRequest.url!, resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "limit", value: "37")) == true)
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "before", value: "cursor value")) == true)
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "before_id", value: "item-cursor")) == true)
        XCTAssertEqual(itemRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let enrichmentRequest = try XCTUnwrap(
            captured.first { $0.url?.path == "/memory/enrichments" }
        )
        let enrichmentComponents = try XCTUnwrap(
            URLComponents(url: enrichmentRequest.url!, resolvingAgainstBaseURL: false)
        )
        XCTAssertTrue(enrichmentComponents.queryItems?.contains(URLQueryItem(name: "limit", value: "19")) == true)
        XCTAssertTrue(enrichmentComponents.queryItems?.contains(URLQueryItem(name: "before", value: "knowledge cursor")) == true)
        XCTAssertTrue(enrichmentComponents.queryItems?.contains(URLQueryItem(name: "before_id", value: "job-cursor")) == true)
    }

    @MainActor
    func testAppModelRestoresServerCountDeletesAndPreservesLastSnapshotOnFailure() async throws {
        let agent = MemoryLibraryAgent()
        let defaultsName = "checkpoint-memory-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = ProviderCredentialManager(
            store: EmptyMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: agent,
            voice: MemoryLibraryVoiceSession(),
            providerCredentials: credentials,
            defaults: defaults
        )

        await model.connectAndLoad()
        XCTAssertEqual(model.capturedObservationCount, 7)
        XCTAssertEqual(model.memoryItems.map(\.id), ["remembered-one"])

        agent.shouldFailMemoryLoads = true
        await model.reloadMemories()
        XCTAssertEqual(model.memoryItems.map(\.id), ["remembered-one"])
        XCTAssertNotNil(model.memoryLibraryError)

        agent.shouldFailMemoryLoads = false
        let item = try XCTUnwrap(model.memoryItems.first)
        await model.deleteMemory(item)
        XCTAssertTrue(model.memoryItems.isEmpty)
        XCTAssertEqual(model.capturedObservationCount, 6)
        XCTAssertNil(model.memoryLibraryError)
    }

    @MainActor
    func testAppModelLoadsEarlierMemoriesWithCursorAndDeduplicates() async throws {
        let newest = "2026-07-18T21:03:00Z"
        let middle = "2026-07-18T21:02:00Z"
        let oldest = "2026-07-18T21:01:00Z"
        let agent = MemoryLibraryAgent(
            page: MemoryItemsPage(
                items: [
                    MemoryItem(id: "newest", capturedAt: newest),
                    MemoryItem(id: "middle", capturedAt: middle),
                ],
                total: 3
            ),
            stats: MemoryStats(totalMemories: 3),
            earlierPage: MemoryItemsPage(
                items: [
                    MemoryItem(id: "middle", capturedAt: middle),
                    MemoryItem(id: "oldest", capturedAt: oldest),
                ],
                total: 3
            )
        )
        let defaultsName = "checkpoint-pagination-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = ProviderCredentialManager(
            store: EmptyMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: agent,
            voice: MemoryLibraryVoiceSession(),
            providerCredentials: credentials,
            defaults: defaults
        )

        await model.connectAndLoad()
        XCTAssertTrue(model.canLoadEarlierMemories)

        await model.loadEarlierMemories()

        XCTAssertEqual(model.memoryItems.map(\.id), ["newest", "middle", "oldest"])
        XCTAssertEqual(agent.requestedBeforeCursors(), ["\(middle)|middle"])
        XCTAssertFalse(model.canLoadEarlierMemories)
    }

    @MainActor
    func testAppModelLoadsEveryKnowledgeAttemptWithStableIndependentCursor() async throws {
        let sharedTimestamp = "2026-07-18T21:05:00Z"
        let agent = MemoryLibraryAgent(
            page: MemoryItemsPage(
                items: [MemoryItem(id: "moment", capturedAt: sharedTimestamp)],
                total: 1
            ),
            stats: MemoryStats(totalMemories: 1),
            enrichmentPage: MemoryEnrichmentsPage(
                items: [
                    MemoryEnrichmentItem(
                        id: "job-c",
                        checkedAt: sharedTimestamp,
                        publicSubject: "LiveKit",
                        outboundQuery: "LiveKit official documentation latest",
                        status: "complete",
                        sources: [MemoryPublicSource(title: "Docs", url: "https://docs.livekit.io")]
                    ),
                    MemoryEnrichmentItem(
                        id: "job-b",
                        checkedAt: sharedTimestamp,
                        publicSubject: "SwiftUI",
                        outboundQuery: "SwiftUI official documentation latest",
                        status: "rate_limited"
                    ),
                ],
                total: 3
            ),
            earlierEnrichmentPage: MemoryEnrichmentsPage(
                items: [
                    MemoryEnrichmentItem(
                        id: "job-b",
                        checkedAt: sharedTimestamp,
                        publicSubject: "SwiftUI",
                        status: "rate_limited"
                    ),
                    MemoryEnrichmentItem(
                        id: "job-a",
                        checkedAt: sharedTimestamp,
                        publicSubject: "Private candidate",
                        status: "rejected"
                    ),
                ],
                total: 3
            )
        )
        let defaultsName = "checkpoint-knowledge-pagination-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = ProviderCredentialManager(
            store: EmptyMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: agent,
            voice: MemoryLibraryVoiceSession(),
            providerCredentials: credentials,
            defaults: defaults
        )

        await model.connectAndLoad()
        XCTAssertEqual(model.memoryEnrichments.map(\.status), ["complete", "rate_limited"])
        XCTAssertTrue(model.canLoadEarlierEnrichments)

        await model.loadEarlierEnrichments()

        XCTAssertEqual(model.memoryEnrichments.map(\.id), ["job-c", "job-b", "job-a"])
        XCTAssertEqual(
            agent.requestedEnrichmentCursors(),
            ["\(sharedTimestamp)|job-b"]
        )
        XCTAssertFalse(model.canLoadEarlierEnrichments)
        XCTAssertEqual(model.memoryItems.map(\.id), ["moment"])

        agent.shouldFailEnrichmentLoads = true
        await model.reloadMemories()
        XCTAssertEqual(model.memoryEnrichments.map(\.id), ["job-c", "job-b", "job-a"])
        XCTAssertNotNil(model.knowledgeLibraryError)
    }

    @MainActor
    func testStoredVisualFallbackRestoresWithoutRequestingScreenPermission() {
        let agent = MemoryLibraryAgent()
        let visualCapture = CountingVisualTextCapture()
        let recorder = WorkspaceRecorder(visualCapture: visualCapture)
        let defaultsName = "checkpoint-visual-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(true, forKey: "checkpoint.visualFallbackEnabled")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = ProviderCredentialManager(
            store: EmptyMemoryCredentialStore(), environment: [:], defaults: defaults
        )

        let model = AppModel(
            client: agent,
            recorder: recorder,
            voice: MemoryLibraryVoiceSession(),
            providerCredentials: credentials,
            defaults: defaults
        )

        XCTAssertTrue(model.visualFallbackEnabled)
        XCTAssertEqual(visualCapture.requestCount, 0)
    }
}

private final class MemoryLibraryURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? {
                throw URLError(.badServerResponse)
            }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MemoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func snapshot() -> [URLRequest] {
        lock.withLock { requests }
    }
}

private final class EmptyMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    func value(for field: ProviderCredentialField) throws -> String? { nil }
    func set(_ value: String, for field: ProviderCredentialField) throws {}
    func remove(_ field: ProviderCredentialField) throws {}
}

private final class CountingVisualTextCapture: VisualTextCapturing, @unchecked Sendable {
    var authorizationState: VisualCaptureAuthorizationState = .notRequested
    private(set) var requestCount = 0

    func requestAccess() -> VisualCaptureAuthorizationState {
        requestCount += 1
        authorizationState = .denied
        return authorizationState
    }

    func recognizeFrontWindowText(for target: VisualCaptureTarget) async -> String? {
        nil
    }
}

@MainActor
private final class MemoryLibraryVoiceSession: VoiceSessionControlling {
    var state: VoiceSessionState = .idle
    var availabilityMessage: String?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChange: ((VoiceSessionState, String?) -> Void)?
    func start() async throws {}
    func stop() async {}
}

private final class MemoryLibraryAgent: AgentServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var page: MemoryItemsPage
    private var stats: MemoryStats
    private var earlierPage: MemoryItemsPage?
    private var enrichmentPage: MemoryEnrichmentsPage
    private var earlierEnrichmentPage: MemoryEnrichmentsPage?
    private var beforeCursors: [String] = []
    private var enrichmentBeforeCursors: [String] = []
    var shouldFailMemoryLoads = false
    var shouldFailEnrichmentLoads = false

    init(
        page: MemoryItemsPage = MemoryItemsPage(
            items: [MemoryItem(id: "remembered-one", applicationName: "Xcode")],
            total: 7
        ),
        stats: MemoryStats = MemoryStats(totalMemories: 7, totalSubjects: 3),
        earlierPage: MemoryItemsPage? = nil,
        enrichmentPage: MemoryEnrichmentsPage = MemoryEnrichmentsPage(),
        earlierEnrichmentPage: MemoryEnrichmentsPage? = nil
    ) {
        self.page = page
        self.stats = stats
        self.earlierPage = earlierPage
        self.enrichmentPage = enrichmentPage
        self.earlierEnrichmentPage = earlierEnrichmentPage
    }

    func health() async throws -> HealthResponse { HealthResponse(status: "ok") }
    func providerStatus() async throws -> ProviderConfigurationResponse {
        ProviderConfigurationResponse(status: "ok")
    }
    func sendTurn(
        text: String, modality: TurnModality, allowPublicEnrichment: Bool
    ) async throws -> TurnResponse {
        TurnResponse(kind: .message, message: text)
    }
    func listCheckpoints() async throws -> [CheckpointRecord] { [] }
    func createCheckpoint(_ request: CreateCheckpointRequest) async throws -> CheckpointRecord {
        CheckpointRecord(title: request.title, summary: request.summary)
    }
    func decideProposal(id: String, decision: ProposalDecision) async throws -> TurnResponse {
        TurnResponse(kind: .message, message: "No action")
    }
    func configureProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse {
        ProviderConfigurationResponse(status: "ok")
    }
    func saveObservation(_ observation: ObservationUploadRequest) async throws -> ObservationUploadResponse {
        ObservationUploadResponse(
            id: observation.id, checkpointID: "ambient-test", contentHash: "hash",
            nodeIDs: [], evidenceID: "evidence"
        )
    }
    func enrich(_ request: EnrichmentUploadRequest) async throws -> EnrichmentUploadResponse {
        EnrichmentUploadResponse(
            jobID: "job", status: "complete", policy: "allowed",
            policyReason: "public_subject_allowed", outboundQuery: request.candidate.query,
            sources: []
        )
    }
    func eraseRecent(minutes: Int) async throws -> EraseRecentMemoryResponse {
        EraseRecentMemoryResponse(
            observations: 0, nodes: 0, edges: 0, evidence: 0,
            enrichmentJobs: 0, sourceVersions: 0
        )
    }
    func listMemoryItems(
        limit: Int,
        before: String?,
        beforeID: String?
    ) async throws -> MemoryItemsPage {
        try checkFailure()
        return lock.withLock {
            if let before {
                beforeCursors.append("\(before)|\(beforeID ?? "")")
                return earlierPage ?? MemoryItemsPage(total: page.total)
            }
            return page
        }
    }
    func listMemoryEnrichments(
        limit: Int,
        before: String?,
        beforeID: String?
    ) async throws -> MemoryEnrichmentsPage {
        try checkFailure()
        if shouldFailEnrichmentLoads { throw URLError(.cannotConnectToHost) }
        return lock.withLock {
            if let before {
                enrichmentBeforeCursors.append("\(before)|\(beforeID ?? "")")
                return earlierEnrichmentPage ?? MemoryEnrichmentsPage(total: enrichmentPage.total)
            }
            return enrichmentPage
        }
    }
    func listMemorySubjects(limit: Int) async throws -> MemorySubjectsPage {
        try checkFailure()
        return MemorySubjectsPage(
            subjects: [MemorySubjectSummary(canonicalName: "Swift", kind: "technology", count: 3)]
        )
    }
    func memoryStats() async throws -> MemoryStats {
        try checkFailure()
        return lock.withLock { stats }
    }
    func deleteMemoryItem(id: String) async throws -> MemoryDeleteResponse {
        lock.withLock {
            page.items.removeAll { $0.id == id }
            page.total = max(0, page.total - 1)
            stats.totalMemories = max(0, stats.totalMemories - 1)
        }
        return MemoryDeleteResponse(observationID: id, deleted: true, checkpointDeleted: false)
    }

    private func checkFailure() throws {
        if shouldFailMemoryLoads { throw URLError(.cannotConnectToHost) }
    }

    func requestedBeforeCursors() -> [String] {
        lock.withLock { beforeCursors }
    }

    func requestedEnrichmentCursors() -> [String] {
        lock.withLock { enrichmentBeforeCursors }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
