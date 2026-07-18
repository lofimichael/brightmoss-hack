import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import CheckpointApp

final class AmbientCaptureTests: XCTestCase {
    func testPrivacyPolicyBlocksCategoricallyPrivateAppsBeforeCapture() {
        let cases: [(AmbientCapturePrivacyContext, AmbientCaptureBlockReason)] = [
            (
                AmbientCapturePrivacyContext(
                    applicationName: "1Password",
                    bundleID: "com.1password.1password",
                    windowTitle: nil,
                    document: nil
                ),
                .passwordManager
            ),
            (
                AmbientCapturePrivacyContext(
                    applicationName: "Signal",
                    bundleID: "org.whispersystems.signal-desktop",
                    windowTitle: nil,
                    document: nil
                ),
                .privateMessaging
            ),
            (
                AmbientCapturePrivacyContext(
                    applicationName: "CHECKPOINT",
                    bundleID: "app.checkpoint.desktop",
                    windowTitle: nil,
                    document: nil
                ),
                .checkpoint
            ),
        ]

        for (context, reason) in cases {
            XCTAssertEqual(AmbientCapturePrivacyPolicy.evaluate(context), .blocked(reason))
        }
    }

    func testPrivacyPolicyFailsClosedForPrivateAuthAndFinancialWindows() {
        XCTAssertEqual(
            AmbientCapturePrivacyPolicy.evaluate(
                AmbientCapturePrivacyContext(
                    applicationName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Private Browsing — Apple",
                    document: "https://apple.com"
                )
            ).reason,
            .privateBrowsing
        )
        XCTAssertEqual(
            AmbientCapturePrivacyPolicy.evaluate(
                AmbientCapturePrivacyContext(
                    applicationName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Enter your verification code",
                    document: "https://example.com"
                )
            ).reason,
            .authentication
        )
        XCTAssertEqual(
            AmbientCapturePrivacyPolicy.evaluate(
                AmbientCapturePrivacyContext(
                    applicationName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Dashboard",
                    document: "https://secure.chase.com/accounts"
                )
            ).reason,
            .financial
        )
        XCTAssertEqual(
            AmbientCapturePrivacyPolicy.evaluate(
                AmbientCapturePrivacyContext(
                    applicationName: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Continue",
                    document: "https://accounts.example.com/v3/signin/identifier"
                )
            ).reason,
            .authentication
        )
        XCTAssertTrue(
            AmbientCapturePrivacyPolicy.evaluate(
                AmbientCapturePrivacyContext(
                    applicationName: "Xcode",
                    bundleID: "com.apple.dt.Xcode",
                    windowTitle: "AmbientCapture.swift",
                    document: "/tmp/AmbientCapture.swift"
                )
            ).isAllowed
        )
    }

    func testAccessibilityWalkerExcludesSecureValuesAndHonorsBounds() {
        struct Node {
            var role: String
            var subrole: String?
            var title: String?
            var value: String?
            var children: [Int]
        }
        let nodes: [Int: Node] = [
            0: Node(role: "AXWindow", title: "Editor", children: [1, 2, 3]),
            1: Node(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                title: "Password",
                value: "super-secret-password",
                children: [4]
            ),
            2: Node(role: "AXStaticText", title: nil, value: "Visible project context", children: []),
            3: Node(role: "AXGroup", title: nil, value: nil, children: [5]),
            4: Node(role: "AXStaticText", title: nil, value: "nested secret", children: []),
            5: Node(role: "AXStaticText", title: nil, value: String(repeating: "x", count: 200), children: []),
        ]
        let collector = BoundedAccessibilityTextCollector<Int>(
            bounds: AccessibilityTextBounds(
                maximumDepth: 2,
                maximumNodes: 5,
                maximumCharacters: 60,
                maximumCharactersPerValue: 40
            )
        )

        let result = collector.collect(root: 0) { identifier in
            let node = nodes[identifier]!
            return AccessibilityNodeContent(
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                value: node.value,
                nodeDescription: nil,
                help: nil,
                children: node.children
            )
        }

        XCTAssertTrue(result.text.contains("Visible project context"))
        XCTAssertFalse(result.text.contains("super-secret"))
        XCTAssertFalse(result.text.contains("nested secret"))
        XCTAssertLessThanOrEqual(result.visitedNodeCount, 5)
        XCTAssertLessThanOrEqual(result.text.count, 60)
        XCTAssertTrue(result.wasTruncated)
    }

    @MainActor
    func testDeterministicExtractorProducesStructuredBoundedSubjects() async {
        let extractor = DeterministicAmbientSubjectExtractor()
        let result = await extractor.extract(
            from: AmbientObservationInput(
                applicationName: "Xcode",
                windowTitle: "LiveKit SwiftUI client — CHECKPOINT",
                document: "/tmp/VoiceClient.swift",
                visibleText: "Building a SwiftUI LiveKit voice client with local OCR retrieval",
                extractionMethod: .accessibility
            )
        )

        XCTAssertEqual(result.extractionMethod, .accessibility)
        XCTAssertEqual(result.subjects, result.structuredSubjects.map(\.canonicalName))
        XCTAssertLessThanOrEqual(result.structuredSubjects.count, 5)
        XCTAssertTrue(result.structuredSubjects.contains { $0.kind == .technology })
        XCTAssertTrue(result.structuredSubjects.allSatisfy { !$0.keywords.isEmpty && $0.keywords.count <= 8 })
    }

    @MainActor
    func testDeterministicPublicSubjectsNeverPromotePrivateTitlePhrases() async {
        let result = await DeterministicAmbientSubjectExtractor().extract(
            from: AmbientObservationInput(
                applicationName: "Safari",
                windowTitle: "LiveKit token auth — secret-project",
                document: nil,
                visibleText: nil,
                extractionMethod: .accessibility
            )
        )
        let outboundEligibleKinds: Set<AmbientSubjectKind> = [
            .technology, .product, .company, .publicDocumentation, .academicTopic,
        ]
        let eligible = result.structuredSubjects
            .filter { outboundEligibleKinds.contains($0.kind) && $0.confidence >= 0.75 }
        let eligibleNames = eligible.map { $0.canonicalName.lowercased() }

        XCTAssertTrue(eligibleNames.contains("livekit"))
        XCTAssertFalse(eligibleNames.contains(where: { $0.contains("token auth") }))
        XCTAssertFalse(eligibleNames.contains(where: { $0.contains("secret-project") }))
        let eligibleKeywords = eligible.flatMap(\.keywords).map { $0.lowercased() }
        XCTAssertFalse(eligibleKeywords.contains("token"))
        XCTAssertFalse(eligibleKeywords.contains("auth"))
        XCTAssertFalse(eligibleKeywords.contains("secret"))
        XCTAssertFalse(eligibleKeywords.contains("project"))
    }

    func testDeduplicatorRestrainsPollingAndRepeatedContent() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = AmbientCaptureDeduplicator(pollInterval: 8, duplicateWindow: 120)

        XCTAssertTrue(gate.shouldPoll(at: start))
        XCTAssertFalse(gate.shouldPoll(at: start.addingTimeInterval(4)))
        XCTAssertTrue(gate.shouldPoll(at: start.addingTimeInterval(8)))

        XCTAssertTrue(gate.shouldRecord(fingerprint: "A", at: start))
        XCTAssertFalse(gate.shouldRecord(fingerprint: "A", at: start.addingTimeInterval(9)))
        XCTAssertTrue(gate.shouldRecord(fingerprint: "B", at: start.addingTimeInterval(10)))
        XCTAssertFalse(gate.shouldRecord(fingerprint: "A", at: start.addingTimeInterval(60)))
        XCTAssertTrue(gate.shouldRecord(fingerprint: "A", at: start.addingTimeInterval(121)))
    }

    func testVolatileMemoryBufferKeepsOnlyNewestBoundedObservations() {
        var buffer = WorkspaceMemoryBuffer(maximumObservations: 2)
        for index in 0 ..< 3 {
            let artifact = CapturedArtifact(
                id: "artifact-\(index)",
                kind: .app,
                displayName: "App \(index)"
            )
            buffer.append(
                observation: WorkspaceObservation(
                    id: "observation-\(index)",
                    capturedAt: Date(timeIntervalSince1970: Double(index)),
                    applicationName: "App \(index)",
                    bundleID: nil,
                    windowTitle: nil,
                    document: nil,
                    artifactIDs: [artifact.id]
                ),
                artifacts: [artifact]
            )
        }

        XCTAssertEqual(buffer.observations.map(\.id), ["observation-1", "observation-2"])
        XCTAssertEqual(buffer.uniqueArtifacts.map(\.id), ["artifact-1", "artifact-2"])
    }

    func testWindowSelectionNeverFallsBackToAnotherProcessWindow() {
        let target = VisualCaptureTarget(processIdentifier: 10, windowTitle: "Reviewed window")
        let windows = [
            VisualWindowDescriptor(
                windowID: 1,
                processIdentifier: 10,
                title: "Authentication secrets",
                frame: CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
            ),
            VisualWindowDescriptor(
                windowID: 2,
                processIdentifier: 10,
                title: "Something else",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
        ]

        XCTAssertNil(VisualWindowSelector.selectWindowID(from: windows, target: target))
        var matching = windows
        matching.append(
            VisualWindowDescriptor(
                windowID: 3,
                processIdentifier: 10,
                title: "  REVIEWED   WINDOW ",
                frame: CGRect(x: 0, y: 0, width: 900, height: 700)
            )
        )
        XCTAssertEqual(VisualWindowSelector.selectWindowID(from: matching, target: target), 3)
        XCTAssertNil(
            VisualWindowSelector.selectWindowID(
                from: windows,
                target: VisualCaptureTarget(processIdentifier: 10, windowTitle: nil)
            )
        )
    }

    func testVisualCaptureSizeBoundsBothAxesAndTotalPixels() {
        for frame in [
            CGRect(x: 0, y: 0, width: 10_000, height: 300),
            CGRect(x: 0, y: 0, width: 300, height: 10_000),
            CGRect(x: 0, y: 0, width: 8_000, height: 8_000),
            CGRect(x: 0, y: 0, width: 1_200, height: 800),
        ] {
            let size = VisualCaptureSizing.pixelSize(for: frame)
            XCTAssertLessThanOrEqual(Int(size.width), VisualCaptureSizing.maximumWidth)
            XCTAssertLessThanOrEqual(Int(size.height), VisualCaptureSizing.maximumHeight)
            XCTAssertLessThanOrEqual(
                Int(size.width * size.height),
                VisualCaptureSizing.maximumPixels
            )
        }
    }

    func testOCRIsOnlyUsedAsEnabledReadyThinAccessibilityFallback() async {
        let capture = MockVisualTextCapture(
            authorizationState: .ready,
            recognizedText: "Canvas based research dashboard\nLiveKit retrieval graph"
        )
        let resolver = AmbientContentResolver(minimumAccessibilityCharacters: 80)
        let target = VisualCaptureTarget(processIdentifier: 42, windowTitle: "Canvas")

        let result = await resolver.resolve(
            snapshot: AccessibilitySnapshot(windowTitle: "Canvas", visibleText: "Canvas"),
            target: target,
            visualFallbackEnabled: true,
            visualCapture: capture
        )

        XCTAssertEqual(result.extractionMethod, .ocr)
        XCTAssertTrue(result.text?.contains("LiveKit retrieval graph") == true)
        XCTAssertEqual(capture.recognitionCount, 1)
        XCTAssertEqual(capture.permissionRequestCount, 0)

        let richText = String(repeating: "Accessible context ", count: 10)
        let accessible = await resolver.resolve(
            snapshot: AccessibilitySnapshot(windowTitle: "Editor", visibleText: richText),
            target: target,
            visualFallbackEnabled: true,
            visualCapture: capture
        )
        XCTAssertEqual(accessible.extractionMethod, .accessibility)
        XCTAssertEqual(capture.recognitionCount, 1)
        XCTAssertEqual(capture.permissionRequestCount, 0)
    }
}

private final class MockVisualTextCapture: VisualTextCapturing, @unchecked Sendable {
    var authorizationState: VisualCaptureAuthorizationState
    var recognizedText: String?
    private(set) var recognitionCount = 0
    private(set) var permissionRequestCount = 0

    init(authorizationState: VisualCaptureAuthorizationState, recognizedText: String?) {
        self.authorizationState = authorizationState
        self.recognizedText = recognizedText
    }

    func requestAccess() -> VisualCaptureAuthorizationState {
        permissionRequestCount += 1
        return authorizationState
    }

    func recognizeFrontWindowText(for target: VisualCaptureTarget) async -> String? {
        _ = target
        recognitionCount += 1
        return recognizedText
    }
}
