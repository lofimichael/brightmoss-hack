import Foundation

enum TurnModality: String, Codable, Sendable {
    case typed
    case voice
}

enum RenderKind: String, Codable, Sendable {
    case message
    case resultCard = "result_card"
    case confirmationCard = "confirmation_card"
    case progressCard = "progress_card"
}

enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case app
    case file
    case url
    case selection
    case note
}

struct CapturedArtifact: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: ArtifactKind
    var displayName: String
    var bundleID: String?
    var resource: String?
    var capturedText: String?

    init(
        id: String = UUID().uuidString,
        kind: ArtifactKind,
        displayName: String,
        bundleID: String? = nil,
        resource: String? = nil,
        capturedText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bundleID = bundleID
        self.resource = resource
        self.capturedText = capturedText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case bundleID = "bundle_id"
        case resource
        case capturedText = "captured_text"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try values.decode(ArtifactKind.self, forKey: .kind)
        displayName = try values.decode(String.self, forKey: .displayName)
        bundleID = try values.decodeIfPresent(String.self, forKey: .bundleID)
        resource = try values.decodeIfPresent(String.self, forKey: .resource)
        capturedText = try values.decodeIfPresent(String.self, forKey: .capturedText)
    }
}

struct CheckpointRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var summary: String
    var nextStep: String?
    var artifacts: [CapturedArtifact]
    var createdAt: String?
    var savedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case nextStep = "next_step"
        case artifacts
        case createdAt = "created_at"
        case savedAt = "saved_at"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        summary: String,
        nextStep: String? = nil,
        artifacts: [CapturedArtifact] = [],
        createdAt: String? = nil,
        savedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.nextStep = nextStep
        self.artifacts = artifacts
        self.createdAt = createdAt
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try values.decode(String.self, forKey: .title)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        nextStep = try values.decodeIfPresent(String.self, forKey: .nextStep)
        artifacts = try values.decodeIfPresent([CapturedArtifact].self, forKey: .artifacts) ?? []
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        savedAt = try values.decodeIfPresent(String.self, forKey: .savedAt)
    }
}

enum SafeActionKind: String, Codable, Sendable {
    case openURL
    case openFile
    case revealInFinder
    case activateApp
    case restoreCheckpoint
}

struct ProposedAction: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: SafeActionKind
    var displayName: String
    var bundleID: String?
    var resource: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case bundleID = "bundle_id"
        case resource
    }

    init(
        id: String = UUID().uuidString,
        kind: SafeActionKind,
        displayName: String,
        bundleID: String? = nil,
        resource: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bundleID = bundleID
        self.resource = resource
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try values.decode(SafeActionKind.self, forKey: .kind)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? kind.rawValue
        bundleID = try values.decodeIfPresent(String.self, forKey: .bundleID)
        resource = try values.decodeIfPresent(String.self, forKey: .resource)
    }
}

struct SourceReference: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var url: String?
    var excerpt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case excerpt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Source"
        url = try values.decodeIfPresent(String.self, forKey: .url)
        excerpt = try values.decodeIfPresent(String.self, forKey: .excerpt)
    }
}

struct TurnRequest: Codable, Sendable {
    let text: String
    let modality: TurnModality
    let allowPublicEnrichment: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case modality
        case allowPublicEnrichment = "allow_public_enrichment"
    }

    init(
        text: String,
        modality: TurnModality,
        allowPublicEnrichment: Bool? = nil
    ) {
        self.text = text
        self.modality = modality
        self.allowPublicEnrichment = allowPublicEnrichment
    }
}

struct TurnResponse: Codable, Identifiable, Sendable {
    var requestID: String
    var kind: RenderKind
    var message: String
    var checkpoint: CheckpointRecord?
    var checkpoints: [CheckpointRecord]
    var sources: [SourceReference]
    var proposedActions: [ProposedAction]
    var proposalID: String?
    var providerDisclosure: [String]

    var id: String { requestID }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case kind
        case message
        case checkpoint
        case checkpoints
        case sources
        case proposedActions = "proposed_actions"
        case proposalID = "proposal_id"
        case providerDisclosure = "provider_disclosure"
    }

    init(
        requestID: String = UUID().uuidString,
        kind: RenderKind,
        message: String,
        checkpoint: CheckpointRecord? = nil,
        checkpoints: [CheckpointRecord] = [],
        sources: [SourceReference] = [],
        proposedActions: [ProposedAction] = [],
        proposalID: String? = nil,
        providerDisclosure: [String] = []
    ) {
        self.requestID = requestID
        self.kind = kind
        self.message = message
        self.checkpoint = checkpoint
        self.checkpoints = checkpoints
        self.sources = sources
        self.proposedActions = proposedActions
        self.proposalID = proposalID
        self.providerDisclosure = providerDisclosure
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID) ?? UUID().uuidString
        kind = try values.decode(RenderKind.self, forKey: .kind)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? ""
        checkpoint = try values.decodeIfPresent(CheckpointRecord.self, forKey: .checkpoint)
        checkpoints = try values.decodeIfPresent([CheckpointRecord].self, forKey: .checkpoints) ?? []
        sources = try values.decodeIfPresent([SourceReference].self, forKey: .sources) ?? []
        proposedActions = try values.decodeIfPresent([ProposedAction].self, forKey: .proposedActions) ?? []
        proposalID = try values.decodeIfPresent(String.self, forKey: .proposalID)
        providerDisclosure = try values.decodeIfPresent([String].self, forKey: .providerDisclosure) ?? []
    }
}

struct CreateCheckpointRequest: Codable, Sendable {
    var title: String
    var summary: String
    var nextStep: String?
    var artifacts: [CapturedArtifact]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case nextStep = "next_step"
        case artifacts
    }
}

enum ProposalDecision: String, Codable, Sendable {
    case approve
    case cancel
}

struct ProposalDecisionRequest: Codable, Sendable {
    let decision: ProposalDecision
}

struct HealthResponse: Codable, Sendable {
    var status: String
}

struct ConversationEntry: Identifiable, Sendable {
    enum Content: Sendable {
        case user(String)
        case assistant(TurnResponse)
    }

    let id: String
    let content: Content

    init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }
}

// MARK: - Persistent memory library

struct MemoryPublicSource: Codable, Identifiable, Hashable, Sendable {
    var title: String
    var url: String
    var snippet: String?

    var id: String { url }

    init(title: String, url: String, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Public source"
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        snippet = try values.decodeIfPresent(String.self, forKey: .snippet)
    }
}

struct MemorySubject: Codable, Identifiable, Hashable, Sendable {
    var canonicalName: String
    var kind: String
    var keywords: [String]
    var confidence: Double

    var id: String { "\(kind):\(canonicalName.lowercased())" }

    enum CodingKeys: String, CodingKey {
        case canonicalName = "canonical_name"
        case kind
        case keywords
        case confidence
    }

    init(
        canonicalName: String,
        kind: String = "other",
        keywords: [String] = [],
        confidence: Double = 0.5
    ) {
        self.canonicalName = canonicalName
        self.kind = kind
        self.keywords = keywords
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canonicalName = try values.decodeIfPresent(String.self, forKey: .canonicalName) ?? "Unknown subject"
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }

    var kindLabel: String {
        kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var checkpointID: String?
    var capturedAt: String?
    var applicationName: String?
    var appBundleID: String?
    var windowTitle: String?
    var documentLabel: String?
    var extractionMethod: String?
    var subjects: [MemorySubject]
    var likelyIntent: String?
    var publicSources: [MemoryPublicSource]
    var provenance: [String]
    var enrichmentStatus: String?
    var outboundQuery: String?

    enum CodingKeys: String, CodingKey {
        case id
        case checkpointID = "checkpoint_id"
        case capturedAt = "captured_at"
        case applicationName = "application_name"
        case appBundleID = "app_bundle_id"
        case windowTitle = "window_title"
        case documentLabel = "document_label"
        case extractionMethod = "extraction_method"
        case subjects
        case likelyIntent = "likely_intent"
        case intent
        case publicSources = "public_sources"
        case provenance
        case enrichmentStatus = "enrichment_status"
        case outboundQuery = "outbound_query"
    }

    init(
        id: String,
        checkpointID: String? = nil,
        capturedAt: String? = nil,
        applicationName: String? = nil,
        appBundleID: String? = nil,
        windowTitle: String? = nil,
        documentLabel: String? = nil,
        extractionMethod: String? = nil,
        subjects: [MemorySubject] = [],
        likelyIntent: String? = nil,
        publicSources: [MemoryPublicSource] = [],
        provenance: [String] = [],
        enrichmentStatus: String? = nil,
        outboundQuery: String? = nil
    ) {
        self.id = id
        self.checkpointID = checkpointID
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.documentLabel = documentLabel
        self.extractionMethod = extractionMethod
        self.subjects = subjects
        self.likelyIntent = likelyIntent
        self.publicSources = publicSources
        self.provenance = provenance
        self.enrichmentStatus = enrichmentStatus
        self.outboundQuery = outboundQuery
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        checkpointID = try values.decodeIfPresent(String.self, forKey: .checkpointID)
        capturedAt = try values.decodeIfPresent(String.self, forKey: .capturedAt)
        applicationName = try values.decodeIfPresent(String.self, forKey: .applicationName)
        appBundleID = try values.decodeIfPresent(String.self, forKey: .appBundleID)
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle)
        documentLabel = try values.decodeIfPresent(String.self, forKey: .documentLabel)
        extractionMethod = try values.decodeIfPresent(String.self, forKey: .extractionMethod)
        subjects = try values.decodeIfPresent([MemorySubject].self, forKey: .subjects) ?? []
        if let text = try? values.decodeIfPresent(String.self, forKey: .likelyIntent) {
            likelyIntent = text
        } else if let intent = try? values.decodeIfPresent(InferredIntentUpload.self, forKey: .likelyIntent) {
            likelyIntent = intent.summary
        } else {
            likelyIntent = try? values.decode(String.self, forKey: .intent)
        }
        publicSources = try values.decodeIfPresent([MemoryPublicSource].self, forKey: .publicSources) ?? []
        provenance = try values.decodeIfPresent([String].self, forKey: .provenance) ?? []
        enrichmentStatus = try values.decodeIfPresent(String.self, forKey: .enrichmentStatus)
        outboundQuery = try values.decodeIfPresent(String.self, forKey: .outboundQuery)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(checkpointID, forKey: .checkpointID)
        try values.encodeIfPresent(capturedAt, forKey: .capturedAt)
        try values.encodeIfPresent(applicationName, forKey: .applicationName)
        try values.encodeIfPresent(appBundleID, forKey: .appBundleID)
        try values.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try values.encodeIfPresent(documentLabel, forKey: .documentLabel)
        try values.encodeIfPresent(extractionMethod, forKey: .extractionMethod)
        try values.encode(subjects, forKey: .subjects)
        try values.encodeIfPresent(likelyIntent, forKey: .likelyIntent)
        try values.encode(publicSources, forKey: .publicSources)
        try values.encode(provenance, forKey: .provenance)
        try values.encodeIfPresent(enrichmentStatus, forKey: .enrichmentStatus)
        try values.encodeIfPresent(outboundQuery, forKey: .outboundQuery)
    }

    var capturedDate: Date? {
        guard let capturedAt else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: capturedAt) ?? ISO8601DateFormatter().date(from: capturedAt)
    }

    var displayTitle: String {
        likelyIntent?.nilIfBlank
            ?? windowTitle?.nilIfBlank
            ?? applicationName?.nilIfBlank
            ?? "Remembered moment"
    }
}

struct MemoryItemsPage: Codable, Equatable, Sendable {
    var items: [MemoryItem]
    var total: Int

    init(items: [MemoryItem] = [], total: Int? = nil) {
        self.items = items
        self.total = total ?? items.count
    }

    init(from decoder: Decoder) throws {
        if let items = try? decoder.singleValueContainer().decode([MemoryItem].self) {
            self.init(items: items)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let items = try values.decodeIfPresent([MemoryItem].self, forKey: .items) ?? []
        self.init(items: items, total: try values.decodeIfPresent(Int.self, forKey: .total))
    }
}

struct MemorySubjectSummary: Codable, Identifiable, Hashable, Sendable {
    var canonicalName: String
    var kind: String
    var keywords: [String]
    var count: Int
    var firstSeen: String?
    var lastSeen: String?
    var apps: [String]
    var publicSources: [MemoryPublicSource]

    var id: String { "\(kind):\(canonicalName.lowercased())" }

    enum CodingKeys: String, CodingKey {
        case canonicalName = "canonical_name"
        case kind
        case keywords
        case count
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case apps
        case publicSources = "public_sources"
    }

    init(
        canonicalName: String,
        kind: String = "other",
        keywords: [String] = [],
        count: Int = 0,
        firstSeen: String? = nil,
        lastSeen: String? = nil,
        apps: [String] = [],
        publicSources: [MemoryPublicSource] = []
    ) {
        self.canonicalName = canonicalName
        self.kind = kind
        self.keywords = keywords
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.apps = apps
        self.publicSources = publicSources
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canonicalName = try values.decodeIfPresent(String.self, forKey: .canonicalName) ?? "Unknown subject"
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 0
        firstSeen = try values.decodeIfPresent(String.self, forKey: .firstSeen)
        lastSeen = try values.decodeIfPresent(String.self, forKey: .lastSeen)
        apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
        publicSources = try values.decodeIfPresent([MemoryPublicSource].self, forKey: .publicSources) ?? []
    }

    var kindLabel: String {
        kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct MemorySubjectsPage: Codable, Equatable, Sendable {
    var subjects: [MemorySubjectSummary]
    var total: Int

    init(subjects: [MemorySubjectSummary] = [], total: Int? = nil) {
        self.subjects = subjects
        self.total = total ?? subjects.count
    }

    init(from decoder: Decoder) throws {
        if let subjects = try? decoder.singleValueContainer().decode([MemorySubjectSummary].self) {
            self.init(subjects: subjects)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let subjects = try values.decodeIfPresent([MemorySubjectSummary].self, forKey: .subjects) ?? []
        self.init(subjects: subjects, total: try values.decodeIfPresent(Int.self, forKey: .total))
    }
}

struct MemoryEnrichmentItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var jobID: String
    var checkpointID: String
    var checkpointTitle: String
    var observationID: String?
    var checkedAt: String
    var publicSubject: String
    var outboundQuery: String
    var status: String
    var policy: String
    var policyReason: String
    var sources: [MemoryPublicSource]
    var sourceCount: Int
    var capturedAt: String?
    var applicationName: String?
    var windowTitle: String?
    var documentLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case checkpointID = "checkpoint_id"
        case checkpointTitle = "checkpoint_title"
        case observationID = "observation_id"
        case checkedAt = "checked_at"
        case publicSubject = "public_subject"
        case outboundQuery = "outbound_query"
        case status
        case policy
        case policyReason = "policy_reason"
        case sources
        case sourceCount = "source_count"
        case capturedAt = "captured_at"
        case applicationName = "application_name"
        case windowTitle = "window_title"
        case documentLabel = "document_label"
    }

    init(
        id: String,
        jobID: String? = nil,
        checkpointID: String = "",
        checkpointTitle: String = "",
        observationID: String? = nil,
        checkedAt: String = "",
        publicSubject: String = "",
        outboundQuery: String = "",
        status: String,
        policy: String = "",
        policyReason: String = "",
        sources: [MemoryPublicSource] = [],
        sourceCount: Int? = nil,
        capturedAt: String? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        documentLabel: String? = nil
    ) {
        self.id = id
        self.jobID = jobID ?? id
        self.checkpointID = checkpointID
        self.checkpointTitle = checkpointTitle
        self.observationID = observationID
        self.checkedAt = checkedAt
        self.publicSubject = publicSubject
        self.outboundQuery = outboundQuery
        self.status = status
        self.policy = policy
        self.policyReason = policyReason
        self.sources = sources
        self.sourceCount = sourceCount ?? sources.count
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.documentLabel = documentLabel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try values.decodeIfPresent(String.self, forKey: .id)
        let decodedJobID = try values.decodeIfPresent(String.self, forKey: .jobID)
        id = decodedID ?? decodedJobID ?? UUID().uuidString
        jobID = decodedJobID ?? id
        checkpointID = try values.decodeIfPresent(String.self, forKey: .checkpointID) ?? ""
        checkpointTitle = try values.decodeIfPresent(String.self, forKey: .checkpointTitle) ?? ""
        observationID = try values.decodeIfPresent(String.self, forKey: .observationID)
        checkedAt = try values.decodeIfPresent(String.self, forKey: .checkedAt) ?? ""
        publicSubject = try values.decodeIfPresent(String.self, forKey: .publicSubject) ?? ""
        outboundQuery = try values.decodeIfPresent(String.self, forKey: .outboundQuery) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        policy = try values.decodeIfPresent(String.self, forKey: .policy) ?? ""
        policyReason = try values.decodeIfPresent(String.self, forKey: .policyReason) ?? ""
        sources = try values.decodeIfPresent([MemoryPublicSource].self, forKey: .sources) ?? []
        sourceCount = try values.decodeIfPresent(Int.self, forKey: .sourceCount) ?? sources.count
        capturedAt = try values.decodeIfPresent(String.self, forKey: .capturedAt)
        applicationName = try values.decodeIfPresent(String.self, forKey: .applicationName)
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle)
        documentLabel = try values.decodeIfPresent(String.self, forKey: .documentLabel)
    }

    var checkedDate: Date? { checkedAt.iso8601Date }
    var originDate: Date? { capturedAt?.iso8601Date }

    var addedKnowledge: Bool {
        ["complete", "cached"].contains(status.lowercased()) && sourceCount > 0
    }
}

struct MemoryEnrichmentsPage: Codable, Equatable, Sendable {
    var items: [MemoryEnrichmentItem]
    var total: Int

    init(items: [MemoryEnrichmentItem] = [], total: Int? = nil) {
        self.items = items
        self.total = total ?? items.count
    }

    init(from decoder: Decoder) throws {
        if let items = try? decoder.singleValueContainer().decode([MemoryEnrichmentItem].self) {
            self.init(items: items)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let items = try values.decodeIfPresent([MemoryEnrichmentItem].self, forKey: .items) ?? []
        self.init(items: items, total: try values.decodeIfPresent(Int.self, forKey: .total))
    }
}

struct MemoryStats: Codable, Equatable, Sendable {
    var totalMemories: Int
    var totalSubjects: Int
    var enrichedMemories: Int
    var publicSources: Int
    var categories: [String: Int]

    enum CodingKeys: String, CodingKey {
        case totalMemories = "total_memories"
        case totalSubjects = "total_subjects"
        case enrichedMemories = "enriched_memories"
        case publicSources = "public_sources"
        case categories
    }

    init(
        totalMemories: Int = 0,
        totalSubjects: Int = 0,
        enrichedMemories: Int = 0,
        publicSources: Int = 0,
        categories: [String: Int] = [:]
    ) {
        self.totalMemories = totalMemories
        self.totalSubjects = totalSubjects
        self.enrichedMemories = enrichedMemories
        self.publicSources = publicSources
        self.categories = categories
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        totalMemories = try values.decodeIfPresent(Int.self, forKey: .totalMemories) ?? 0
        totalSubjects = try values.decodeIfPresent(Int.self, forKey: .totalSubjects) ?? 0
        enrichedMemories = try values.decodeIfPresent(Int.self, forKey: .enrichedMemories) ?? 0
        publicSources = try values.decodeIfPresent(Int.self, forKey: .publicSources) ?? 0
        categories = try values.decodeIfPresent([String: Int].self, forKey: .categories) ?? [:]
    }
}

struct MemoryDeleteResponse: Codable, Equatable, Sendable {
    var observationID: String
    var deleted: Bool
    var checkpointDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case observationID = "observation_id"
        case deleted
        case checkpointDeleted = "checkpoint_deleted"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var iso8601Date: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: self) ?? ISO8601DateFormatter().date(from: self)
    }
}
