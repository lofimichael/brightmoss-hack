import Darwin
import Foundation
import XCTest
@testable import CheckpointApp

final class ModelsAndSafetyTests: XCTestCase {
    func testVoiceConfigurationNeedsOnlyTokenServerIDAndDefaultsAgentName() {
        XCTAssertNil(LiveKitVoiceConfiguration.load(environment: [:], infoDictionary: [:]))
        XCTAssertEqual(
            LiveKitVoiceConfiguration.load(
                environment: ["LIVEKIT_SANDBOX_ID": "sandbox-only"],
                infoDictionary: [:]
            ),
            LiveKitVoiceConfiguration(sandboxID: "sandbox-only", agentName: "checkpoint")
        )
        XCTAssertNil(
            LiveKitVoiceConfiguration.load(
                environment: [
                    "LIVEKIT_SANDBOX_ID": "your-livekit-sandbox-id",
                    "LIVEKIT_AGENT_NAME": "checkpoint-agent",
                ],
                infoDictionary: [:]
            )
        )

        XCTAssertEqual(
            LiveKitVoiceConfiguration.load(
                environment: [
                    "LIVEKIT_SANDBOX_ID": "sandbox-123",
                    "LIVEKIT_AGENT_NAME": "checkpoint-agent",
                ],
                infoDictionary: [:]
            ),
            LiveKitVoiceConfiguration(sandboxID: "sandbox-123", agentName: "checkpoint-agent")
        )
    }

    func testVoiceConfigurationCanComeFromPackagedInfoDictionary() {
        XCTAssertEqual(
            LiveKitVoiceConfiguration.load(
                environment: [:],
                infoDictionary: [
                    "LiveKitSandboxId": "packaged-sandbox",
                    "LiveKitAgentName": "packaged-agent",
                ]
            ),
            LiveKitVoiceConfiguration(sandboxID: "packaged-sandbox", agentName: "packaged-agent")
        )
    }

    @MainActor
    func testVoiceFactoryDefaultsToNativeOnDeviceSpeechWithoutLiveKitConfiguration() {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: true)

        let voice = VoiceSessionFactory.make(
            environment: [:],
            infoDictionary: [:],
            localRecognizer: recognizer
        )

        XCTAssertTrue(voice is NativeMacOSVoiceSession)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recognizer.authorizationRequestCount, 0)
    }

    @MainActor
    func testVoiceFactoryKeepsConfiguredLiveKitAsTheOptionalTransport() {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: true)

        let voice = VoiceSessionFactory.make(
            environment: ["LIVEKIT_SANDBOX_ID": "configured-token-server"],
            infoDictionary: [:],
            localRecognizer: recognizer
        )

        XCTAssertTrue(voice is LiveKitVoiceSession)
        XCTAssertEqual(recognizer.authorizationRequestCount, 0)
    }

    @MainActor
    func testSystemSpeechRequestForbidsServerRecognitionFallback() {
        let request = SystemOnDeviceSpeechRecognizer.makeRecognitionRequest()

        XCTAssertTrue(request.requiresOnDeviceRecognition)
    }

    @MainActor
    func testNativeVoiceDefersAuthorizationAndPublishesOnlyFinalTranscript() async throws {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: true, permission: .granted)
        let voice = NativeMacOSVoiceSession(recognizer: recognizer)
        var states: [VoiceSessionState] = []
        var transcripts: [String] = []
        voice.onStateChange = { state, _ in states.append(state) }
        voice.onFinalTranscript = { transcripts.append($0) }

        XCTAssertEqual(recognizer.authorizationRequestCount, 0)
        try await voice.start()

        XCTAssertEqual(recognizer.authorizationRequestCount, 1)
        XCTAssertEqual(recognizer.startCount, 1)
        XCTAssertEqual(voice.state, .listening)
        recognizer.emit(" unfinished ", isFinal: false)
        XCTAssertTrue(transcripts.isEmpty)

        recognizer.emit("  find the token work  ", isFinal: true)

        XCTAssertEqual(transcripts, ["find the token work"])
        XCTAssertEqual(recognizer.stopCount, 1)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(states, [.connecting, .listening, .finishing, .idle])
    }

    @MainActor
    func testNativeVoiceFailsWithoutRequestingAuthorizationWhenOnDeviceSpeechIsUnavailable() async {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: false)
        let voice = NativeMacOSVoiceSession(recognizer: recognizer)

        XCTAssertEqual(voice.state, .unavailable)
        XCTAssertNotNil(voice.availabilityMessage)
        do {
            try await voice.start()
            XCTFail("Expected unavailable on-device speech to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("On-device speech recognition"))
        }
        XCTAssertEqual(recognizer.authorizationRequestCount, 0)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    @MainActor
    func testNativeVoiceStopsCleanlyAndIgnoresLateRecognitionCallbacks() async throws {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: true, permission: .granted)
        let voice = NativeMacOSVoiceSession(recognizer: recognizer)
        var transcripts: [String] = []
        voice.onFinalTranscript = { transcripts.append($0) }

        try await voice.start()
        await voice.stop()
        recognizer.emit("too late", isFinal: true)
        recognizer.fail("too late")

        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recognizer.stopCount, 1)
        XCTAssertTrue(transcripts.isEmpty)
    }

    @MainActor
    func testNativeVoiceReportsDeniedSpeechAuthorizationWithoutStartingCapture() async {
        let recognizer = TestOnDeviceSpeechRecognizer(isAvailable: true, permission: .denied)
        let voice = NativeMacOSVoiceSession(recognizer: recognizer)

        do {
            try await voice.start()
            XCTFail("Expected denied speech authorization to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Speech recognition access is off"))
        }

        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recognizer.authorizationRequestCount, 1)
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testProviderCredentialsEncodeOnlyDocumentedSnakeCaseFields() throws {
        let credentials = ProviderCredentials(
            brightDataAPIKey: "bright",
            mossProjectID: "moss-id",
            liveKitSandboxID: "sandbox"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(credentials)) as? [String: Any]
        )

        XCTAssertEqual(object["bright_data_api_key"] as? String, "bright")
        XCTAssertEqual(object["moss_project_id"] as? String, "moss-id")
        XCTAssertEqual(object["livekit_sandbox_id"] as? String, "sandbox")
        XCTAssertNil(object["brightDataAPIKey"])
        XCTAssertTrue(object["openai_api_key"] is NSNull)
    }

    func testStartupProviderPatchOmitsMissingFieldsInsteadOfClearingHelperEnvironment() throws {
        let credentials = ProviderCredentials(brightDataAPIKey: "bright")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(PresentProviderCredentials(credentials: credentials))
            ) as? [String: Any]
        )

        XCTAssertEqual(object["bright_data_api_key"] as? String, "bright")
        XCTAssertNil(object["moss_project_id"])
        XCTAssertNil(object["moss_project_key"])
        XCTAssertNil(object["openai_api_key"])
    }

    @MainActor
    func testCredentialManagerStoresReplacesAndRemovesWithoutFillingADraft() throws {
        let store = InMemoryCredentialStore()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ProviderCredentialManager(store: store, environment: [:], defaults: defaults)
        var draft = ProviderDraft()
        draft[.brightDataAPIKey] = "first-secret"

        try manager.save(draft, for: .brightData)
        XCTAssertTrue(manager.isConnected(.brightData))
        XCTAssertEqual(try manager.snapshot().brightDataAPIKey, "first-secret")
        XCTAssertEqual(ProviderDraft()[.brightDataAPIKey], "")

        var replacement = ProviderDraft()
        replacement[.brightDataAPIKey] = "replacement-secret"
        try manager.save(replacement, for: .brightData)
        XCTAssertEqual(try manager.snapshot().brightDataAPIKey, "replacement-secret")

        try manager.remove(.brightData)
        XCTAssertFalse(manager.isConnected(.brightData))
        XCTAssertNil(try manager.snapshot().brightDataAPIKey)
    }

    @MainActor
    func testMossConnectionIsOnePasteButStillRequiresBothOpaqueValues() throws {
        let store = InMemoryCredentialStore()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ProviderCredentialManager(store: store, environment: [:], defaults: defaults)

        var dotenvDraft = ProviderDraft()
        dotenvDraft.connectionCode = """
        MOSS_PROJECT_ID=project-123
        MOSS_PROJECT_KEY=moss_access_key_secret
        """
        try manager.save(dotenvDraft, for: .moss)

        XCTAssertTrue(manager.isConnected(.moss))
        XCTAssertEqual(try manager.snapshot().mossProjectID, "project-123")
        XCTAssertEqual(try manager.snapshot().mossProjectKey, "moss_access_key_secret")

        var keyOnlyReplacement = ProviderDraft()
        keyOnlyReplacement.connectionCode = "moss_replacement_key"
        try manager.save(keyOnlyReplacement, for: .moss)
        XCTAssertEqual(try manager.snapshot().mossProjectID, "project-123")
        XCTAssertEqual(try manager.snapshot().mossProjectKey, "moss_replacement_key")
    }

    @MainActor
    func testMossCLIProfileJSONParsesAndBareKeyCannotInventProjectID() throws {
        let store = InMemoryCredentialStore()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ProviderCredentialManager(store: store, environment: [:], defaults: defaults)

        var keyOnly = ProviderDraft()
        keyOnly.connectionCode = "moss_key_without_id"
        XCTAssertThrowsError(try manager.save(keyOnly, for: .moss)) { error in
            XCTAssertEqual(error as? ProviderSetupError, .mossProjectIDRequired)
        }

        var profile = ProviderDraft()
        profile.connectionCode = #"{"active_profile":"demo","profiles":{"demo":{"project_id":"project-json","project_key":"moss_json_key"}}}"#
        try manager.save(profile, for: .moss)
        XCTAssertEqual(try manager.snapshot().mossProjectID, "project-json")
        XCTAssertEqual(try manager.snapshot().mossProjectKey, "moss_json_key")
    }

    @MainActor
    func testLiveKitConnectionAcceptsOneTokenServerIDOrOneExportBlock() throws {
        let store = InMemoryCredentialStore()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ProviderCredentialManager(store: store, environment: [:], defaults: defaults)

        var tokenServer = ProviderDraft()
        tokenServer.connectionCode = "sandbox-one-paste"
        try manager.save(tokenServer, for: .liveKit)
        XCTAssertEqual(try manager.snapshot().liveKitSandboxID, "sandbox-one-paste")
        XCTAssertEqual(try manager.snapshot().liveKitAgentName, "checkpoint")

        var cloud = ProviderDraft()
        cloud.connectionCode = """
        LIVEKIT_URL=wss://example.livekit.cloud
        LIVEKIT_API_KEY=api-key
        LIVEKIT_API_SECRET=api-secret
        """
        try manager.save(cloud, for: .liveKit)
        XCTAssertNil(try manager.snapshot().liveKitSandboxID)
        XCTAssertEqual(try manager.snapshot().liveKitURL, "wss://example.livekit.cloud")
        XCTAssertEqual(try manager.snapshot().liveKitAPIKey, "api-key")
        XCTAssertEqual(try manager.snapshot().liveKitAPISecret, "api-secret")

        try manager.save(tokenServer, for: .liveKit)
        XCTAssertEqual(try manager.snapshot().liveKitSandboxID, "sandbox-one-paste")
        XCTAssertNil(try manager.snapshot().liveKitURL)
        XCTAssertNil(try manager.snapshot().liveKitAPIKey)
        XCTAssertNil(try manager.snapshot().liveKitAPISecret)
    }

    @MainActor
    func testOperatorEnvironmentMigratesOnceAndRejectsPlaceholders() throws {
        let store = InMemoryCredentialStore()
        try store.set("existing", for: .brightDataAPIKey)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ProviderCredentialManager(
            store: store,
            environment: [
                "BRIGHT_DATA_API_KEY": "must-not-overwrite",
                "MOSS_PROJECT_ID": "moss-project",
                "MOSS_PROJECT_KEY": "your-moss-key",
                "OPENAI_API_KEY": "$(OPENAI_API_KEY)",
            ],
            defaults: defaults
        )

        XCTAssertEqual(try manager.snapshot().brightDataAPIKey, "existing")
        XCTAssertEqual(try manager.snapshot().mossProjectID, "moss-project")
        XCTAssertNil(try manager.snapshot().mossProjectKey)
        XCTAssertNil(try manager.snapshot().openAIAPIKey)
        XCTAssertFalse(manager.wasProvidedByOperator(.brightData))
        XCTAssertTrue(manager.wasProvidedByOperator(.moss))
        XCTAssertFalse(manager.isConnected(.moss))
    }

    @MainActor
    func testDeterministicAmbientExtractorReturnsStructuredLocalSubjects() async {
        let extractor = DeterministicAmbientSubjectExtractor()
        let result = await extractor.extract(
            from: AmbientObservationInput(
                applicationName: "Xcode",
                windowTitle: "TokenService.swift — CHECKPOINT",
                document: "/tmp/TokenService.swift"
            )
        )

        XCTAssertEqual(result.source, .deterministicLocal)
        XCTAssertTrue(result.subjects.contains("TokenService.swift"))
        XCTAssertTrue(result.subjects.contains("Xcode"))
        XCTAssertEqual(result.likelyIntent, "Working in Xcode on TokenService.swift — CHECKPOINT")
    }

    func testPassiveObservationUploadIsStructuredAndBoundedForLoopbackStorage() throws {
        let observation = WorkspaceObservation(
            id: "observation-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            applicationName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            windowTitle: "SecretProject.swift",
            document: "/Users/test/SecretProject.swift",
            artifactIDs: [],
            extraction: AmbientExtraction(
                subjects: ["SecretProject.swift", "Xcode", "Xcode"],
                likelyIntent: "Debug the private project",
                source: .deterministicLocal
            )
        )

        let upload = ObservationUploadRequest(observation: observation)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any]
        )

        XCTAssertNil(object["checkpoint_id"] as? String)
        XCTAssertEqual(object["application_name"] as? String, "Xcode")
        XCTAssertEqual(object["document_resource"] as? String, "/Users/test/SecretProject.swift")
        XCTAssertEqual((object["subjects"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(SafePublicEnrichmentCandidateFactory.candidate(for: observation))
    }

    func testPublicEnrichmentCandidateContainsOnlyThePublicHostname() throws {
        let observation = WorkspaceObservation(
            applicationName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Secret launch plan — alice@example.com",
            document: "https://docs.livekit.io/private/launch?token=do-not-send#notes",
            artifactIDs: [],
            extraction: AmbientExtraction(
                subjects: ["Secret launch plan"],
                likelyIntent: "Review the confidential launch",
                source: .deterministicLocal
            )
        )

        let candidate = try XCTUnwrap(
            SafePublicEnrichmentCandidateFactory.candidate(for: observation)
        )
        XCTAssertEqual(candidate.canonicalName, "docs.livekit.io")
        XCTAssertEqual(candidate.query, "docs.livekit.io official documentation latest")
        let encoded = String(data: try JSONEncoder().encode(candidate), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("launch"))
        XCTAssertFalse(encoded.contains("alice"))
        XCTAssertFalse(encoded.contains("do-not-send"))

        var privateObservation = observation
        privateObservation.document = "https://auth.internal/private"
        XCTAssertNil(SafePublicEnrichmentCandidateFactory.candidate(for: privateObservation))
    }

    func testObservationDeliveryGateDeduplicatesAndThrottlesAppSwitchBursts() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = WorkspaceObservation(
            applicationName: "Safari", bundleID: "com.apple.Safari",
            windowTitle: "Docs", document: "https://docs.example.org", artifactIDs: []
        )
        let second = WorkspaceObservation(
            applicationName: "Xcode", bundleID: "com.apple.dt.Xcode",
            windowTitle: "App.swift", document: "/tmp/App.swift", artifactIDs: []
        )
        var gate = ObservationDeliveryGate(duplicateWindow: 120, minimumInterval: 1.5)

        XCTAssertTrue(gate.shouldDeliver(first, now: start))
        XCTAssertFalse(gate.shouldDeliver(second, now: start.addingTimeInterval(0.5)))
        XCTAssertTrue(gate.shouldDeliver(second, now: start.addingTimeInterval(2)))
        XCTAssertFalse(gate.shouldDeliver(first, now: start.addingTimeInterval(4)))
        XCTAssertTrue(gate.shouldDeliver(first, now: start.addingTimeInterval(121)))
    }

    func testMemoryActivityUsesConsumerReadableDynamicLabels() {
        XCTAssertEqual(MemoryActivity.remembered(application: "Safari").title, "Remembered Safari")
        XCTAssertEqual(MemoryActivity.enriching(subject: "livekit.io").title, "Learning about livekit.io…")
        XCTAssertEqual(
            MemoryActivity.enriched(subject: "livekit.io", sourceCount: 2).detail,
            "Stored 2 public sources beside the private memory."
        )
    }

    func testMemoryBufferErasesOnlyRecentObservationsAndTheirArtifacts() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldArtifact = CapturedArtifact(id: "old-artifact", kind: .app, displayName: "Old")
        let recentArtifact = CapturedArtifact(id: "recent-artifact", kind: .app, displayName: "Recent")
        var buffer = WorkspaceMemoryBuffer()
        buffer.append(
            observation: WorkspaceObservation(
                id: "old",
                capturedAt: now.addingTimeInterval(-901),
                applicationName: "Old",
                bundleID: nil,
                windowTitle: nil,
                document: nil,
                artifactIDs: [oldArtifact.id]
            ),
            artifacts: [oldArtifact]
        )
        buffer.append(
            observation: WorkspaceObservation(
                id: "recent",
                capturedAt: now.addingTimeInterval(-60),
                applicationName: "Recent",
                bundleID: nil,
                windowTitle: nil,
                document: nil,
                artifactIDs: [recentArtifact.id]
            ),
            artifacts: [recentArtifact]
        )

        XCTAssertEqual(buffer.erase(since: now.addingTimeInterval(-900)), 1)
        XCTAssertEqual(buffer.observations.map(\.id), ["old"])
        XCTAssertEqual(buffer.uniqueArtifacts.map(\.id), ["old-artifact"])
    }

    func testTurnResponseDecodesDocumentedSnakeCaseEnvelope() throws {
        let data = Data(
            """
            {
              "request_id": "request-1",
              "kind": "confirmation_card",
              "message": "Resume this checkpoint?",
              "checkpoint": {
                "id": "checkpoint-1",
                "title": "BrightMoss auth",
                "summary": "JWT generation was blocking the Mac agent.",
                "next_step": "Implement token endpoint",
                "artifacts": [{
                  "kind": "url",
                  "display_name": "LiveKit docs",
                  "resource": "https://docs.livekit.io/"
                }]
              },
              "proposal_id": "proposal-1",
              "proposed_actions": [{
                "kind": "openURL",
                "display_name": "LiveKit docs",
                "resource": "https://docs.livekit.io/"
              }],
              "provider_disclosure": ["Moss · local"]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(TurnResponse.self, from: data)

        XCTAssertEqual(response.requestID, "request-1")
        XCTAssertEqual(response.kind, .confirmationCard)
        XCTAssertEqual(response.checkpoint?.nextStep, "Implement token endpoint")
        XCTAssertEqual(response.proposedActions.first?.kind, .openURL)
        XCTAssertEqual(response.proposalID, "proposal-1")
        XCTAssertEqual(response.sources, [])
    }

    func testConnectionAcceptsPortFileAndRejectsRemoteHost() throws {
        let localData = Data(#"{"port":43117,"token":"secret"}"#.utf8)
        let connection = try JSONDecoder().decode(AgentConnection.self, from: localData)
        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:43117")

        XCTAssertThrowsError(
            try AgentConnection(baseURL: XCTUnwrap(URL(string: "https://agent.example.com")), token: "secret")
        )
    }

    func testConnectionStoreRequiresUserOnlyFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-connection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-connection.json")
        try Data(#"{"port":43117,"token":"secret"}"#.utf8).write(to: file)

        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertNoThrow(try AgentConnectionStore.load(environment: [:], fileURL: file))

        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try AgentConnectionStore.load(environment: [:], fileURL: file))
    }

    func testValidatorAllowsOnlySavedHTTPSURL() throws {
        let artifact = CapturedArtifact(
            kind: .url,
            displayName: "LiveKit docs",
            resource: "https://docs.livekit.io/agents/"
        )
        let action = ProposedAction(
            kind: .openURL,
            displayName: "LiveKit docs",
            resource: "https://docs.livekit.io/agents/"
        )

        let plan = try SafeActionValidator.validate([action], against: [artifact])
        XCTAssertEqual(plan.actions, [action])

        let unsafe = ProposedAction(
            kind: .openURL,
            displayName: "Unsafe page",
            resource: "http://example.com"
        )
        XCTAssertThrowsError(try SafeActionValidator.validate([unsafe], against: [artifact])) { error in
            guard case SafeActionValidationError.invalidURL = error else {
                return XCTFail("Expected invalidURL, got \(error)")
            }
        }
    }

    func testValidatorRejectsUnsavedFileEvenWhenItExists() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("test".utf8)))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let action = ProposedAction(
            kind: .openFile,
            displayName: "Untrusted file",
            resource: fileURL.path
        )

        XCTAssertThrowsError(try SafeActionValidator.validate([action], against: [])) { error in
            XCTAssertEqual(error as? SafeActionValidationError, .targetWasNotSaved("Untrusted file"))
        }
    }

    func testValidatorCapsApprovedPlanAtThreeActions() {
        let actions = (0..<4).map { index in
            ProposedAction(
                kind: .activateApp,
                displayName: "App \(index)",
                bundleID: "test.app.\(index)"
            )
        }
        let artifacts = actions.map {
            CapturedArtifact(kind: .app, displayName: $0.displayName, bundleID: $0.bundleID)
        }

        XCTAssertThrowsError(try SafeActionValidator.validate(actions, against: artifacts)) { error in
            XCTAssertEqual(error as? SafeActionValidationError, .tooManyActions)
        }
    }

    func testApprovedActionsMustExactlyMatchWhatTheUserReviewed() {
        let reviewed = ProposedAction(
            id: "action-1",
            kind: .openURL,
            displayName: "LiveKit docs",
            resource: "https://docs.livekit.io/"
        )
        let exact = reviewed
        let swapped = ProposedAction(
            id: "action-1",
            kind: .openURL,
            displayName: "Another saved page",
            resource: "https://example.com/"
        )

        XCTAssertTrue(SafeActionValidator.matchesReviewedPlan(returned: [exact], displayed: [reviewed]))
        XCTAssertFalse(SafeActionValidator.matchesReviewedPlan(returned: [swapped], displayed: [reviewed]))
    }

    @MainActor
    func testFinalVoiceTranscriptUsesTheSharedTurnPipelineWithVoiceModality() async throws {
        let client = VoiceTurnAgentClient()
        let voice = TestVoiceSession()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: InMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: voice,
            providerCredentials: providers,
            defaults: defaults
        )
        await model.connectAndLoad()

        voice.emitFinalTranscript("  resume the token problem  ")
        for _ in 0..<50 where client.turns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(client.turns.count, 1)
        let turn = try XCTUnwrap(client.turns.first)
        XCTAssertEqual(turn.text, "resume the token problem")
        XCTAssertEqual(turn.modality, .voice)
        XCTAssertEqual(turn.allowPublicEnrichment, false)
        guard case let .user(text) = model.conversation.first?.content else {
            return XCTFail("Expected the finalized transcript to become a user turn")
        }
        XCTAssertEqual(text, "resume the token problem")
    }

    @MainActor
    func testVoiceCaptureIntentUsesTheSameExplicitRecorderPathAsTyping() async {
        let client = VoiceTurnAgentClient()
        let voice = TestVoiceSession()
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: InMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: voice,
            providerCredentials: providers,
            defaults: defaults
        )
        await model.connectAndLoad()

        voice.emitFinalTranscript("Checkpoint this as Demo session")
        await Task.yield()

        XCTAssertEqual(model.recorder.phase, .remembering)
        XCTAssertEqual(model.captureSuggestedTitle, "Demo session")
        XCTAssertTrue(client.turns.isEmpty)
        model.cancelCapture()
    }

    @MainActor
    func testMicrophonePermissionIsRequestedOnlyAfterVoiceButtonIsUsed() async throws {
        let client = VoiceTurnAgentClient()
        let voice = TestVoiceSession()
        let microphone = TestMicrophoneAuthorizer(result: .denied)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: InMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: voice,
            microphone: microphone,
            providerCredentials: providers,
            defaults: defaults
        )
        await model.connectAndLoad()

        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(voice.startCount, 0)
        model.startVoice()
        for _ in 0..<50 where microphone.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertEqual(voice.startCount, 0)
    }

    @MainActor
    func testStoredProviderSnapshotIsProvisionedAfterHelperHealthCheck() async throws {
        let client = VoiceTurnAgentClient()
        let store = InMemoryCredentialStore()
        try store.set("bright-from-keychain", for: .brightDataAPIKey)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: store, environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: TestVoiceSession(),
            providerCredentials: providers,
            defaults: defaults
        )

        await model.connectAndLoad()

        XCTAssertTrue(
            client.providerConfigurations.contains {
                $0.brightDataAPIKey == "bright-from-keychain"
            }
        )
    }

    @MainActor
    func testTypedTurnWaitsForTransientHelperStartupAndSendsExactlyOnce() async throws {
        let client = VoiceTurnAgentClient(healthFailures: 2)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: InMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: TestVoiceSession(),
            providerCredentials: providers,
            defaults: defaults,
            helperRetryDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        )

        model.composer = "find the token endpoint"
        model.submit()
        for _ in 0..<100 where client.turns.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertGreaterThanOrEqual(client.healthAttempts, 3)
        XCTAssertEqual(client.turns.map(\.text), ["find the token endpoint"])
        XCTAssertEqual(model.composer, "")
        let assistantMessages = model.conversation.compactMap { entry -> String? in
            guard case let .assistant(response) = entry.content else { return nil }
            return response.message
        }
        XCTAssertFalse(assistantMessages.contains { $0.contains("request was not sent") })
    }

    @MainActor
    func testTypedTurnRestoresDraftWhenHelperRemainsUnavailable() async throws {
        let client = VoiceTurnAgentClient(healthFailures: 100)
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCredentialManager(
            store: InMemoryCredentialStore(), environment: [:], defaults: defaults
        )
        let model = AppModel(
            client: client,
            voice: TestVoiceSession(),
            providerCredentials: providers,
            defaults: defaults,
            helperRetryDelays: []
        )

        model.composer = "keep this draft"
        model.submit()
        for _ in 0..<50 where model.composer.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(client.turns.isEmpty)
        XCTAssertEqual(model.composer, "keep this draft")
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "checkpoint-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

@MainActor
private final class TestVoiceSession: VoiceSessionControlling {
    var state: VoiceSessionState = .idle
    var availabilityMessage: String?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChange: ((VoiceSessionState, String?) -> Void)?
    private(set) var startCount = 0

    func start() async throws { startCount += 1 }
    func stop() async {}

    func emitFinalTranscript(_ text: String) {
        onFinalTranscript?(text)
    }
}

@MainActor
private final class TestMicrophoneAuthorizer: MicrophoneAuthorizing {
    let result: MicrophonePermission
    private(set) var requestCount = 0

    init(result: MicrophonePermission) {
        self.result = result
    }

    func requestWhenNeeded() async -> MicrophonePermission {
        requestCount += 1
        return result
    }
}

@MainActor
private final class TestOnDeviceSpeechRecognizer: OnDeviceSpeechRecognizing {
    let isOnDeviceRecognitionAvailable: Bool
    let permission: SpeechRecognitionPermission
    private(set) var authorizationRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onTranscript: (@MainActor (String, Bool) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?

    init(
        isAvailable: Bool,
        permission: SpeechRecognitionPermission = .granted
    ) {
        isOnDeviceRecognitionAvailable = isAvailable
        self.permission = permission
    }

    func requestAuthorization() async -> SpeechRecognitionPermission {
        authorizationRequestCount += 1
        return permission
    }

    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        startCount += 1
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ transcript: String, isFinal: Bool) {
        onTranscript?(transcript, isFinal)
    }

    func fail(_ message: String) {
        onFailure?(message)
    }
}

private final class VoiceTurnAgentClient: AgentServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingHealthFailures: Int
    private var recordedHealthAttempts = 0
    private var recordedTurns: [TurnRequest] = []
    private var recordedProviderConfigurations: [ProviderCredentials] = []

    init(healthFailures: Int = 0) {
        remainingHealthFailures = healthFailures
    }

    var healthAttempts: Int {
        lock.withLock { recordedHealthAttempts }
    }

    var turns: [TurnRequest] {
        lock.withLock { recordedTurns }
    }

    var providerConfigurations: [ProviderCredentials] {
        lock.withLock { recordedProviderConfigurations }
    }

    func health() async throws -> HealthResponse {
        let shouldFail = lock.withLock {
            recordedHealthAttempts += 1
            guard remainingHealthFailures > 0 else { return false }
            remainingHealthFailures -= 1
            return true
        }
        if shouldFail {
            throw URLError(.cannotConnectToHost)
        }
        return HealthResponse(status: "ok")
    }

    func providerStatus() async throws -> ProviderConfigurationResponse {
        ProviderConfigurationResponse(status: "ok")
    }

    func sendTurn(
        text: String,
        modality: TurnModality,
        allowPublicEnrichment: Bool
    ) async throws -> TurnResponse {
        lock.withLock {
            recordedTurns.append(
                TurnRequest(
                    text: text,
                    modality: modality,
                    allowPublicEnrichment: allowPublicEnrichment
                )
            )
        }
        return TurnResponse(kind: .message, message: "Found it.")
    }

    func listCheckpoints() async throws -> [CheckpointRecord] { [] }

    func createCheckpoint(_ request: CreateCheckpointRequest) async throws -> CheckpointRecord {
        CheckpointRecord(
            title: request.title,
            summary: request.summary,
            nextStep: request.nextStep,
            artifacts: request.artifacts
        )
    }

    func decideProposal(id: String, decision: ProposalDecision) async throws -> TurnResponse {
        TurnResponse(kind: .message, message: "No action.")
    }

    func configureProviders(_ credentials: ProviderCredentials) async throws -> ProviderConfigurationResponse {
        lock.withLock { recordedProviderConfigurations.append(credentials) }
        return ProviderConfigurationResponse(status: "ok")
    }

    func saveObservation(_ observation: ObservationUploadRequest) async throws -> ObservationUploadResponse {
        ObservationUploadResponse(
            id: observation.id,
            checkpointID: "ambient-test",
            contentHash: "hash",
            nodeIDs: [],
            evidenceID: "evidence"
        )
    }

    func enrich(_ request: EnrichmentUploadRequest) async throws -> EnrichmentUploadResponse {
        EnrichmentUploadResponse(
            jobID: "job",
            status: "provider_unavailable",
            policy: "allowed",
            policyReason: "public_subject_allowed",
            outboundQuery: request.candidate.query,
            sources: []
        )
    }

    func eraseRecent(minutes: Int) async throws -> EraseRecentMemoryResponse {
        EraseRecentMemoryResponse(
            observations: 0,
            nodes: 0,
            edges: 0,
            evidence: 0,
            enrichmentJobs: 0,
            sourceVersions: 0
        )
    }
}
