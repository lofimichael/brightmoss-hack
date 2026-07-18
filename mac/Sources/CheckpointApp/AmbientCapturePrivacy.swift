import Foundation

enum AmbientCaptureBlockReason: String, Equatable, Sendable {
    case checkpoint
    case passwordManager = "password_manager"
    case privateMessaging = "private_messaging"
    case privateBrowsing = "private_browsing"
    case authentication = "authentication"
    case financial = "financial"
}

struct AmbientCapturePrivacyContext: Equatable, Sendable {
    var applicationName: String
    var bundleID: String?
    var windowTitle: String?
    var document: String?
}

struct AmbientCapturePolicyDecision: Equatable, Sendable {
    var isAllowed: Bool
    var reason: AmbientCaptureBlockReason?

    static let allowed = AmbientCapturePolicyDecision(isAllowed: true, reason: nil)

    static func blocked(_ reason: AmbientCaptureBlockReason) -> AmbientCapturePolicyDecision {
        AmbientCapturePolicyDecision(isAllowed: false, reason: reason)
    }
}

/// Pure, conservative policy applied before any Accessibility traversal or
/// visual capture. The browser checks intentionally key off the focused window
/// and document instead of blocking browsers wholesale.
enum AmbientCapturePrivacyPolicy {
    private static let checkpointBundleIDs: Set<String> = [
        "app.checkpoint.desktop",
    ]

    private static let passwordManagerBundleFragments = [
        "1password", "agilebits", "bitwarden", "lastpass", "dashlane",
        "keepass", "enpass", "proton.pass", "passwordmanager",
    ]

    private static let passwordManagerNames = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass",
        "enpass", "proton pass", "password manager",
    ]

    private static let privateMessagingBundleFragments = [
        "com.apple.mobilesms", "whispersystems.signal", "signal-desktop",
        "whatsapp", "telegram", "tinyspeck.slack", "slackmacgap",
        "discord", "microsoft.teams", "facebook.archon", "wechat",
    ]

    private static let privateMessagingNames = [
        "messages", "signal", "whatsapp", "telegram", "slack", "discord",
        "microsoft teams", "wechat",
    ]

    private static let privateWindowPhrases = [
        "private browsing", "private window", "incognito", "inprivate",
        "private tab",
    ]

    private static let authenticationPhrases = [
        "sign in", "log in", "login", "password", "passkey", "security key",
        "two-factor", "two factor", "2fa", "multi-factor", "multifactor",
        "one-time code", "one time code", "one-time password", "verification code",
        "authenticator code", "recovery code",
    ]

    private static let authenticationPathFragments = [
        "/login", "/log-in", "/signin", "/sign-in", "/oauth/authorize",
        "/authorize", "/mfa", "/2fa", "/verify-account",
    ]

    private static let financialPhrases = [
        "online banking", "mobile banking", "bank account", "account balance",
        "routing number", "credit card", "debit card", "card number",
        "investment account", "brokerage account", "payment details",
    ]

    private static let financialHosts = [
        "chase.com", "bankofamerica.com", "wellsfargo.com", "capitalone.com",
        "americanexpress.com", "citi.com", "citibank.com", "usbank.com",
        "pnc.com", "schwab.com", "fidelity.com", "vanguard.com", "paypal.com",
        "venmo.com", "wise.com", "robinhood.com", "coinbase.com", "stripe.com",
    ]

    private static let financialHostFragments = [
        "bank", "creditunion", "credit-union", "brokerage",
    ]

    private static let authenticationHostPrefixes = [
        "login.", "signin.", "auth.", "accounts.", "identity.",
    ]

    static func evaluate(_ context: AmbientCapturePrivacyContext) -> AmbientCapturePolicyDecision {
        let appName = normalized(context.applicationName)
        let bundleID = normalized(context.bundleID)

        if checkpointBundleIDs.contains(bundleID) || appName == "checkpoint" {
            return .blocked(.checkpoint)
        }
        if containsAny(bundleID, passwordManagerBundleFragments)
            || containsAny(appName, passwordManagerNames) {
            return .blocked(.passwordManager)
        }
        if containsAny(bundleID, privateMessagingBundleFragments)
            || privateMessagingNames.contains(appName) {
            return .blocked(.privateMessaging)
        }

        let title = normalized(context.windowTitle)
        if containsAny(title, privateWindowPhrases) {
            return .blocked(.privateBrowsing)
        }
        if containsAny(title, authenticationPhrases) {
            return .blocked(.authentication)
        }
        if containsAny(title, financialPhrases) {
            return .blocked(.financial)
        }

        if let document = context.document,
           let components = URLComponents(string: document),
           let host = components.host?.lowercased() {
            let normalizedPath = components.path.lowercased()
            if financialHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return .blocked(.financial)
            }
            if financialHostFragments.contains(where: host.contains) {
                return .blocked(.financial)
            }
            if authenticationHostPrefixes.contains(where: host.hasPrefix)
                || authenticationPathFragments.contains(where: normalizedPath.contains) {
                return .blocked(.authentication)
            }
        }
        return .allowed
    }

    private static func normalized(_ raw: String?) -> String {
        (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ value: String, _ fragments: [String]) -> Bool {
        fragments.contains(where: value.contains)
    }
}

struct AccessibilityTextBounds: Equatable, Sendable {
    var maximumDepth: Int = 6
    var maximumNodes: Int = 180
    var maximumCharacters: Int = 8_000
    var maximumCharactersPerValue: Int = 1_000
}

struct AccessibilityNodeContent<Node> {
    var role: String?
    var subrole: String?
    var title: String?
    var value: String?
    var nodeDescription: String?
    var help: String?
    var children: [Node]
}

struct AccessibilityTextCollection: Equatable, Sendable {
    var text: String
    var visitedNodeCount: Int
    var wasTruncated: Bool
}

/// A deterministic, generic tree walk. The system adapter supplies AXUIElement
/// nodes; tests supply value-type nodes. Secure nodes are never read below their
/// role/subrole boundary.
struct BoundedAccessibilityTextCollector<Node> {
    var bounds: AccessibilityTextBounds

    init(bounds: AccessibilityTextBounds = AccessibilityTextBounds()) {
        self.bounds = bounds
    }

    func collect(
        root: Node,
        inspect: (Node) -> AccessibilityNodeContent<Node>
    ) -> AccessibilityTextCollection {
        var stack: [(node: Node, depth: Int)] = [(root, 0)]
        var visited = 0
        var characterCount = 0
        var values: [String] = []
        var seen: Set<String> = []
        var truncated = false

        while let next = stack.popLast() {
            guard next.depth <= bounds.maximumDepth else {
                truncated = true
                continue
            }
            guard visited < bounds.maximumNodes else {
                truncated = true
                break
            }
            visited += 1
            let content = inspect(next.node)
            let isSecure = Self.isSecure(role: content.role, subrole: content.subrole)

            if !isSecure {
                let hasSensitiveLabel = Self.hasSensitiveLabel(content.title)
                    || Self.hasSensitiveLabel(content.nodeDescription)
                let candidates = [
                    content.title,
                    hasSensitiveLabel ? nil : content.value,
                    content.nodeDescription,
                    content.help,
                ]
                for candidate in candidates.compactMap({ $0 }) {
                    let normalized = Self.normalized(candidate)
                    guard !normalized.isEmpty else { continue }
                    let bounded = String(normalized.prefix(bounds.maximumCharactersPerValue))
                    let key = bounded.casefolded
                    guard seen.insert(key).inserted else { continue }

                    let separatorCount = values.isEmpty ? 0 : 1
                    let remaining = bounds.maximumCharacters - characterCount - separatorCount
                    guard remaining > 0 else {
                        truncated = true
                        break
                    }
                    let accepted = String(bounded.prefix(remaining))
                    values.append(accepted)
                    characterCount += accepted.count + separatorCount
                    if accepted.count < bounded.count {
                        truncated = true
                        break
                    }
                }

                if next.depth < bounds.maximumDepth {
                    for child in content.children.reversed() {
                        stack.append((child, next.depth + 1))
                    }
                } else if !content.children.isEmpty {
                    truncated = true
                }
            }

            if characterCount >= bounds.maximumCharacters {
                truncated = true
                break
            }
        }

        return AccessibilityTextCollection(
            text: values.joined(separator: "\n"),
            visitedNodeCount: visited,
            wasTruncated: truncated
        )
    }

    static func isSecure(role: String?, subrole: String?) -> Bool {
        let identity = "\(role ?? "") \(subrole ?? "")".casefolded
        return identity.contains("secure") || identity.contains("password")
    }

    static func hasSensitiveLabel(_ raw: String?) -> Bool {
        let label = (raw ?? "").casefolded
        return [
            "password", "passcode", "verification code", "security answer", "secure text",
            "one-time code", "one time code",
        ]
            .contains(where: label.contains)
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AmbientCaptureDeduplicator: Equatable, Sendable {
    let pollInterval: TimeInterval
    let duplicateWindow: TimeInterval

    private var lastPoll: Date?
    private var lastFingerprint: String?
    private var recentFingerprints: [String: Date] = [:]

    init(pollInterval: TimeInterval = 8, duplicateWindow: TimeInterval = 120) {
        self.pollInterval = pollInterval
        self.duplicateWindow = duplicateWindow
    }

    mutating func shouldPoll(at now: Date = Date()) -> Bool {
        guard let lastPoll else {
            self.lastPoll = now
            return true
        }
        guard now.timeIntervalSince(lastPoll) >= pollInterval else { return false }
        self.lastPoll = now
        return true
    }

    mutating func shouldRecord(fingerprint: String, at now: Date = Date()) -> Bool {
        recentFingerprints = recentFingerprints.filter {
            now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) < duplicateWindow
        }
        guard fingerprint != lastFingerprint else { return false }
        guard recentFingerprints[fingerprint] == nil else { return false }
        lastFingerprint = fingerprint
        recentFingerprints[fingerprint] = now
        return true
    }
}

enum AmbientTextPrivacyFilter {
    private static let sensitiveLineFragments = [
        "password", "passcode", "one-time code", "one time code", "verification code",
        "recovery code", "security answer", "private key", "secret key", "card number",
        "routing number", "account number",
    ]

    static func sanitize(_ raw: String, maximumCharacters: Int = 8_000) -> String? {
        var output: [String] = []
        var seen: Set<String> = []
        var count = 0
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let folded = line.casefolded
            guard !sensitiveLineFragments.contains(where: folded.contains),
                  !containsCredentialShapedToken(line),
                  seen.insert(folded).inserted else {
                continue
            }
            let separator = output.isEmpty ? 0 : 1
            let remaining = maximumCharacters - count - separator
            guard remaining > 0 else { break }
            let accepted = String(line.prefix(remaining))
            output.append(accepted)
            count += accepted.count + separator
            if accepted.count < line.count { break }
        }
        let result = output.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    private static func containsCredentialShapedToken(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        return tokens.contains { token in
            let value = token.trimmingCharacters(in: .punctuationCharacters)
            guard value.count >= 48 else { return false }
            return value.allSatisfy { $0.isLetter || $0.isNumber || "_-+=/.".contains($0) }
        }
    }
}

private extension String {
    var casefolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
}
