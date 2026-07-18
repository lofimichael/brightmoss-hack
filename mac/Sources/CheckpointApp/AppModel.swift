import AppKit
import Combine
import Foundation

enum MemoryActivity: Equatable, Sendable {
    case idle
    case saving(application: String)
    case remembered(application: String)
    case enriching(subject: String)
    case enriched(subject: String, sourceCount: Int)
    case localOnly(application: String)
    case failed

    var title: String {
        switch self {
        case .idle: return "Ready to remember"
        case .saving: return "Saving context locally…"
        case .remembered(let application): return "Remembered \(application)"
        case .enriching(let subject): return "Learning about \(subject)…"
        case .enriched(let subject, _): return "Added public context for \(subject)"
        case .localOnly(let application): return "Remembered \(application) locally"
        case .failed: return "Local memory will retry"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "Nothing leaves this Mac unless public enrichment is on."
        case .saving: return "Structuring the active app, document, subjects, and intent."
        case .remembered: return "Indexed in the private daily workspace memory."
        case .enriching: return "Only a generic public topic is sent to Bright Data."
        case .enriched(_, let count):
            return "Stored \(count) public source\(count == 1 ? "" : "s") beside the private memory."
        case .localOnly: return "No workspace title, path, intent, or text was sent to the web."
        case .failed: return "The observation is still present in this app's private buffer."
        }
    }
}

struct ObservationDeliveryGate: Sendable {
    private var recentFingerprints: [Int: Date] = [:]
    private var lastDelivery: Date?
    let duplicateWindow: TimeInterval
    let minimumInterval: TimeInterval

    init(duplicateWindow: TimeInterval = 120, minimumInterval: TimeInterval = 1.5) {
        self.duplicateWindow = duplicateWindow
        self.minimumInterval = minimumInterval
    }

    mutating func shouldDeliver(_ observation: WorkspaceObservation, now: Date = Date()) -> Bool {
        recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < duplicateWindow }
        if let lastDelivery, now.timeIntervalSince(lastDelivery) < minimumInterval {
            return false
        }
        var hasher = Hasher()
        hasher.combine(observation.applicationName.lowercased())
        hasher.combine(observation.bundleID?.lowercased())
        hasher.combine(observation.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        hasher.combine(observation.document?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        observation.extraction?.subjects.forEach { hasher.combine($0.lowercased()) }
        let fingerprint = hasher.finalize()
        guard recentFingerprints[fingerprint] == nil else { return false }
        recentFingerprints[fingerprint] = now
        lastDelivery = now
        return true
    }
}

enum EnrichmentActivitySubjectResolver {
    static func label(
        for subjects: [AmbientSubject],
        outboundQuery: String?
    ) -> String {
        let queryTokens = tokens(in: outboundQuery ?? "")
        guard !queryTokens.isEmpty else { return "public topic" }

        let match = subjects
            .filter { subject in
                let subjectTokens = tokens(in: subject.canonicalName)
                guard !subjectTokens.isEmpty else { return false }
                return queryTokens.starts(with: subjectTokens)
                    || contains(subjectTokens, in: queryTokens)
            }
            .max { left, right in
                if left.canonicalName.count == right.canonicalName.count {
                    return left.confidence < right.confidence
                }
                return left.canonicalName.count < right.canonicalName.count
            }

        return match?.canonicalName ?? "public topic"
    }

    private static func tokens(in value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func contains(_ needle: [String], in haystack: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        if needle.count == 1 { return haystack.contains(needle[0]) }
        return (0 ... haystack.count - needle.count).contains { offset in
            Array(haystack[offset ..< offset + needle.count]) == needle
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var composer = ""
    @Published private(set) var conversation: [ConversationEntry] = []
    @Published private(set) var checkpoints: [CheckpointRecord] = []
    @Published private(set) var isSending = false
    @Published private(set) var isSaving = false
    @Published private(set) var helperStatus = "Connecting…"
    @Published private(set) var helperIsHealthy = false
    @Published private(set) var decidedProposalIDs: Set<String> = []
    @Published private(set) var captureSuggestedTitle: String?
    @Published private(set) var voiceState: VoiceSessionState = .unavailable
    @Published private(set) var voiceStatusMessage: String?
    @Published private(set) var publicEnrichmentEnabled: Bool
    @Published private(set) var memoryActivity: MemoryActivity = .idle
    @Published private(set) var capturedObservationCount = 0
    @Published private(set) var memoryItems: [MemoryItem] = []
    @Published private(set) var memorySubjects: [MemorySubjectSummary] = []
    @Published private(set) var memoryEnrichments: [MemoryEnrichmentItem] = []
    @Published private(set) var memoryEnrichmentTotal = 0
    @Published private(set) var memoryStats = MemoryStats()
    @Published private(set) var isLoadingMemories = false
    @Published private(set) var isLoadingEarlierMemories = false
    @Published private(set) var canLoadEarlierMemories = false
    @Published private(set) var isLoadingEarlierEnrichments = false
    @Published private(set) var canLoadEarlierEnrichments = false
    @Published private(set) var memoryLibraryError: String?
    @Published private(set) var knowledgeLibraryError: String?
    @Published private(set) var deletingMemoryIDs: Set<String> = []
    @Published private(set) var providerStatus: ProviderConfigurationResponse?
    @Published var showsConnections = false
    @Published var showsMemories = false

    let recorder: WorkspaceRecorder
    let providerCredentials: ProviderCredentialManager

    private var client: AgentServicing?
    private let managesHelperConnection: Bool
    private var helperConnection: AgentConnection?
    private var voice: VoiceSessionControlling
    private let actionExecutor: SafeActionExecutor
    private let microphone: MicrophoneAuthorizing
    private let defaults: UserDefaults
    private let helperRetryDelays: [Duration]
    private var subscriptions: Set<AnyCancellable> = []
    private var observationDeliveryGate = ObservationDeliveryGate()

    private static let memoryEnabledKey = "checkpoint.memoryEnabled"
    private static let publicEnrichmentKey = "checkpoint.publicEnrichmentEnabled"
    private static let visualFallbackKey = "checkpoint.visualFallbackEnabled"

    init(
        client: AgentServicing? = nil,
        recorder: WorkspaceRecorder? = nil,
        voice: VoiceSessionControlling? = nil,
        actionExecutor: SafeActionExecutor? = nil,
        microphone: MicrophoneAuthorizing? = nil,
        providerCredentials: ProviderCredentialManager? = nil,
        defaults: UserDefaults = .standard,
        helperRetryDelays: [Duration]? = nil
    ) {
        self.client = client
        managesHelperConnection = client == nil
        self.recorder = recorder ?? WorkspaceRecorder()
        self.defaults = defaults
        self.providerCredentials = providerCredentials ?? ProviderCredentialManager(defaults: defaults)
        let storedCredentials = try? self.providerCredentials.snapshot()
        self.voice = voice ?? VoiceSessionFactory.make(credentials: storedCredentials)
        self.actionExecutor = actionExecutor ?? SafeActionExecutor()
        self.microphone = microphone ?? SystemMicrophoneAuthorizer()
        self.helperRetryDelays = helperRetryDelays ?? [
            .milliseconds(150),
            .milliseconds(300),
            .milliseconds(600),
            .seconds(1),
            .seconds(2),
            .seconds(3),
            .seconds(5),
        ]
        publicEnrichmentEnabled = defaults.bool(forKey: Self.publicEnrichmentKey)
        voiceState = self.voice.state
        voiceStatusMessage = self.voice.availabilityMessage

        installVoiceCallbacks()
        installRecorderCallbacks()

        // Restore the preference without requesting Screen Recording. Permission
        // prompts are reserved for the explicit interactive toggle path below.
        if defaults.bool(forKey: Self.visualFallbackKey) {
            self.recorder.setVisualFallbackEnabled(true)
        }

        self.recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

        self.providerCredentials.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

        if defaults.bool(forKey: Self.memoryEnabledKey) {
            self.recorder.turnMemoryOn()
        }

        Task { await connectAndLoad() }
    }

    var recentCheckpoints: [CheckpointRecord] {
        Array(checkpoints.prefix(3))
    }

    var voiceIsAvailable: Bool {
        voiceState != .unavailable
    }

    var activeVoiceStatus: String? {
        switch voiceState {
        case .connecting: return "Connecting voice…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing transcript…"
        case .unavailable, .idle: return nil
        }
    }

    func connectAndLoad() async {
        if managesHelperConnection {
            do {
                let connection = try AgentConnectionStore.load()
                if client == nil || connection != helperConnection {
                    client = URLSessionAgentClient(connection: connection)
                    helperConnection = connection
                }
            } catch {
                client = nil
                helperConnection = nil
                helperIsHealthy = false
                helperStatus = "Memory is starting"
                return
            }
        }

        guard let client else { return }
        do {
            let health = try await client.health()
            helperIsHealthy = health.status.lowercased() == "ok"
            helperStatus = helperIsHealthy ? "Memory ready" : "Memory is starting"
            if helperIsHealthy {
                await reprovisionStoredProviders(to: client)
                providerStatus = try? await client.providerStatus()
            }
            checkpoints = try await client.listCheckpoints()
            await loadMemoryLibrary(using: client, showingProgress: false)
        } catch {
            helperIsHealthy = false
            helperStatus = "Memory is starting"
        }
    }

    func completeOnboarding(publicEnrichment: Bool) {
        setPublicEnrichment(publicEnrichment)
        turnMemoryOn()
    }

    func turnMemoryOn() {
        defaults.set(true, forKey: Self.memoryEnabledKey)
        recorder.turnMemoryOn()
    }

    func pauseMemory() {
        defaults.set(false, forKey: Self.memoryEnabledKey)
        recorder.pauseMemory()
    }

    func toggleMemory() {
        recorder.memoryState == .on ? pauseMemory() : turnMemoryOn()
    }

    var visualFallbackEnabled: Bool {
        recorder.visualFallbackEnabled
    }

    var visualCaptureState: VisualCaptureAuthorizationState {
        recorder.visualCaptureState
    }

    func setVisualFallback(_ enabled: Bool) {
        guard enabled != recorder.visualFallbackEnabled else { return }
        defaults.set(enabled, forKey: Self.visualFallbackKey)
        recorder.setVisualFallbackEnabled(enabled)
        if enabled {
            // This is the only path that can prompt for Screen Recording, and it
            // runs as the immediate consequence of the consumer turning it on.
            recorder.requestVisualCaptureAccess()
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMemories() {
        showsMemories = true
        Task { await reloadMemories() }
    }

    func reloadMemories() async {
        guard let client = await healthyClient() else {
            memoryLibraryError = "Local memory is still starting. Try again in a moment."
            return
        }
        await loadMemoryLibrary(using: client, showingProgress: true)
    }

    func loadEarlierMemories() async {
        guard !isLoadingEarlierMemories,
              canLoadEarlierMemories,
              let cursor = memoryItems.last?.capturedAt?.nilIfBlank else {
            return
        }
        guard let client = await healthyClient() else {
            memoryLibraryError = "Local memory is still starting. Try again in a moment."
            return
        }

        isLoadingEarlierMemories = true
        defer { isLoadingEarlierMemories = false }
        do {
            let page = try await client.listMemoryItems(
                limit: 50,
                before: cursor,
                beforeID: memoryItems.last?.id
            )
            var knownIDs = Set(memoryItems.map(\.id))
            let earlier = page.items.filter { knownIDs.insert($0.id).inserted }
            memoryItems.append(contentsOf: earlier)
            capturedObservationCount = max(capturedObservationCount, page.total)
            canLoadEarlierMemories = !page.items.isEmpty
                && memoryItems.count < capturedObservationCount
                && memoryItems.last?.capturedAt?.nilIfBlank != nil
            memoryLibraryError = nil
        } catch {
            memoryLibraryError = "Couldn't load earlier memories. Your existing local memory is unchanged."
        }
    }

    func loadEarlierEnrichments() async {
        guard !isLoadingEarlierEnrichments,
              canLoadEarlierEnrichments,
              let cursor = memoryEnrichments.last?.checkedAt.nilIfBlank else {
            return
        }
        guard let client = await healthyClient() else {
            knowledgeLibraryError = "Local memory is still starting. Try again in a moment."
            return
        }

        isLoadingEarlierEnrichments = true
        defer { isLoadingEarlierEnrichments = false }
        do {
            let page = try await client.listMemoryEnrichments(
                limit: 25,
                before: cursor,
                beforeID: memoryEnrichments.last?.id
            )
            var knownIDs = Set(memoryEnrichments.map(\.id))
            let earlier = page.items.filter { knownIDs.insert($0.id).inserted }
            memoryEnrichments.append(contentsOf: earlier)
            memoryEnrichmentTotal = max(memoryEnrichmentTotal, page.total)
            canLoadEarlierEnrichments = !page.items.isEmpty
                && memoryEnrichments.count < memoryEnrichmentTotal
                && memoryEnrichments.last?.checkedAt.nilIfBlank != nil
            knowledgeLibraryError = nil
        } catch {
            knowledgeLibraryError = "Couldn't load earlier public knowledge. Existing results are unchanged."
        }
    }

    func deleteMemory(_ item: MemoryItem) async {
        guard !deletingMemoryIDs.contains(item.id), let client = await healthyClient() else {
            memoryLibraryError = "Local memory is still starting. Nothing was deleted."
            return
        }
        deletingMemoryIDs.insert(item.id)
        defer { deletingMemoryIDs.remove(item.id) }
        do {
            let result = try await client.deleteMemoryItem(id: item.id)
            guard result.deleted else {
                memoryLibraryError = "That memory could not be deleted."
                return
            }
            memoryItems.removeAll { $0.id == item.id }
            capturedObservationCount = max(0, capturedObservationCount - 1)
            memoryStats.totalMemories = capturedObservationCount
            memoryLibraryError = nil
            await loadMemoryLibrary(using: client, showingProgress: false)
        } catch {
            memoryLibraryError = "That memory is still safely stored. Deletion did not finish."
        }
    }

    func eraseLastFifteenMinutes() {
        let erasedCount = recorder.eraseLastFifteenMinutes()
        capturedObservationCount = max(0, capturedObservationCount - erasedCount)
        memoryActivity = .idle
        Task {
            let remoteCount: Int
            if let client = await healthyClient(),
               let result = try? await client.eraseRecent(minutes: 15) {
                remoteCount = result.observations
            } else {
                remoteCount = 0
            }
            let total = max(erasedCount, remoteCount)
            if let client = await healthyClient() {
                await loadMemoryLibrary(using: client, showingProgress: false)
            }
            appendSystemMessage(
                total == 0
                    ? "There was no recent memory to erase."
                    : "Erased the last 15 minutes from this Mac and its local index."
            )
        }
    }

    func setPublicEnrichment(_ enabled: Bool) {
        publicEnrichmentEnabled = enabled
        defaults.set(enabled, forKey: Self.publicEnrichmentKey)
    }

    func saveProvider(_ provider: ProviderKind, draft: ProviderDraft) async throws {
        try providerCredentials.save(draft, for: provider)
        refreshVoiceFromCredentials()

        guard let client = await healthyClient() else { return }
        let credentials = try providerCredentials.snapshot()
        do {
            providerStatus = try await client.configurePresentProviders(credentials)
        } catch {
            // The Keychain remains authoritative. A bundled helper can pick up
            // the saved connection on its next authenticated provision pass.
        }
    }

    func removeProvider(_ provider: ProviderKind) async throws {
        try providerCredentials.remove(provider)
        refreshVoiceFromCredentials()

        guard let client = await healthyClient() else { return }
        do {
            providerStatus = try await client.removeProvider(provider)
        } catch {
            // Removal is already complete locally even if the helper is offline.
        }
    }

    func useSuggestion(_ suggestion: String) {
        composer = suggestion
    }

    func submit() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        composer = ""
        acceptUserTurn(text, modality: .typed)
    }

    func startCapture(suggestedTitle: String? = nil) {
        captureSuggestedTitle = suggestedTitle
        recorder.start()
    }

    func cancelCapture() {
        captureSuggestedTitle = nil
        recorder.cancel()
    }

    func requestResume(_ checkpoint: CheckpointRecord) {
        let text = "Resume \"\(checkpoint.title)\""
        acceptUserTurn(text, modality: .typed)
    }

    func startVoice() {
        Task {
            switch voiceState {
            case .connecting, .listening, .finishing:
                await voice.stop()
            case .idle:
                guard await microphone.requestWhenNeeded() == .granted else {
                    appendSystemMessage(
                        "Microphone access is off. You can enable it in System Settings, or keep typing here."
                    )
                    return
                }
                do {
                    try await voice.start()
                } catch {
                    appendSystemMessage(error.localizedDescription)
                }
            case .unavailable:
                appendSystemMessage(
                    voice.availabilityMessage ?? "Voice isn't connected yet. Typing still works."
                )
            }
        }
    }

    func saveCheckpoint(title: String, summary: String, nextStep: String?) {
        guard !isSaving else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        Task {
            isSaving = true
            defer { isSaving = false }
            guard let client = await healthyClient() else {
                appendSystemMessage("Local memory isn't ready yet. Your capture is still in the preview.")
                return
            }

            let request = CreateCheckpointRequest(
                title: cleanTitle,
                summary: cleanSummary.isEmpty ? "Saved work session" : cleanSummary,
                nextStep: nextStep?.nilIfBlank,
                artifacts: recorder.artifacts
            )
            do {
                let checkpoint = try await client.createCheckpoint(request)
                upsert(checkpoint)
                recorder.finish()
                captureSuggestedTitle = nil
                conversation.append(
                    ConversationEntry(
                        content: .assistant(
                            TurnResponse(
                                kind: .resultCard,
                                message: "Saved locally. Ask for \"\(checkpoint.title)\" whenever you're ready.",
                                checkpoint: checkpoint,
                                providerDisclosure: ["Local memory"]
                            )
                        )
                    )
                )
            } catch {
                appendSystemMessage("Nothing was saved: \(error.localizedDescription)")
            }
        }
    }

    func decide(_ response: TurnResponse, decision: ProposalDecision) {
        guard let proposalID = response.proposalID else {
            appendSystemMessage("This proposal is missing its safety ID, so CHECKPOINT did not run it.")
            return
        }
        guard !decidedProposalIDs.contains(proposalID) else { return }
        decidedProposalIDs.insert(proposalID)

        Task {
            guard let client = await healthyClient() else {
                appendSystemMessage("Local memory became unavailable before anything changed.")
                return
            }
            do {
                let decided = try await client.decideProposal(id: proposalID, decision: decision)
                conversation.append(ConversationEntry(content: .assistant(decided)))
                absorb(decided)

                guard decision == .approve, !decided.proposedActions.isEmpty else { return }
                guard decided.proposalID == proposalID else {
                    appendSystemMessage("The approved proposal ID changed, so CHECKPOINT refused to run it.")
                    return
                }
                guard SafeActionValidator.matchesReviewedPlan(
                    returned: decided.proposedActions,
                    displayed: response.proposedActions
                ) else {
                    appendSystemMessage("The approved action list changed, so CHECKPOINT refused to run it.")
                    return
                }
                guard let reviewedCheckpoint = response.checkpoint else {
                    appendSystemMessage("The reviewed checkpoint was missing, so CHECKPOINT refused to run it.")
                    return
                }
                let plan = try SafeActionValidator.validate(
                    decided.proposedActions,
                    against: reviewedCheckpoint.artifacts
                )
                let results = await actionExecutor.execute(plan)
                let successes = results.filter(\.succeeded).count
                let failures = results.count - successes
                let summary = failures == 0
                    ? "Opened \(successes) saved item\(successes == 1 ? "" : "s")."
                    : "Opened \(successes) of \(results.count) saved items. \(failures) could not be opened."
                appendSystemMessage(summary)
            } catch {
                appendSystemMessage("Nothing was opened: \(error.localizedDescription)")
            }
        }
    }

    func hasDecided(_ response: TurnResponse) -> Bool {
        guard let proposalID = response.proposalID else { return false }
        return decidedProposalIDs.contains(proposalID)
    }

    private func sendTurn(_ text: String, modality: TurnModality) async {
        isSending = true
        defer { isSending = false }
        guard let client = await healthyClient() else {
            if modality == .typed, composer.isEmpty {
                composer = text
            }
            appendSystemMessage("Local memory isn't ready yet. Your request was not sent.")
            return
        }

        do {
            let response = try await client.sendTurn(
                text: text,
                modality: modality,
                allowPublicEnrichment: publicEnrichmentEnabled
            )
            conversation.append(ConversationEntry(content: .assistant(response)))
            absorb(response)
        } catch {
            appendSystemMessage("Something went wrong before anything changed. \(error.localizedDescription)")
        }
    }

    private func receiveFinalVoiceTranscript(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        acceptUserTurn(text, modality: .voice)
    }

    private func acceptUserTurn(_ text: String, modality: TurnModality) {
        conversation.append(ConversationEntry(content: .user(text)))

        if isCaptureIntent(text) {
            startCapture(suggestedTitle: suggestedCaptureTitle(from: text))
            conversation.append(
                ConversationEntry(
                    content: .assistant(
                        TurnResponse(
                            kind: .message,
                            message: "Remembering this work. Switch between the apps and pages that belong together, then choose Save."
                        )
                    )
                )
            )
            return
        }

        Task { await sendTurn(text, modality: modality) }
    }

    private func healthyClient() async -> AgentServicing? {
        for attempt in 0...helperRetryDelays.count {
            if managesHelperConnection {
                // The helper publishes a fresh bearer token on every launch. A
                // changed connection file is therefore also our process-restart
                // signal: reconnect and restore the helper's in-memory provider
                // configuration from the Keychain before sending the next turn.
                let publishedConnection = try? AgentConnectionStore.load()
                if publishedConnection != helperConnection {
                    await connectAndLoad()
                }
            }
            if client == nil || !helperIsHealthy {
                await connectAndLoad()
            }
            if helperIsHealthy {
                return client
            }
            guard attempt < helperRetryDelays.count else { break }
            do {
                try await Task.sleep(for: helperRetryDelays[attempt])
            } catch {
                return nil
            }
        }
        return nil
    }

    private func reprovisionStoredProviders(to client: AgentServicing) async {
        guard let credentials = try? providerCredentials.snapshot() else { return }
        // An empty Keychain snapshot must not erase operator credentials loaded
        // by the helper from an ignored dotenv file.
        guard credentials.containsAnyProviderValue else { return }
        do {
            providerStatus = try await client.configurePresentProviders(credentials)
        } catch {
            // Local SQLite memory remains usable with zero providers. The
            // credentials stay only in Keychain and can be retried on the next
            // helper connection without exposing their values in an error.
        }
    }

    private func absorb(_ response: TurnResponse) {
        if let checkpoint = response.checkpoint { upsert(checkpoint) }
        response.checkpoints.forEach(upsert)
    }

    private func upsert(_ checkpoint: CheckpointRecord) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.insert(checkpoint, at: 0)
    }

    private func appendSystemMessage(_ message: String) {
        conversation.append(
            ConversationEntry(
                content: .assistant(TurnResponse(kind: .message, message: message))
            )
        )
    }

    private func isCaptureIntent(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return normalized.hasPrefix("checkpoint this")
            || normalized == "save where i am"
            || normalized.hasPrefix("remember this")
    }

    private func suggestedCaptureTitle(from text: String) -> String? {
        guard let range = text.range(of: " as ", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let suggestion = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return suggestion.isEmpty ? nil : suggestion
    }

    private func installVoiceCallbacks() {
        voice.onFinalTranscript = { [weak self] transcript in
            self?.receiveFinalVoiceTranscript(transcript)
        }
        voice.onStateChange = { [weak self] state, message in
            self?.voiceState = state
            self?.voiceStatusMessage = message
        }
    }

    private func installRecorderCallbacks() {
        recorder.onObservationReady = { [weak self] observation in
            self?.queuePassiveObservation(observation)
        }
    }

    private func queuePassiveObservation(_ observation: WorkspaceObservation) {
        guard recorder.memoryState == .on,
              observationDeliveryGate.shouldDeliver(observation) else {
            return
        }
        memoryActivity = .saving(application: observation.applicationName)

        Task {
            guard let client = await healthyClient() else {
                memoryActivity = .failed
                return
            }
            do {
                let saved = try await client.saveObservation(
                    ObservationUploadRequest(
                        observation: observation,
                        allowPublicEnrichment: publicEnrichmentEnabled
                    )
                )
                capturedObservationCount += 1
                if capturedObservationCount == 1 {
                    checkpoints = try await client.listCheckpoints()
                }
                if showsMemories {
                    await loadMemoryLibrary(using: client, showingProgress: false)
                }

                guard publicEnrichmentEnabled,
                      providerStatus?.brightData == "ready" else {
                    memoryActivity = providerStatus?.brightData == "ready"
                        ? .remembered(application: observation.applicationName)
                        : .localOnly(application: observation.applicationName)
                    return
                }

                if let result = saved.enrichment,
                   result.status == "complete" || result.status == "cached" {
                    let subject = EnrichmentActivitySubjectResolver.label(
                        for: observation.extraction?.structuredSubjects ?? [],
                        outboundQuery: result.outboundQuery
                    )
                    memoryActivity = .enriched(
                        subject: subject,
                        sourceCount: result.sources.count
                    )
                } else {
                    memoryActivity = .remembered(application: observation.applicationName)
                }
                if showsMemories {
                    await loadMemoryLibrary(using: client, showingProgress: false)
                }
            } catch {
                // Keep failures deliberately non-specific: provider and network
                // errors can otherwise echo credential-bearing URLs.
                memoryActivity = .failed
            }
        }
    }

    private func loadMemoryLibrary(
        using client: AgentServicing,
        showingProgress: Bool
    ) async {
        if showingProgress { isLoadingMemories = true }
        defer { isLoadingMemories = false }
        do {
            async let pageRequest = client.listMemoryItems(
                limit: 50,
                before: nil,
                beforeID: nil
            )
            async let statsRequest = client.memoryStats()
            async let subjectRequest = try? client.listMemorySubjects(limit: 24)
            async let enrichmentRequest = try? client.listMemoryEnrichments(
                limit: 25,
                before: nil,
                beforeID: nil
            )
            let (page, stats, subjects, enrichments) = try await (
                pageRequest, statsRequest, subjectRequest, enrichmentRequest
            )
            memoryItems = page.items
            memoryStats = stats
            memorySubjects = subjects?.subjects ?? []
            capturedObservationCount = max(page.total, stats.totalMemories)
            canLoadEarlierMemories = !page.items.isEmpty
                && page.items.count < capturedObservationCount
                && page.items.last?.capturedAt?.nilIfBlank != nil
            memoryLibraryError = nil
            if let enrichments {
                memoryEnrichments = enrichments.items
                memoryEnrichmentTotal = enrichments.total
                canLoadEarlierEnrichments = !enrichments.items.isEmpty
                    && enrichments.items.count < enrichments.total
                    && enrichments.items.last?.checkedAt.nilIfBlank != nil
                knowledgeLibraryError = nil
            } else {
                // Public knowledge has an independent timeline. Preserve its
                // last good snapshot if only this endpoint is temporarily down.
                knowledgeLibraryError = "Couldn't refresh expanded knowledge. Existing results are unchanged."
            }
        } catch {
            // Preserve the last successful snapshot. A transient helper restart
            // must not make remembered moments visually disappear.
            memoryLibraryError = "Couldn't refresh memories. Your existing local memory is unchanged."
        }
    }

    private func refreshVoiceFromCredentials() {
        guard voiceState == .idle || voiceState == .unavailable else { return }
        let credentials = try? providerCredentials.snapshot()
        voice = VoiceSessionFactory.make(credentials: credentials)
        voiceState = voice.state
        voiceStatusMessage = voice.availabilityMessage
        installVoiceCallbacks()
    }

}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension ProviderCredentials {
    var containsAnyProviderValue: Bool {
        [
            brightDataAPIKey,
            mossProjectID,
            mossProjectKey,
            openAIAPIKey,
            liveKitURL,
            liveKitAPIKey,
            liveKitAPISecret,
            liveKitSandboxID,
            liveKitAgentName,
        ].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
