import AppKit
import Foundation

enum SafeActionValidationError: LocalizedError, Equatable {
    case emptyPlan
    case tooManyActions
    case unsupportedHighLevelAction
    case missingTarget(String)
    case targetWasNotSaved(String)
    case invalidURL(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return "The approved plan contained no actions."
        case .tooManyActions:
            return "The approved plan exceeded the three-action safety limit."
        case .unsupportedHighLevelAction:
            return "The restore plan did not contain concrete open actions."
        case .missingTarget(let name):
            return "\(name) did not include a concrete target."
        case .targetWasNotSaved(let name):
            return "\(name) is not part of a saved checkpoint."
        case .invalidURL(let value):
            return "Only saved HTTPS URLs can be opened: \(value)"
        case .missingFile(let path):
            return "The saved file has moved or is unavailable: \(path)"
        }
    }
}

struct ValidatedActionPlan: Sendable {
    let actions: [ProposedAction]
}

enum SafeActionValidator {
    static func matchesReviewedPlan(
        returned: [ProposedAction],
        displayed: [ProposedAction]
    ) -> Bool {
        guard returned.count == displayed.count else { return false }
        return zip(returned, displayed).allSatisfy { left, right in
            left.id == right.id
                && left.kind == right.kind
                && left.displayName == right.displayName
                && left.bundleID == right.bundleID
                && left.resource == right.resource
        }
    }

    static func validate(
        _ actions: [ProposedAction],
        against savedArtifacts: [CapturedArtifact],
        fileManager: FileManager = .default
    ) throws -> ValidatedActionPlan {
        guard !actions.isEmpty else { throw SafeActionValidationError.emptyPlan }
        guard actions.count <= 3 else { throw SafeActionValidationError.tooManyActions }

        let savedBundleIDs = Set(savedArtifacts.compactMap(\.bundleID))
        let savedFiles = Set(
            savedArtifacts
                .filter { $0.kind == .file }
                .compactMap(\.resource)
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
        let savedURLs = Set(
            savedArtifacts
                .filter { $0.kind == .url }
                .compactMap(\.resource)
                .compactMap(URL.init(string:))
                .filter { $0.scheme?.lowercased() == "https" }
                .map(\.absoluteString)
        )

        for action in actions {
            switch action.kind {
            case .restoreCheckpoint:
                throw SafeActionValidationError.unsupportedHighLevelAction

            case .activateApp:
                guard let bundleID = action.bundleID, !bundleID.isEmpty else {
                    throw SafeActionValidationError.missingTarget(action.displayName)
                }
                guard savedBundleIDs.contains(bundleID) else {
                    throw SafeActionValidationError.targetWasNotSaved(action.displayName)
                }

            case .openURL:
                guard let raw = action.resource,
                      let url = URL(string: raw),
                      url.scheme?.lowercased() == "https",
                      url.user == nil,
                      url.password == nil else {
                    throw SafeActionValidationError.invalidURL(action.resource ?? action.displayName)
                }
                guard savedURLs.contains(url.absoluteString) else {
                    throw SafeActionValidationError.targetWasNotSaved(action.displayName)
                }

            case .openFile, .revealInFinder:
                guard let raw = action.resource, !raw.isEmpty else {
                    throw SafeActionValidationError.missingTarget(action.displayName)
                }
                let path = URL(fileURLWithPath: raw).standardizedFileURL.path
                guard savedFiles.contains(path) else {
                    throw SafeActionValidationError.targetWasNotSaved(action.displayName)
                }
                guard fileManager.fileExists(atPath: path) else {
                    throw SafeActionValidationError.missingFile(path)
                }
            }
        }

        return ValidatedActionPlan(actions: actions)
    }
}

struct ActionExecutionResult: Identifiable, Sendable {
    let id = UUID().uuidString
    let action: ProposedAction
    let succeeded: Bool
    let detail: String
}

@MainActor
final class SafeActionExecutor {
    func execute(_ plan: ValidatedActionPlan) async -> [ActionExecutionResult] {
        var results: [ActionExecutionResult] = []
        for action in plan.actions {
            do {
                try await execute(action)
                results.append(
                    ActionExecutionResult(action: action, succeeded: true, detail: "Opened \(action.displayName)")
                )
            } catch {
                results.append(
                    ActionExecutionResult(
                        action: action,
                        succeeded: false,
                        detail: error.localizedDescription
                    )
                )
            }
        }
        return results
    }

    private func execute(_ action: ProposedAction) async throws {
        switch action.kind {
        case .openURL:
            guard let raw = action.resource, let url = URL(string: raw), NSWorkspace.shared.open(url) else {
                throw SafeActionValidationError.invalidURL(action.resource ?? action.displayName)
            }

        case .openFile:
            guard let raw = action.resource else {
                throw SafeActionValidationError.missingTarget(action.displayName)
            }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            guard NSWorkspace.shared.open(url) else {
                throw SafeActionValidationError.missingFile(url.path)
            }

        case .revealInFinder:
            guard let raw = action.resource else {
                throw SafeActionValidationError.missingTarget(action.displayName)
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: raw).standardizedFileURL])

        case .activateApp:
            guard let bundleID = action.bundleID,
                  let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw SafeActionValidationError.missingTarget(action.displayName)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

        case .restoreCheckpoint:
            throw SafeActionValidationError.unsupportedHighLevelAction
        }
    }
}
