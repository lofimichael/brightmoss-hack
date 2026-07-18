import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

enum VisualCaptureAuthorizationState: String, Codable, Equatable, Sendable {
    case notRequested = "not_requested"
    case ready
    case denied
    case unavailable
}

struct VisualCaptureTarget: Equatable, Sendable {
    var processIdentifier: pid_t
    var windowTitle: String?
}

struct VisualWindowDescriptor: Equatable, Sendable {
    var windowID: CGWindowID
    var processIdentifier: pid_t
    var title: String?
    var frame: CGRect
}

enum VisualWindowSelector {
    static func selectWindowID(
        from windows: [VisualWindowDescriptor],
        target: VisualCaptureTarget
    ) -> CGWindowID? {
        let eligible = windows.filter {
            $0.processIdentifier == target.processIdentifier
                && $0.frame.width >= 80
                && $0.frame.height >= 60
        }
        let expected = normalized(target.windowTitle)
        if !expected.isEmpty {
            // Never fall back to another window from the same process: the
            // privacy policy evaluated the focused title, not every app window.
            return eligible.first(where: { normalized($0.title) == expected })?.windowID
        }
        return eligible.count == 1 ? eligible[0].windowID : nil
    }

    private static func normalized(_ raw: String?) -> String {
        (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VisualCaptureSizing {
    static let maximumWidth = 2_400
    static let maximumHeight = 1_600
    static let maximumPixels = 3_840_000

    static func pixelSize(for frame: CGRect) -> CGSize {
        let width = Double(max(frame.width, 1))
        let height = Double(max(frame.height, 1))
        let pixelScale = sqrt(Double(maximumPixels) / (width * height))
        let scale = min(
            2.0,
            Double(maximumWidth) / width,
            Double(maximumHeight) / height,
            pixelScale
        )
        let outputWidth = max(1, min(maximumWidth, Int((width * scale).rounded(.down))))
        let outputHeight = max(1, min(maximumHeight, Int((height * scale).rounded(.down))))
        return CGSize(width: CGFloat(outputWidth), height: CGFloat(outputHeight))
    }
}

protocol VisualTextCapturing: AnyObject {
    var authorizationState: VisualCaptureAuthorizationState { get }

    /// This is the only method allowed to trigger the Screen Recording prompt.
    /// Call it only from an explicit user action.
    @discardableResult
    func requestAccess() -> VisualCaptureAuthorizationState

    func recognizeFrontWindowText(for target: VisualCaptureTarget) async -> String?
}

final class SystemVisualTextCapture: VisualTextCapturing, @unchecked Sendable {
    private static let didRequestPermissionKey = "checkpoint.didRequestScreenCapture"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var authorizationState: VisualCaptureAuthorizationState {
        guard #available(macOS 14.0, *) else { return .unavailable }
        if CGPreflightScreenCaptureAccess() { return .ready }
        return defaults.bool(forKey: Self.didRequestPermissionKey) ? .denied : .notRequested
    }

    @discardableResult
    func requestAccess() -> VisualCaptureAuthorizationState {
        guard #available(macOS 14.0, *) else { return .unavailable }
        defaults.set(true, forKey: Self.didRequestPermissionKey)
        return CGRequestScreenCaptureAccess() ? .ready : .denied
    }

    func recognizeFrontWindowText(for target: VisualCaptureTarget) async -> String? {
        guard #available(macOS 14.0, *),
              authorizationState == .ready,
              await MainActor.run(body: {
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
              }) else { return nil }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            let descriptors = shareable.windows.compactMap { window -> VisualWindowDescriptor? in
                guard let processIdentifier = window.owningApplication?.processID else { return nil }
                return VisualWindowDescriptor(
                    windowID: window.windowID,
                    processIdentifier: processIdentifier,
                    title: window.title,
                    frame: window.frame
                )
            }
            guard let selectedID = VisualWindowSelector.selectWindowID(
                from: descriptors,
                target: target
            ),
            let window = shareable.windows.first(where: { $0.windowID == selectedID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let size = VisualCaptureSizing.pixelSize(for: window.frame)
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            // The image exists only in this lexical scope. It is never encoded,
            // written to disk, cached, logged, or attached to an observation.
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return try Self.recognizeText(in: image)
        } catch {
            return nil
        }
    }

    private static func recognizeText(in image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let ordered = (request.results ?? []).sorted { left, right in
            let verticalDelta = left.boundingBox.midY - right.boundingBox.midY
            if abs(verticalDelta) > 0.015 { return verticalDelta > 0 }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        let raw = ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return AmbientTextPrivacyFilter.sanitize(raw)
    }
}

struct AmbientResolvedContent: Equatable, Sendable {
    var text: String?
    var extractionMethod: AmbientExtractionMethod
}

/// Accessibility text always wins when it is sufficiently rich. Vision is a
/// one-shot fallback only when the user enabled it and TCC is already ready.
struct AmbientContentResolver {
    var minimumAccessibilityCharacters = 80
    var maximumCharacters = 8_000

    func resolve(
        snapshot: AccessibilitySnapshot,
        target: VisualCaptureTarget,
        visualFallbackEnabled: Bool,
        visualCapture: VisualTextCapturing
    ) async -> AmbientResolvedContent {
        let accessibilityText = snapshot.visibleText.flatMap {
            AmbientTextPrivacyFilter.sanitize($0, maximumCharacters: maximumCharacters)
        }
        if let accessibilityText,
           accessibilityText.count >= minimumAccessibilityCharacters {
            return AmbientResolvedContent(
                text: accessibilityText,
                extractionMethod: .accessibility
            )
        }

        if visualFallbackEnabled,
           visualCapture.authorizationState == .ready,
           let recognized = await visualCapture.recognizeFrontWindowText(for: target),
           let safeOCR = AmbientTextPrivacyFilter.sanitize(
               recognized,
               maximumCharacters: maximumCharacters
           ) {
            let merged = Self.merge(accessibilityText, safeOCR, limit: maximumCharacters)
            return AmbientResolvedContent(text: merged, extractionMethod: .ocr)
        }

        if let accessibilityText {
            return AmbientResolvedContent(
                text: accessibilityText,
                extractionMethod: .accessibility
            )
        }
        return AmbientResolvedContent(text: nil, extractionMethod: .metadata)
    }

    private static func merge(_ first: String?, _ second: String, limit: Int) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        for line in [first, second].compactMap({ $0 }).flatMap({ $0.components(separatedBy: .newlines) }) {
            let key = line.lowercased()
            guard seen.insert(key).inserted else { continue }
            lines.append(line)
        }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
}
