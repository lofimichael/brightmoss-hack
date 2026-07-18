import Combine
import Foundation
import LiveKit
import AVFoundation
import Speech

enum VoiceSessionState: Equatable, Sendable {
    case unavailable
    case idle
    case connecting
    case listening
    case finishing
}

@MainActor
protocol VoiceSessionControlling: AnyObject {
    var state: VoiceSessionState { get }
    var availabilityMessage: String? { get }
    var onFinalTranscript: ((String) -> Void)? { get set }
    var onStateChange: ((VoiceSessionState, String?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

enum VoiceSessionError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

struct LiveKitVoiceConfiguration: Equatable, Sendable {
    static let defaultAgentName = "checkpoint"

    let sandboxID: String
    let agentName: String

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> LiveKitVoiceConfiguration? {
        guard let sandboxID = configuredValue(
            environment["LIVEKIT_SANDBOX_ID"] ?? infoDictionary["LiveKitSandboxId"] as? String
        ) else {
            return nil
        }
        let agentName = configuredValue(
            environment["LIVEKIT_AGENT_NAME"] ?? infoDictionary["LiveKitAgentName"] as? String
        ) ?? defaultAgentName
        return LiveKitVoiceConfiguration(sandboxID: sandboxID, agentName: agentName)
    }

    static func load(credentials: ProviderCredentials?) -> LiveKitVoiceConfiguration? {
        guard let credentials,
              let sandboxID = configuredValue(credentials.liveKitSandboxID) else {
            return nil
        }
        let agentName = configuredValue(credentials.liveKitAgentName) ?? defaultAgentName
        return LiveKitVoiceConfiguration(sandboxID: sandboxID, agentName: agentName)
    }

    private static func configuredValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$("),
              !value.lowercased().contains("your-") else {
            return nil
        }
        return value
    }
}

@MainActor
enum VoiceSessionFactory {
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        credentials: ProviderCredentials? = nil,
        localRecognizer: OnDeviceSpeechRecognizing? = nil
    ) -> VoiceSessionControlling {
        let configuration = LiveKitVoiceConfiguration.load(credentials: credentials)
            ?? LiveKitVoiceConfiguration.load(environment: environment, infoDictionary: infoDictionary)
        if let configuration {
            return LiveKitVoiceSession(configuration: configuration)
        }
        return NativeMacOSVoiceSession(
            recognizer: localRecognizer ?? SystemOnDeviceSpeechRecognizer()
        )
    }
}

enum SpeechRecognitionPermission: Equatable, Sendable {
    case granted
    case denied
}

@MainActor
protocol OnDeviceSpeechRecognizing: AnyObject {
    var isOnDeviceRecognitionAvailable: Bool { get }
    func requestAuthorization() async -> SpeechRecognitionPermission
    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws
    func stop()
}

/// Owns the Speech framework and audio-engine objects used by the zero-key
/// voice path. The recognition request always requires Apple's on-device
/// recognizer; it is never allowed to fall back to server recognition.
@MainActor
final class SystemOnDeviceSpeechRecognizer: OnDeviceSpeechRecognizing {
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine: AVAudioEngine
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false

    var isOnDeviceRecognitionAvailable: Bool {
        speechRecognizer?.supportsOnDeviceRecognition == true
    }

    init(
        locale: Locale = .autoupdatingCurrent,
        audioEngine: AVAudioEngine = AVAudioEngine()
    ) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.audioEngine = audioEngine
    }

    func requestAuthorization() async -> SpeechRecognitionPermission {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized ? .granted : .denied
    }

    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        guard let speechRecognizer,
              speechRecognizer.supportsOnDeviceRecognition else {
            throw VoiceSessionError.unavailable(Self.unavailableMessage)
        }

        tearDownRecognition()

        let request = Self.makeRecognitionRequest()
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            tearDownRecognition()
            throw VoiceSessionError.unavailable(
                "Microphone input isn't available. Typing still works."
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInputTap = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failureMessage = error?.localizedDescription
            Task { @MainActor in
                if let text {
                    onTranscript(text, isFinal)
                }
                // Speech commonly reports cancellation after its final result.
                // Never replace a valid final transcript with that teardown error.
                if let failureMessage, !isFinal {
                    onFailure(failureMessage)
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            tearDownRecognition()
            throw VoiceSessionError.unavailable(
                "Microphone input couldn't start. Typing still works."
            )
        }
    }

    func stop() {
        tearDownRecognition()
    }

    static func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    private func tearDownRecognition() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    static let unavailableMessage =
        "On-device speech recognition isn't available on this Mac. Typing still works."
}

/// Zero-key macOS voice capture. Speech authorization is intentionally deferred
/// until start(), and only finalized local transcripts leave this object.
@MainActor
final class NativeMacOSVoiceSession: VoiceSessionControlling {
    private(set) var state: VoiceSessionState
    private(set) var availabilityMessage: String?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChange: ((VoiceSessionState, String?) -> Void)?

    private let recognizer: OnDeviceSpeechRecognizing
    private var activeAttemptID: UUID?

    init(recognizer: OnDeviceSpeechRecognizing) {
        self.recognizer = recognizer
        if recognizer.isOnDeviceRecognitionAvailable {
            state = .idle
            availabilityMessage = nil
        } else {
            state = .unavailable
            availabilityMessage = SystemOnDeviceSpeechRecognizer.unavailableMessage
        }
    }

    func start() async throws {
        guard state == .idle else {
            if state == .unavailable {
                throw VoiceSessionError.unavailable(
                    availabilityMessage ?? SystemOnDeviceSpeechRecognizer.unavailableMessage
                )
            }
            return
        }
        guard recognizer.isOnDeviceRecognitionAvailable else {
            failPermanently(SystemOnDeviceSpeechRecognizer.unavailableMessage)
            throw VoiceSessionError.unavailable(SystemOnDeviceSpeechRecognizer.unavailableMessage)
        }

        availabilityMessage = nil
        let attemptID = UUID()
        activeAttemptID = attemptID
        transition(to: .connecting)

        guard await recognizer.requestAuthorization() == .granted else {
            guard activeAttemptID == attemptID else { return }
            activeAttemptID = nil
            let message = "Speech recognition access is off. You can enable it in System Settings, or keep typing here."
            availabilityMessage = message
            transition(to: .idle, message: message)
            throw VoiceSessionError.unavailable(message)
        }
        guard activeAttemptID == attemptID, state == .connecting else { return }

        do {
            try recognizer.start(
                onTranscript: { [weak self] transcript, isFinal in
                    self?.receive(transcript: transcript, isFinal: isFinal, attemptID: attemptID)
                },
                onFailure: { [weak self] message in
                    self?.handleRuntimeFailure(message, attemptID: attemptID)
                }
            )
        } catch {
            guard activeAttemptID == attemptID else { return }
            recognizer.stop()
            activeAttemptID = nil
            let message = error.localizedDescription
            availabilityMessage = message
            transition(to: .idle, message: message)
            throw error
        }

        guard activeAttemptID == attemptID else {
            recognizer.stop()
            return
        }
        transition(to: .listening)
    }

    func stop() async {
        guard state != .unavailable, state != .idle else { return }
        activeAttemptID = nil
        transition(to: .finishing)
        recognizer.stop()
        transition(to: .idle)
    }

    private func receive(transcript: String, isFinal: Bool, attemptID: UUID) {
        guard isFinal, activeAttemptID == attemptID, state == .listening else { return }
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else { return }

        activeAttemptID = nil
        onFinalTranscript?(finalTranscript)
        transition(to: .finishing)
        recognizer.stop()
        transition(to: .idle)
    }

    private func handleRuntimeFailure(_ message: String, attemptID: UUID) {
        guard activeAttemptID == attemptID,
              state == .connecting || state == .listening else { return }
        activeAttemptID = nil
        availabilityMessage = message
        transition(to: .finishing, message: message)
        recognizer.stop()
        transition(to: .idle, message: message)
    }

    private func transition(to newState: VoiceSessionState, message: String? = nil) {
        state = newState
        onStateChange?(newState, message)
    }

    private func failPermanently(_ message: String) {
        activeAttemptID = nil
        availabilityMessage = message
        transition(to: .unavailable, message: message)
    }
}

enum MicrophonePermission: Equatable, Sendable {
    case granted
    case denied
}

@MainActor
protocol MicrophoneAuthorizing: AnyObject {
    func requestWhenNeeded() async -> MicrophonePermission
}

@MainActor
final class SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
    func requestWhenNeeded() async -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

/// Development-only LiveKit Cloud voice transport. It receives microphone audio
/// through the hosted token-server path and forwards only finalized user
/// transcripts. This is not the app's local/offline voice path.
@MainActor
final class LiveKitVoiceSession: VoiceSessionControlling {
    private(set) var state: VoiceSessionState = .idle
    private(set) var availabilityMessage: String?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChange: ((VoiceSessionState, String?) -> Void)?

    private let session: LiveKit.Session
    private var observation: AnyCancellable?
    private var submittedTranscriptIDs: Set<String> = []
    private var isEndingAfterTranscript = false
    private var isHandlingFailure = false

    init(configuration: LiveKitVoiceConfiguration) {
        session = LiveKit.Session.withAgent(
            configuration.agentName,
            tokenSource: SandboxTokenSource(id: configuration.sandboxID).cached(),
            options: SessionOptions(preConnectAudio: true, agentConnectTimeout: 20)
        )

        observation = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.consumeSessionChanges()
            }
        }
    }

    func start() async throws {
        guard state == .idle else { return }
        submittedTranscriptIDs = []
        isEndingAfterTranscript = false
        isHandlingFailure = false
        availabilityMessage = nil
        transition(to: .connecting)

        await session.start()
        if let error = session.error {
            await session.end()
            let message = error.localizedDescription
            availabilityMessage = message
            transition(to: .idle, message: message)
            throw VoiceSessionError.unavailable(message)
        }
        guard session.isConnected else {
            let message = "Voice could not connect. Typing still works."
            availabilityMessage = message
            transition(to: .idle, message: message)
            throw VoiceSessionError.unavailable(message)
        }

        transition(to: .listening)
        consumeFinalTranscripts()
    }

    func stop() async {
        guard state != .unavailable, state != .idle else { return }
        transition(to: .finishing)
        await session.end()
        transition(to: .idle)
    }

    private func consumeSessionChanges() {
        consumeFinalTranscripts()

        if let error = session.error, state == .listening {
            handleRuntimeFailure(error.localizedDescription)
        } else if let error = session.agent.error, state == .listening {
            handleRuntimeFailure(error.localizedDescription)
        }
    }

    private func consumeFinalTranscripts() {
        for message in session.messages where message.isFinal {
            guard case let .userTranscript(text) = message.content,
                  !submittedTranscriptIDs.contains(message.id) else {
                continue
            }
            submittedTranscriptIDs.insert(message.id)
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { continue }

            onFinalTranscript?(transcript)
            guard !isEndingAfterTranscript else { continue }
            isEndingAfterTranscript = true
            transition(to: .finishing)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await session.end()
                transition(to: .idle)
                isEndingAfterTranscript = false
            }
        }
    }

    private func transition(to newState: VoiceSessionState, message: String? = nil) {
        state = newState
        onStateChange?(newState, message)
    }

    private func handleRuntimeFailure(_ message: String) {
        guard !isHandlingFailure else { return }
        isHandlingFailure = true
        availabilityMessage = message
        transition(to: .finishing, message: message)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await session.end()
            transition(to: .idle, message: message)
            isHandlingFailure = false
        }
    }
}

/// Honest fallback used when configuration is absent or a LiveKit adapter
/// cannot be created. It never simulates transcripts or connectivity.
@MainActor
final class UnavailableVoiceSession: VoiceSessionControlling {
    let state: VoiceSessionState = .unavailable
    let availabilityMessage: String?
    var onFinalTranscript: ((String) -> Void)?
    var onStateChange: ((VoiceSessionState, String?) -> Void)?

    init(reason: String = "Voice is unavailable. Typing still works.") {
        availabilityMessage = reason
    }

    func start() async throws {
        throw VoiceSessionError.unavailable(availabilityMessage ?? "Voice is unavailable.")
    }

    func stop() async {}
}
