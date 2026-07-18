import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct AccessibilitySnapshot: Equatable, Sendable {
    var windowTitle: String?
    var document: String?
    var visibleText: String?
    var visitedNodeCount: Int
    var wasTruncated: Bool

    init(
        windowTitle: String? = nil,
        document: String? = nil,
        visibleText: String? = nil,
        visitedNodeCount: Int = 0,
        wasTruncated: Bool = false
    ) {
        self.windowTitle = windowTitle
        self.document = document
        self.visibleText = visibleText
        self.visitedNodeCount = visitedNodeCount
        self.wasTruncated = wasTruncated
    }
}

@MainActor
protocol AccessibilityMetadataProviding: AnyObject {
    var isTrusted: Bool { get }
    func requestAccess()
    func snapshot(for application: NSRunningApplication) -> AccessibilitySnapshot
}

@MainActor
final class SystemAccessibilityMetadataProvider: AccessibilityMetadataProviding {
    private let bounds: AccessibilityTextBounds

    init(bounds: AccessibilityTextBounds = AccessibilityTextBounds()) {
        self.bounds = bounds
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func snapshot(for application: NSRunningApplication) -> AccessibilitySnapshot {
        guard isTrusted else { return AccessibilitySnapshot() }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, from: appElement) else {
            return AccessibilitySnapshot()
        }

        let collection = BoundedAccessibilityTextCollector<AXUIElement>(bounds: bounds).collect(
            root: window
        ) { [weak self] element in
            guard let self else {
                return AccessibilityNodeContent(children: [])
            }
            let role = stringAttribute(kAXRoleAttribute, from: element)
            let subrole = stringAttribute(kAXSubroleAttribute, from: element)
            let title = stringAttribute(kAXTitleAttribute, from: element)
            let nodeDescription = stringAttribute(kAXDescriptionAttribute, from: element)
            let isSensitive = BoundedAccessibilityTextCollector<AXUIElement>.isSecure(
                role: role,
                subrole: subrole
            ) || BoundedAccessibilityTextCollector<AXUIElement>.hasSensitiveLabel(title)
                || BoundedAccessibilityTextCollector<AXUIElement>.hasSensitiveLabel(nodeDescription)
            return AccessibilityNodeContent(
                role: role,
                subrole: subrole,
                title: title,
                // Never request AXValue or descendants from a secure/password node.
                value: isSensitive ? nil : stringAttribute(kAXValueAttribute, from: element),
                nodeDescription: nodeDescription,
                help: isSensitive ? nil : stringAttribute(kAXHelpAttribute, from: element),
                children: isSensitive ? [] : elementArrayAttribute(kAXChildrenAttribute, from: element)
            )
        }

        return AccessibilitySnapshot(
            windowTitle: stringAttribute(kAXTitleAttribute, from: window),
            document: stringAttribute(kAXDocumentAttribute, from: window),
            visibleText: AmbientTextPrivacyFilter.sanitize(
                collection.text,
                maximumCharacters: bounds.maximumCharacters
            ),
            visitedNodeCount: collection.visitedNodeCount,
            wasTruncated: collection.wasTruncated
        )
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return Array(values.prefix(64))
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }
}

enum MemoryState: String, Codable, Equatable, Sendable {
    case on
    case paused
}

struct WorkspaceObservation: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var capturedAt: Date
    var applicationName: String
    var bundleID: String?
    var windowTitle: String?
    var document: String?
    var extractedText: String?
    var extractionMethod: AmbientExtractionMethod
    var artifactIDs: [String]
    var extraction: AmbientExtraction?

    init(
        id: String = UUID().uuidString,
        capturedAt: Date = Date(),
        applicationName: String,
        bundleID: String?,
        windowTitle: String?,
        document: String?,
        extractedText: String? = nil,
        extractionMethod: AmbientExtractionMethod = .metadata,
        artifactIDs: [String],
        extraction: AmbientExtraction? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.document = document
        self.extractedText = extractedText
        self.extractionMethod = extractionMethod
        self.artifactIDs = artifactIDs
        self.extraction = extraction
    }
}

struct WorkspaceMemoryBuffer: Equatable, Sendable {
    private(set) var observations: [WorkspaceObservation] = []
    private(set) var artifactEvents: [(capturedAt: Date, artifact: CapturedArtifact)] = []
    let maximumObservations: Int

    init(maximumObservations: Int = 200) {
        self.maximumObservations = max(1, maximumObservations)
    }

    static func == (left: WorkspaceMemoryBuffer, right: WorkspaceMemoryBuffer) -> Bool {
        left.observations == right.observations
            && left.artifactEvents.map { $0.capturedAt } == right.artifactEvents.map { $0.capturedAt }
            && left.artifactEvents.map { $0.artifact } == right.artifactEvents.map { $0.artifact }
    }

    mutating func append(
        observation: WorkspaceObservation,
        artifacts: [CapturedArtifact]
    ) {
        observations.append(observation)
        artifactEvents.append(contentsOf: artifacts.map { (observation.capturedAt, $0) })
        let overflow = observations.count - maximumObservations
        if overflow > 0 {
            let removedArtifactIDs = Set(
                observations.prefix(overflow).flatMap(\.artifactIDs)
            )
            observations.removeFirst(overflow)
            artifactEvents.removeAll { removedArtifactIDs.contains($0.artifact.id) }
        }
    }

    mutating func setExtraction(_ extraction: AmbientExtraction, observationID: String) {
        guard let index = observations.firstIndex(where: { $0.id == observationID }) else { return }
        observations[index].extraction = extraction
    }

    @discardableResult
    mutating func erase(since cutoff: Date) -> Int {
        let erasedObservationIDs = Set(
            observations.lazy.filter { $0.capturedAt >= cutoff }.map(\.id)
        )
        observations.removeAll { erasedObservationIDs.contains($0.id) }
        artifactEvents.removeAll { $0.capturedAt >= cutoff }
        return erasedObservationIDs.count
    }

    mutating func removeArtifact(id: String) {
        artifactEvents.removeAll { $0.artifact.id == id }
        for index in observations.indices {
            observations[index].artifactIDs.removeAll { $0 == id }
        }
    }

    var uniqueArtifacts: [CapturedArtifact] {
        var seen: Set<String> = []
        return artifactEvents.reversed().compactMap { event in
            let artifact = event.artifact
            let key: String
            switch artifact.kind {
            case .app: key = "app:\(artifact.bundleID ?? artifact.displayName)"
            case .file, .url: key = "\(artifact.kind.rawValue):\(artifact.resource ?? artifact.displayName)"
            case .selection, .note: key = "\(artifact.kind.rawValue):\(artifact.capturedText ?? artifact.displayName)"
            }
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return artifact
        }.reversed()
    }
}

@MainActor
final class WorkspaceRecorder: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case remembering
        case preview
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var memoryState: MemoryState = .paused
    @Published private(set) var artifacts: [CapturedArtifact] = []
    @Published private(set) var recentObservations: [WorkspaceObservation] = []
    @Published private(set) var visualFallbackEnabled = false
    @Published private(set) var visualCaptureState: VisualCaptureAuthorizationState

    /// Fired only after bounded local text and subject extraction finish. A
    /// transient visual fallback may exist in memory during Vision OCR, but no
    /// pixels are ever encoded, written, cached, or attached here.
    var onObservationReady: ((WorkspaceObservation) -> Void)?

    let accessibility: AccessibilityMetadataProviding
    let extractor: AmbientSubjectExtracting

    private let visualCapture: VisualTextCapturing
    private let contentResolver: AmbientContentResolver
    private let pollingInterval: TimeInterval
    private var buffer = WorkspaceMemoryBuffer()
    private var deduplicator: AmbientCaptureDeduplicator
    private var isObserving = false
    private var captureInFlight = false
    private var pollTimer: Timer?

    init(
        accessibility: AccessibilityMetadataProviding? = nil,
        extractor: AmbientSubjectExtracting? = nil,
        visualCapture: VisualTextCapturing? = nil,
        pollingInterval: TimeInterval = 8
    ) {
        let resolvedVisualCapture = visualCapture ?? SystemVisualTextCapture()
        self.accessibility = accessibility ?? SystemAccessibilityMetadataProvider()
        self.extractor = extractor ?? AmbientSubjectExtractorFactory.make()
        self.visualCapture = resolvedVisualCapture
        visualCaptureState = resolvedVisualCapture.authorizationState
        self.pollingInterval = max(4, pollingInterval)
        deduplicator = AmbientCaptureDeduplicator(pollInterval: max(4, pollingInterval))
        contentResolver = AmbientContentResolver()
        super.init()
    }

    deinit {
        pollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var isRemembering: Bool { phase == .remembering }
    var extractionLabel: String { extractor.source.consumerLabel }

    func turnMemoryOn() {
        guard memoryState != .on else { return }
        memoryState = .on
        refreshVisualCaptureState()
        beginObserving()
        captureFrontmostNow()
    }

    func pauseMemory() {
        guard memoryState != .paused else { return }
        memoryState = .paused
        endObservingIfUnneeded()
    }

    func setVisualFallbackEnabled(_ enabled: Bool) {
        visualFallbackEnabled = enabled
        refreshVisualCaptureState()
    }

    /// The sole recorder entry point that can display the Screen Recording TCC
    /// prompt. Enabling the preference itself is intentionally side-effect-free.
    func requestVisualCaptureAccess() {
        visualCaptureState = visualCapture.requestAccess()
    }

    func refreshVisualCaptureState() {
        visualCaptureState = visualCapture.authorizationState
    }

    func eraseLastFifteenMinutes(now: Date = Date()) -> Int {
        let count = buffer.erase(since: now.addingTimeInterval(-15 * 60))
        publishBuffer()
        return count
    }

    // Explicit checkpoints remain available through natural-language commands,
    // but passive memory no longer requires entering this mode.
    func start() {
        guard phase == .idle else { return }
        phase = .remembering
        beginObserving()
        captureFrontmostNow()
    }

    func showPreview() {
        guard phase == .remembering else { return }
        phase = .preview
        endObservingIfUnneeded()
    }

    func resumeRemembering() {
        guard phase == .preview else { return }
        phase = .remembering
        beginObserving()
    }

    func finish() {
        phase = .idle
        endObservingIfUnneeded()
    }

    func cancel() {
        finish()
    }

    func removeArtifact(id: String) {
        buffer.removeArtifact(id: id)
        publishBuffer()
    }

    func captureFrontmostNow() {
        guard isCaptureActive,
              let application = NSWorkspace.shared.frontmostApplication else {
            return
        }
        record(application)
    }

    func requestAccessibility() {
        accessibility.requestAccess()
    }

    private var isCaptureActive: Bool {
        memoryState == .on || phase == .remembering
    }

    private func beginObserving() {
        guard !isObserving else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        let timer = Timer(
            timeInterval: pollingInterval,
            target: self,
            selector: #selector(pollFrontmostApplication),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        isObserving = true
    }

    private func endObservingIfUnneeded() {
        guard isObserving, memoryState == .paused, phase != .remembering else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        pollTimer?.invalidate()
        pollTimer = nil
        isObserving = false
    }

    @objc private func pollFrontmostApplication() {
        guard isCaptureActive, deduplicator.shouldPoll(),
              let application = NSWorkspace.shared.frontmostApplication else { return }
        refreshVisualCaptureState()
        record(application)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard isCaptureActive,
              let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        record(application)
    }

    private func record(_ application: NSRunningApplication) {
        guard !captureInFlight else { return }

        let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
        let bundleID = application.bundleIdentifier
        let preliminary = AmbientCapturePrivacyPolicy.evaluate(
            AmbientCapturePrivacyContext(
                applicationName: appName,
                bundleID: bundleID,
                windowTitle: nil,
                document: nil
            )
        )
        // Do not even traverse Accessibility for categorically private apps.
        guard preliminary.isAllowed else { return }

        let snapshot = accessibility.snapshot(for: application)
        let decision = AmbientCapturePrivacyPolicy.evaluate(
            AmbientCapturePrivacyContext(
                applicationName: appName,
                bundleID: bundleID,
                windowTitle: snapshot.windowTitle,
                document: snapshot.document
            )
        )
        guard decision.isAllowed else { return }

        captureInFlight = true
        let target = VisualCaptureTarget(
            processIdentifier: application.processIdentifier,
            windowTitle: snapshot.windowTitle
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await contentResolver.resolve(
                snapshot: snapshot,
                target: target,
                visualFallbackEnabled: visualFallbackEnabled,
                visualCapture: visualCapture
            )
            captureInFlight = false
            guard isCaptureActive else { return }
            commitObservation(
                applicationName: appName,
                bundleID: bundleID,
                snapshot: snapshot,
                resolved: resolved
            )
        }
    }

    private func commitObservation(
        applicationName: String,
        bundleID: String?,
        snapshot: AccessibilitySnapshot,
        resolved: AmbientResolvedContent
    ) {
        let fingerprint = Self.fingerprint(
            applicationName: applicationName,
            bundleID: bundleID,
            windowTitle: snapshot.windowTitle,
            document: snapshot.document,
            extractedText: resolved.text
        )
        guard deduplicator.shouldRecord(fingerprint: fingerprint) else { return }

        let capturedAt = Date()
        var eventArtifacts: [CapturedArtifact] = []
        let displayName = snapshot.windowTitle.flatMap { title in
            title.isEmpty ? nil : "\(applicationName) — \(title)"
        } ?? applicationName
        eventArtifacts.append(
            CapturedArtifact(
                kind: .app,
                displayName: displayName,
                bundleID: bundleID,
                capturedText: snapshot.windowTitle
            )
        )

        if let document = snapshot.document?.trimmingCharacters(in: .whitespacesAndNewlines),
           !document.isEmpty {
            if let url = URL(string: document),
               url.scheme?.lowercased() == "https",
               url.user == nil,
               url.password == nil {
                eventArtifacts.append(
                    CapturedArtifact(kind: .url, displayName: url.host ?? document, resource: url.absoluteString)
                )
            } else {
                let fileURL: URL?
                if let url = URL(string: document), url.isFileURL {
                    fileURL = url
                } else if document.hasPrefix("/") {
                    fileURL = URL(fileURLWithPath: document)
                } else {
                    fileURL = nil
                }
                if let fileURL {
                    eventArtifacts.append(
                        CapturedArtifact(
                            kind: .file,
                            displayName: fileURL.lastPathComponent,
                            resource: fileURL.standardizedFileURL.path
                        )
                    )
                }
            }
        }

        let observation = WorkspaceObservation(
            capturedAt: capturedAt,
            applicationName: applicationName,
            bundleID: bundleID,
            windowTitle: snapshot.windowTitle,
            document: snapshot.document,
            extractedText: resolved.text,
            extractionMethod: resolved.extractionMethod,
            artifactIDs: eventArtifacts.map(\.id)
        )
        buffer.append(observation: observation, artifacts: eventArtifacts)
        publishBuffer()

        let input = AmbientObservationInput(
            applicationName: applicationName,
            windowTitle: snapshot.windowTitle,
            document: snapshot.document,
            visibleText: resolved.text,
            extractionMethod: resolved.extractionMethod
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let extraction = await extractor.extract(from: input)
            buffer.setExtraction(extraction, observationID: observation.id)
            publishBuffer()
            if let enrichedObservation = buffer.observations.first(where: { $0.id == observation.id }) {
                onObservationReady?(enrichedObservation)
            }
        }
    }

    private static func fingerprint(
        applicationName: String,
        bundleID: String?,
        windowTitle: String?,
        document: String?,
        extractedText: String?
    ) -> String {
        let normalized = [applicationName, bundleID, windowTitle, document, extractedText]
            .map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func publishBuffer() {
        artifacts = buffer.uniqueArtifacts
        recentObservations = buffer.observations.sorted { $0.capturedAt > $1.capturedAt }
    }
}
