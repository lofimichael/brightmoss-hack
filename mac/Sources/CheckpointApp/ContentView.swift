import AppKit
import SwiftUI

private let checkpointAccent = Color(red: 0.24, green: 0.48, blue: 0.34)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("checkpoint.didCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [checkpointAccent.opacity(0.045), .clear, Color(nsColor: .windowBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Group {
                if didCompleteOnboarding {
                    ConversationView(model: model)
                } else {
                    OnboardingView(model: model) { publicEnrichment in
                        model.completeOnboarding(publicEnrichment: publicEnrichment)
                        didCompleteOnboarding = true
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 620, idealHeight: 700)
        .tint(checkpointAccent)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let complete: (Bool) -> Void
    @State private var publicEnrichment = false
    @State private var showsConnections = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 18)

            ZStack {
                Circle()
                    .fill(checkpointAccent.opacity(0.07))
                    .frame(width: 116, height: 116)
                Circle()
                    .stroke(checkpointAccent.opacity(0.12), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 45, weight: .medium))
                    .foregroundStyle(checkpointAccent)
            }

            VStack(spacing: 9) {
                Text("Never lose the thread.")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("CHECKPOINT quietly remembers the context around your work, then lets you ask for it in plain English.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 0) {
                OnboardingPromise(
                    icon: "macbook",
                    title: "Understands locally",
                    detail: "App, page, and document context is structured on this Mac."
                )
                Divider().padding(.leading, 49)
                OnboardingPromise(
                    icon: "photo.badge.checkmark",
                    title: "No screenshot archive",
                    detail: "CHECKPOINT keeps useful context, not a recording of your screen."
                )
                Divider().padding(.leading, 49)
                OnboardingPromise(
                    icon: "hand.raised.fill",
                    title: "You're always in control",
                    detail: "Pause from the menu bar or erase the last 15 minutes anytime."
                )
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .frame(maxWidth: 470)

            Toggle(isOn: $publicEnrichment) {
                HStack(spacing: 11) {
                    Image(systemName: "globe.americas.fill")
                        .foregroundStyle(checkpointAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add fresh public context")
                            .font(.callout.weight(.semibold))
                        Text("Bright Data may enrich approved public topics—never screenshots or local files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(14)
            .background(checkpointAccent.opacity(publicEnrichment ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 470)

            VStack(spacing: 10) {
                Button {
                    complete(publicEnrichment)
                } label: {
                    Text("Start remembering")
                        .frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showsConnections = true
                } label: {
                    let count = effectiveConnectionCount(model)
                    Text(count == 0 ? "Optional connections" : "\(count) connection\(count == 1 ? "" : "s") ready")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 34)
        .sheet(isPresented: $showsConnections) {
            ProviderConnectionsView(
                model: model,
                compact: false,
                doneTitle: "Done",
                done: { showsConnections = false }
            )
        }
    }
}

private struct OnboardingPromise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(checkpointAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct ConversationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            TimelineView(model: model)
            ComposerView(model: model)
        }
        .background(.clear)
        .sheet(
            isPresented: Binding(
                get: { model.recorder.phase == .preview },
                set: { visible in
                    if !visible, model.recorder.phase == .preview {
                        model.recorder.resumeRemembering()
                    }
                }
            )
        ) {
            CapturePreviewView(model: model)
        }
        .sheet(isPresented: $model.showsConnections) {
            ProviderConnectionsView(
                model: model,
                compact: false,
                doneTitle: "Done",
                done: { model.showsConnections = false }
            )
        }
        .sheet(isPresented: $model.showsMemories) {
            MemoriesLibraryView(model: model)
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel
    @State private var confirmsErase = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(checkpointAccent.opacity(0.12))
                    Image(systemName: "brain.head.profile.fill")
                        .foregroundStyle(checkpointAccent)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text("CHECKPOINT")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(0.8)
                    Text("Your private work memory")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.toggleMemory()
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.recorder.memoryState == .on ? checkpointAccent : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(model.recorder.memoryState == .on ? "Memory On" : "Paused")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(model.recorder.memoryState == .on ? "Pause memory" : "Turn memory on")

                Button {
                    model.openMemories()
                } label: {
                    Label("\(model.capturedObservationCount)", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Browse memories")

                Menu {
                    Button("Browse Memories…") { model.openMemories() }
                    Button(model.recorder.memoryState == .on ? "Pause Memory" : "Turn Memory On") {
                        model.toggleMemory()
                    }
                    Toggle(
                        "Public enrichment",
                        isOn: Binding(
                            get: { model.publicEnrichmentEnabled },
                            set: { model.setPublicEnrichment($0) }
                        )
                    )
                    Toggle(
                        "Visual fallback · screenshots never saved",
                        isOn: Binding(
                            get: { model.visualFallbackEnabled },
                            set: { model.setVisualFallback($0) }
                        )
                    )
                    Divider()
                    Button("Connections…") { model.showsConnections = true }
                    Button("Erase last 15 minutes…", role: .destructive) { confirmsErase = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            MemoryActivityStrip(model: model)

            if model.recorder.isRemembering {
                HStack {
                    Text("Building an explicit checkpoint…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelCapture() }
                        .buttonStyle(.plain)
                    Button("Review") { model.recorder.showPreview() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .confirmationDialog(
            "Erase recent memory?",
            isPresented: $confirmsErase,
            titleVisibility: .visible
        ) {
            Button("Erase last 15 minutes", role: .destructive) {
                model.eraseLastFifteenMinutes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recent local observations from this Mac.")
        }
    }
}

private struct MemoriesLibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(checkpointAccent.opacity(0.1))
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundStyle(checkpointAccent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Memories")
                        .font(.title2.weight(.semibold))
                    Text("The useful trail on this Mac—not a screenshot archive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.reloadMemories() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh memories")
                .disabled(model.isLoadingMemories)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MemoryStatsStrip(stats: model.memoryStats)

                    VisualFallbackCard(model: model)

                    if !model.memorySubjects.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("INTERESTS TAKING SHAPE")
                                .font(.caption2.weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.memorySubjects) { subject in
                                        SubjectSummaryChip(subject: subject)
                                    }
                                }
                            }
                        }
                    }

                    ExpandedKnowledgeSection(model: model)

                    if let error = model.memoryLibraryError {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Try again") {
                                Task { await model.reloadMemories() }
                            }
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                    }

                    memoryContent
                }
                .padding(20)
            }
        }
        .frame(minWidth: 610, idealWidth: 680, minHeight: 620, idealHeight: 720)
        .task {
            if model.memoryItems.isEmpty {
                await model.reloadMemories()
            }
        }
    }

    @ViewBuilder
    private var memoryContent: some View {
        if model.isLoadingMemories && model.memoryItems.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading your private memory…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        } else if model.memoryItems.isEmpty && model.memoryLibraryError == nil {
            VStack(spacing: 11) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 30))
                    .foregroundStyle(checkpointAccent)
                Text("Nothing remembered yet")
                    .font(.headline)
                Text("Leave Memory On and keep working normally. Your first useful moment will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RECENT MOMENTS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(memoryCountLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.memoryItems) { item in
                    MemoryItemCard(
                        item: item,
                        isDeleting: model.deletingMemoryIDs.contains(item.id),
                        delete: { Task { await model.deleteMemory(item) } }
                    )
                }
                if model.memoryItems.count < model.capturedObservationCount {
                    HStack {
                        Spacer()
                        if model.canLoadEarlierMemories {
                            Button {
                                Task { await model.loadEarlierMemories() }
                            } label: {
                                HStack(spacing: 7) {
                                    if model.isLoadingEarlierMemories {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(model.isLoadingEarlierMemories ? "Loading…" : "Load earlier")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isLoadingEarlierMemories)
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var memoryCountLabel: String {
        let visible = model.memoryItems.count
        let total = model.capturedObservationCount
        return visible < total ? "Latest \(visible) of \(total)" : "\(total) remembered"
    }
}

private struct MemoryStatsStrip: View {
    let stats: MemoryStats

    var body: some View {
        HStack(spacing: 9) {
            MemoryStatTile(value: stats.totalMemories, label: "Moments", icon: "clock.fill")
            MemoryStatTile(value: stats.totalSubjects, label: "Subjects", icon: "tag.fill")
            MemoryStatTile(value: stats.enrichedMemories, label: "Enriched", icon: "globe.americas.fill")
            MemoryStatTile(value: stats.publicSources, label: "Sources", icon: "link")
        }
    }
}

private struct MemoryStatTile: View {
    let value: Int
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(checkpointAccent)
                Spacer()
                Text("\(value)")
                    .font(.title3.weight(.semibold))
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct VisualFallbackCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { model.visualFallbackEnabled },
                    set: { model.setVisualFallback($0) }
                )
            ) {
                HStack(spacing: 11) {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(checkpointAccent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Visual fallback")
                            .font(.callout.weight(.semibold))
                        Text("Off by default. A screen image is processed once in memory for text, then discarded—screenshots are never saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusCopy)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.visualCaptureState == .denied {
                    Button("Open System Settings") {
                        model.openScreenRecordingSettings()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .padding(.leading, 35)
        }
        .padding(12)
        .background(checkpointAccent.opacity(model.visualFallbackEnabled ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCopy: String {
        switch model.visualCaptureState {
        case .notRequested: return "Permission requested only when enabled"
        case .ready: return "Ready · pixels discarded after OCR"
        case .denied: return "Screen Recording is off · Accessibility still works"
        case .unavailable: return "Not available on this Mac"
        }
    }

    private var statusColor: Color {
        switch model.visualCaptureState {
        case .ready: return .green
        case .denied: return .orange
        case .notRequested, .unavailable: return .secondary
        }
    }
}

private struct SubjectSummaryChip: View {
    let subject: MemorySubjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(subject.canonicalName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(subject.kindLabel) · \(subject.count)x")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(checkpointAccent.opacity(0.075), in: RoundedRectangle(cornerRadius: 9))
        .help(subject.keywords.isEmpty ? subject.canonicalName : subject.keywords.joined(separator: ", "))
    }
}

private struct ExpandedKnowledgeSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EXPANDED KNOWLEDGE")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text("Generic public subjects can gain fresh context; private screen text stays local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.memoryEnrichmentTotal > 0 {
                    Text(knowledgeCountLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let error = model.knowledgeLibraryError {
                HStack(spacing: 9) {
                    Image(systemName: "globe.americas.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try again") {
                        Task { await model.reloadMemories() }
                    }
                    .controlSize(.small)
                }
                .padding(11)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            }

            if model.memoryEnrichments.isEmpty {
                if model.isLoadingMemories {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading public knowledge…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                } else if model.knowledgeLibraryError == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "globe.americas")
                            .foregroundStyle(checkpointAccent)
                        Text("No public knowledge attempts yet. Keep enrichment on and work normally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
                }
            } else {
                ForEach(model.memoryEnrichments) { enrichment in
                    KnowledgeExpansionCard(item: enrichment)
                }

                if model.memoryEnrichments.count < model.memoryEnrichmentTotal {
                    HStack {
                        Spacer()
                        if model.canLoadEarlierEnrichments {
                            Button {
                                Task { await model.loadEarlierEnrichments() }
                            } label: {
                                HStack(spacing: 7) {
                                    if model.isLoadingEarlierEnrichments {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(model.isLoadingEarlierEnrichments ? "Loading…" : "Load earlier knowledge")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isLoadingEarlierEnrichments)
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var knowledgeCountLabel: String {
        let visible = model.memoryEnrichments.count
        let total = model.memoryEnrichmentTotal
        return visible < total ? "Latest \(visible) of \(total)" : "\(total) attempt\(total == 1 ? "" : "s")"
    }
}

private struct KnowledgeExpansionCard: View {
    let item: MemoryEnrichmentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.addedKnowledge ? "sparkles" : "globe.americas")
                    .foregroundStyle(item.addedKnowledge ? checkpointAccent : statusColor)
                    .frame(width: 24, height: 24)
                    .background(statusColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(subjectLabel)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text(outcomeLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.addedKnowledge ? checkpointAccent : statusColor)
                }
                Spacer()
                if let date = item.checkedDate {
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let originLabel {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(originLabel).lineLimit(1)
                    if let date = item.originDate {
                        Text("·")
                        Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if item.status.lowercased() == "rejected" {
                Text("The candidate was withheld before any public lookup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !item.outboundQuery.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PUBLIC QUERY")
                        .font(.caption2.weight(.bold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                    Text(item.outboundQuery)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if item.addedKnowledge {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.sources) { source in
                        if let url = URL(string: source.url), !source.url.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Link(destination: url) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link")
                                        Text(source.title).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption2)
                                    }
                                }
                                .font(.caption.weight(.medium))
                                if let snippet = source.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    if item.sourceCount > item.sources.count {
                        Text("+ \(item.sourceCount - item.sources.count) more public source\(item.sourceCount - item.sources.count == 1 ? "" : "s") indexed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(checkpointAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            } else if !item.policyReason.isEmpty {
                Text(item.policyReason.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(13)
        .background(
            item.addedKnowledge ? checkpointAccent.opacity(0.045) : Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    item.addedKnowledge ? checkpointAccent.opacity(0.22) : Color.primary.opacity(0.065),
                    lineWidth: 1
                )
        }
    }

    private var subjectLabel: String {
        if item.status.lowercased() == "rejected" || item.publicSubject == "[rejected]" {
            return "Subject withheld by privacy policy"
        }
        return item.publicSubject.isEmpty ? "Public context attempt" : item.publicSubject
    }

    private var outcomeLabel: String {
        switch item.status.lowercased() {
        case "complete", "cached":
            if item.sourceCount > 0 {
                return "Knowledge added · \(item.sourceCount) source\(item.sourceCount == 1 ? "" : "s")"
            }
            return "No knowledge added · no public sources found"
        case "rate_limited": return "No knowledge added · Bright Data rate limited"
        case "provider_unavailable": return "No knowledge added · Bright Data unavailable"
        case "rejected": return "No knowledge added · blocked by privacy policy"
        case "failed": return "No knowledge added · public lookup failed"
        default: return "No knowledge added · \(item.status.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private var statusColor: Color {
        switch item.status.lowercased() {
        case "complete", "cached": return item.sourceCount > 0 ? checkpointAccent : .secondary
        case "rate_limited", "provider_unavailable": return .orange
        case "rejected": return .purple
        case "failed": return .red
        default: return .secondary
        }
    }

    private var originLabel: String? {
        let pieces = [
            item.applicationName,
            item.documentLabel ?? item.windowTitle,
            item.checkpointTitle.isEmpty ? nil : item.checkpointTitle,
        ]
        .compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }
}

private struct MemoryItemCard: View {
    let item: MemoryItem
    let isDeleting: Bool
    let delete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                ApplicationGlyph(bundleID: item.appBundleID)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        if let application = item.applicationName {
                            Text(application)
                        }
                        if let label = item.documentLabel, label != item.windowTitle {
                            Text("·")
                            Text(label)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = item.capturedDate {
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    confirmsDelete = true
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this memory")
                .disabled(isDeleting)
            }

            if !item.subjects.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.subjects.prefix(4))) { subject in
                        Text(subject.canonicalName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                            .help("\(subject.kindLabel)\(subject.keywords.isEmpty ? "" : " · \(subject.keywords.joined(separator: ", "))")")
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            HStack(spacing: 9) {
                ProvenanceChip(label: "On this Mac", icon: "lock.fill", isActive: true)
                if item.provenance.contains(where: { $0.localizedCaseInsensitiveContains("moss") }) {
                    ProvenanceChip(label: "Moss", icon: "leaf.fill", isActive: true)
                }
                if !item.publicSources.isEmpty || item.outboundQuery != nil {
                    ProvenanceChip(label: "Bright Data", icon: "globe.americas.fill", isActive: true)
                }
                Spacer()
                Text(item.extractionMethod == "ocr" ? "Visual text · image discarded" : "No screenshot kept")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let query = item.outboundQuery {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Exact public query")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(query)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.top, 7)
                } label: {
                    Text(enrichmentLabel)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        }
        .confirmationDialog(
            "Delete this remembered moment?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local observation and its derived private graph evidence.")
        }
    }

    private var enrichmentLabel: String {
        switch item.enrichmentStatus {
        case "complete", "cached": return "Public context attached · \(item.publicSources.count) source\(item.publicSources.count == 1 ? "" : "s")"
        case "rate_limited": return "Public context queued for later"
        case "rejected": return "Public enrichment kept private by policy"
        case "failed", "provider_unavailable": return "Public context unavailable · local memory intact"
        default: return "Public enrichment details"
        }
    }
}

private struct MemoryActivityStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.recorder.memoryState == .on {
                Image(systemName: activityIcon)
                    .foregroundStyle(checkpointAccent)
            } else {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.secondary)
            }

            Text(model.recorder.memoryState == .on ? model.memoryActivity.title : "Memory paused")
                .font(.caption.weight(.medium))

            Text("·")
                .foregroundStyle(.tertiary)

            Text(model.recorder.memoryState == .on
                ? model.memoryActivity.detail
                : "Existing context stays searchable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            ProvenanceChip(label: "Local graph", icon: "internaldrive.fill", isActive: true)
            ProvenanceChip(label: "Moss", icon: "leaf.fill", isActive: mossIsAvailable)

            Text("0 screenshots saved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var activityIcon: String {
        let title = model.memoryActivity.title.lowercased()
        if title.contains("enrich") { return "globe.americas.fill" }
        if title.contains("sav") || title.contains("remember") { return "checkmark.circle.fill" }
        return "sparkles"
    }

    private var mossIsAvailable: Bool {
        if let status = model.providerStatus?.moss {
            return status == "ready"
        }
        return model.providerCredentials.isConnected(.moss)
    }
}

private struct TimelineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.recorder.memoryState == .on && !model.recorder.accessibility.isTrusted {
                        AccessibilityNudge(model: model)
                    }
                    if model.conversation.isEmpty {
                        EmptyStateView(model: model)
                            .padding(.top, 18)
                    } else {
                        ForEach(model.conversation) { entry in
                            ConversationEntryView(entry: entry, model: model)
                                .id(entry.id)
                        }
                        if model.isSending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.publicEnrichmentEnabled
                                    ? "Following the thread across memory and fresh public context…"
                                    : "Following the thread through your private memory…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .onChange(of: model.conversation.count) {
                if let id = model.conversation.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct AccessibilityNudge: View {
    @ObservedObject var model: AppModel
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.title3)
                    .foregroundStyle(checkpointAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remember what each window is about")
                        .font(.callout.weight(.medium))
                    Text("Allow app context for titles and document names. You choose when to grant access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not now") { dismissed = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                Button("Allow") { model.recorder.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(13)
            .background(checkpointAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

private struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                Text("Ask your work, not your folders.")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(model.recorder.memoryState == .on
                    ? "Your context is already taking shape. Ask naturally whenever you need it."
                    : "Memory is paused, but everything already remembered is still searchable.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            if model.recentCheckpoints.isEmpty {
                HStack(spacing: 8) {
                    SuggestionButton(title: "What was I just doing?", model: model)
                    SuggestionButton(title: "Find that page", model: model)
                    SuggestionButton(title: "Catch me up", model: model)
                }
            }

            if let observation = model.recorder.recentObservations.first {
                JustRememberedCard(observation: observation, model: model)
            } else if model.recorder.memoryState == .on {
                WaitingForContextCard(model: model)
            }

            RetrievalPathView(model: model)

            if !model.recentCheckpoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SAVED CHECKPOINTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(model.recentCheckpoints) { checkpoint in
                        Button {
                            model.requestResume(checkpoint)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(checkpoint.title).font(.callout.weight(.medium))
                                    Text(checkpoint.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 470)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct JustRememberedCard: View {
    let observation: WorkspaceObservation
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(checkpointAccent)
                    .frame(width: 7, height: 7)
                    .shadow(color: checkpointAccent.opacity(0.45), radius: 4)
                Text("JUST REMEMBERED")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(checkpointAccent)
                Spacer()
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 12) {
                ApplicationGlyph(bundleID: observation.bundleID)

                VStack(alignment: .leading, spacing: 5) {
                    Text(observation.extraction?.likelyIntent ?? fallbackTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(observation.applicationName)
                        if model.capturedObservationCount > 0 {
                            Text("·")
                            Text(model.memoryActivity.title)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
            }

            if let subjects = observation.extraction?.subjects, !subjects.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(subjects.prefix(3)), id: \.self) { subject in
                        Text(subject)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(checkpointAccent.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            HStack(spacing: 7) {
                ProvenanceChip(label: "On this Mac", icon: "lock.fill", isActive: true)
                if mossIsAvailable {
                    ProvenanceChip(label: "Moss", icon: "leaf.fill", isActive: true)
                }
                if model.publicEnrichmentEnabled && brightDataIsAvailable {
                    ProvenanceChip(label: "Bright Data", icon: "globe.americas.fill", isActive: true)
                }
                Spacer()
                Text("No screenshot kept")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(checkpointAccent.opacity(0.14), lineWidth: 1)
        }
        .frame(maxWidth: 470)
    }

    private var fallbackTitle: String {
        if let title = observation.windowTitle, !title.isEmpty {
            return "Working in \(observation.applicationName) on \(title)"
        }
        return "Using \(observation.applicationName)"
    }

    private var relativeTime: String {
        RelativeDateTimeFormatter().localizedString(for: observation.capturedAt, relativeTo: Date())
    }

    private var mossIsAvailable: Bool {
        if let status = model.providerStatus?.moss {
            return status == "ready"
        }
        return model.providerCredentials.isConnected(.moss)
    }

    private var brightDataIsAvailable: Bool {
        if let status = model.providerStatus?.brightData {
            return status == "ready"
        }
        return model.providerCredentials.isConnected(.brightData)
    }
}

private struct WaitingForContextCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.memoryActivity.title)
                    .font(.callout.weight(.semibold))
                Text("Switch to another app and CHECKPOINT will start building useful context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 470)
    }
}

private struct ApplicationGlyph: View {
    let bundleID: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "macwindow")
                    .font(.title3)
                    .foregroundStyle(checkpointAccent)
                    .padding(9)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var image: NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct RetrievalPathView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            RetrievalStep(icon: "macbook", title: "Local context", isActive: true)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            RetrievalStep(
                icon: "leaf.fill",
                title: "Moss recall",
                isActive: mossIsAvailable
            )
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            RetrievalStep(
                icon: "globe.americas.fill",
                title: "Fresh context",
                isActive: model.publicEnrichmentEnabled && brightDataIsAvailable
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local context, Moss recall, and optional Bright Data public context")
    }

    private var mossIsAvailable: Bool {
        if let status = model.providerStatus?.moss {
            return status == "ready"
        }
        return model.providerCredentials.isConnected(.moss)
    }

    private var brightDataIsAvailable: Bool {
        if let status = model.providerStatus?.brightData {
            return status == "ready"
        }
        return model.providerCredentials.isConnected(.brightData)
    }
}

private struct RetrievalStep: View {
    let icon: String
    let title: String
    let isActive: Bool

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .opacity(isActive ? 1 : 0.5)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(isActive ? 0.045 : 0.022), in: Capsule())
    }
}

private struct ProvenanceChip: View {
    let label: String
    let icon: String
    let isActive: Bool

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .opacity(isActive ? 1 : 0.5)
            .help(isActive ? "Available for this memory" : "Connect this service to use it")
    }
}

private struct SuggestionButton: View {
    let title: String
    @ObservedObject var model: AppModel

    var body: some View {
        Button(title) { model.useSuggestion(title) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct ConversationEntryView: View {
    let entry: ConversationEntry
    @ObservedObject var model: AppModel

    var body: some View {
        switch entry.content {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(checkpointAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
            }
        case .assistant(let response):
            AssistantOutcomeView(response: response, model: model)
                .frame(maxWidth: 430, alignment: .leading)
        }
    }
}

private struct AssistantOutcomeView: View {
    let response: TurnResponse
    @ObservedObject var model: AppModel

    var body: some View {
        switch response.kind {
        case .message:
            VStack(alignment: .leading, spacing: 9) {
                Text(response.message)
                    .textSelection(.enabled)
                    .font(.body)
                DisclosureFooter(labels: response.providerDisclosure)
            }

        case .resultCard:
            CardContainer {
                Text(response.message)
                    .font(.callout)
                if let checkpoint = response.checkpoint {
                    CheckpointSummary(checkpoint: checkpoint)
                    HStack {
                        Spacer()
                        Button("Resume") { model.requestResume(checkpoint) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(response.sources) { source in
                    if let rawURL = source.url,
                       let url = URL(string: rawURL),
                       url.scheme?.lowercased() == "https" {
                        Link(destination: url) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(checkpointAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.caption.weight(.medium))
                                    if let excerpt = source.excerpt, !excerpt.isEmpty {
                                        Text(excerpt)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                DisclosureFooter(labels: response.providerDisclosure)
            }

        case .confirmationCard:
            CardContainer {
                Label("Confirm this action", systemImage: "checkmark.shield")
                    .font(.headline)
                Text(response.message)
                    .font(.callout)
                ForEach(response.proposedActions) { action in
                    Label(action.displayName, systemImage: icon(for: action.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if model.hasDecided(response) {
                        Text("Decision sent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Cancel") { model.decide(response, decision: .cancel) }
                        Button("Resume") { model.decide(response, decision: .approve) }
                            .buttonStyle(.borderedProminent)
                            .disabled(response.proposalID == nil)
                    }
                }
                DisclosureFooter(labels: response.providerDisclosure)
            }

        case .progressCard:
            CardContainer {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(response.message).font(.callout)
                }
                DisclosureFooter(labels: response.providerDisclosure)
            }
        }
    }

    private func icon(for kind: SafeActionKind) -> String {
        switch kind {
        case .openURL: return "safari"
        case .openFile: return "doc"
        case .revealInFinder: return "folder"
        case .activateApp: return "macwindow"
        case .restoreCheckpoint: return "arrow.counterclockwise"
        }
    }
}

private struct CheckpointSummary: View {
    let checkpoint: CheckpointRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(checkpoint.title)
                .font(.headline)
            Text(checkpoint.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let nextStep = checkpoint.nextStep, !nextStep.isEmpty {
                Text("Next: \(nextStep)")
                    .font(.caption)
            }
            if !checkpoint.artifacts.isEmpty {
                Text(checkpoint.artifacts.prefix(4).map(\.displayName).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct DisclosureFooter: View {
    let labels: [String]

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 8) {
                ForEach(normalizedLabels, id: \.self) { label in
                    Label(label, systemImage: icon(for: label))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private var normalizedLabels: [String] {
        var seen: Set<String> = []
        var result: [String] = []

        func append(_ label: String) {
            guard !seen.contains(label) else { return }
            seen.insert(label)
            result.append(label)
        }

        for raw in labels {
            let lowercased = raw.lowercased()
            if lowercased.contains("bright") {
                if lowercased.contains("live") { append("Live web") }
                append("Bright Data")
                if lowercased.contains("public context") { append("Saved locally") }
            } else if lowercased.contains("moss") {
                append("On this Mac")
                append("Moss")
            } else if lowercased.contains("livekit") || lowercased.contains("voice") {
                append("Voice")
                append("LiveKit")
            } else if lowercased.contains("openai") {
                append("Cloud reasoning")
                append("OpenAI")
            } else if lowercased.contains("local") || lowercased.contains("sqlite") {
                append("On this Mac")
            } else {
                append(raw)
            }
        }

        return result
    }

    private func icon(for label: String) -> String {
        switch label {
        case "Bright Data": return "globe.americas.fill"
        case "Live web": return "network"
        case "Saved locally": return "internaldrive.fill"
        case "Moss": return "leaf.fill"
        case "LiveKit": return "waveform.circle.fill"
        case "Voice": return "mic.fill"
        case "OpenAI": return "sparkles"
        case "Cloud reasoning": return "cloud.fill"
        case "On this Mac": return "lock.fill"
        default: return "checkmark.circle"
        }
    }
}

private struct ProviderConnectionsView: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    let doneTitle: String
    let done: () -> Void

    @State private var editingProvider: ProviderKind?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect services")
                    .font(.title2.weight(.semibold))
                Text("Optional. CHECKPOINT works in local mode without any of these.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(ProviderKind.allCases) { provider in
                        ProviderCard(
                            provider: provider,
                            isConnected: providerIsEffectivelyConnected(provider, model: model),
                            isOperatorProvided: model.providerCredentials.wasProvidedByOperator(provider),
                            edit: { editingProvider = provider },
                            remove: {
                                Task {
                                    do {
                                        try await model.removeProvider(provider)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        )
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Connections you add are saved in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(doneTitle, action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(compact ? 28 : 24)
        .frame(
            minWidth: compact ? nil : 500,
            idealWidth: compact ? nil : 520,
            minHeight: compact ? nil : 520,
            idealHeight: compact ? nil : 560
        )
        .sheet(item: $editingProvider) { provider in
            ProviderEditor(
                provider: provider,
                isReplacing: providerIsEffectivelyConnected(provider, model: model)
            ) { draft in
                Task {
                    do {
                        try await model.saveProvider(provider, draft: draft)
                        editingProvider = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

@MainActor
private func effectiveConnectionCount(_ model: AppModel) -> Int {
    ProviderKind.allCases.filter { providerIsEffectivelyConnected($0, model: model) }.count
}

@MainActor
private func providerIsEffectivelyConnected(_ provider: ProviderKind, model: AppModel) -> Bool {
    if model.providerCredentials.isConnected(provider) { return true }

    switch provider {
    case .brightData:
        return model.providerStatus?.brightData == "ready"
    case .moss:
        return model.providerStatus?.moss == "ready"
    case .liveKit:
        guard let status = model.providerStatus?.voice else { return false }
        return status != "not_configured" && status != "unavailable"
    case .openAI:
        return model.providerStatus?.planner == "openai"
    }
}

private struct ProviderCard: View {
    let provider: ProviderKind
    let isConnected: Bool
    let isOperatorProvided: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: providerIcon)
                .font(.title3)
                .foregroundStyle(checkpointAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.callout.weight(.semibold))
                    if isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(checkpointAccent)
                    }
                }
                Text(connectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link("Open", destination: provider.officialURL)
                .font(.caption)
            Button(isConnected ? "Replace" : "Connect", action: edit)
                .buttonStyle(.bordered)
                .controlSize(.small)
            if isConnected {
                Menu {
                    Button("Remove connection", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var providerIcon: String {
        switch provider {
        case .brightData: return "sun.max.fill"
        case .moss: return "leaf.fill"
        case .liveKit: return "waveform.circle.fill"
        case .openAI: return "sparkles"
        }
    }

    private var connectionDescription: String {
        if isOperatorProvided && isConnected { return "Connected · provided by organizer" }
        if isConnected { return "Connected · \(provider.purpose)" }
        return "Not connected · \(provider.purpose)"
    }
}

private struct ProviderEditor: View {
    let provider: ProviderKind
    let isReplacing: Bool
    let save: (ProviderDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProviderDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(isReplacing ? "Replace" : "Connect") \(provider.name)")
                    .font(.title2.weight(.semibold))
                Text(isReplacing
                    ? "Existing values stay hidden. Paste one replacement connection."
                    : "One paste. CHECKPOINT reads the connection locally and stores it in Keychain.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(provider.connectionLabel)
                    .font(.caption)

                SecureField(provider.connectionPlaceholder, text: $draft.connectionCode)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            draft.connectionCode = pasted
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !draft.connectionCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Ready to save", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(checkpointAccent)
                    }
                }

                Text(provider.connectionGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link("Open \(provider.name)", destination: provider.officialURL)
                .font(.caption)

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save securely") { save(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnyValue)
            }
        }
        .padding(24)
        .frame(width: 470, height: 410)
    }

    private var hasAnyValue: Bool {
        !draft.connectionCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ComposerView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.activeVoiceStatus {
                HStack(spacing: 6) {
                    Image(systemName: model.voiceState == .listening ? "waveform" : "ellipsis")
                    Text(status)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(model.voiceState == .listening ? Color.red : .secondary)
                .accessibilityLabel(status)
            }

            HStack(alignment: .bottom, spacing: 9) {
                TextField("Ask your work memory anything…", text: $model.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { model.submit() }

                Button {
                    model.startVoice()
                } label: {
                    Image(systemName: microphoneIcon)
                        .foregroundStyle(model.voiceState == .listening ? Color.red : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
                .help(microphoneHelp)

                Button {
                    model.submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(checkpointAccent)
                }
                .buttonStyle(.plain)
                .disabled(model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(focused ? checkpointAccent.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 1)
            }

            HStack(spacing: 6) {
                Label("\(model.capturedObservationCount) moment\(model.capturedObservationCount == 1 ? "" : "s") remembered", systemImage: "lock.fill")
                if model.publicEnrichmentEnabled {
                    Text("·")
                    Label("Fresh public context on", systemImage: "globe.americas")
                }
                Spacer()
                Text("Text or voice → search memory")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkpointFocusComposer)) { _ in
            focused = true
        }
    }

    private var microphoneIcon: String {
        switch model.voiceState {
        case .unavailable: return "mic.slash"
        case .connecting, .finishing: return "stop.circle"
        case .listening: return "stop.circle.fill"
        case .idle: return "mic.fill"
        }
    }

    private var microphoneHelp: String {
        switch model.voiceState {
        case .unavailable:
            return model.voiceStatusMessage ?? "Voice is unavailable; typing works"
        case .connecting, .listening, .finishing:
            return "Stop voice request"
        case .idle:
            return "Talk to CHECKPOINT"
        }
    }
}

private struct CapturePreviewView: View {
    @ObservedObject var model: AppModel
    @State private var title = "New checkpoint"
    @State private var summary = ""
    @State private var nextStep = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save this checkpoint?")
                    .font(.title2.weight(.semibold))
                Text("Review exactly what will be stored on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Title", text: $title)
                TextField("Short summary", text: $summary)
                TextField("Next step or blocker", text: $nextStep)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                Text("CAPTURED ITEMS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if model.recorder.artifacts.isEmpty {
                    Text("No app metadata was available. You can still save the note above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recorder.artifacts) { artifact in
                        HStack {
                            Image(systemName: artifactIcon(artifact.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(artifact.displayName)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.recorder.removeArtifact(id: artifact.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Spacer()
            HStack {
                Button("Back") { model.recorder.resumeRemembering() }
                Spacer()
                Button("Cancel") { model.cancelCapture() }
                Button("Save checkpoint") {
                    model.saveCheckpoint(title: title, summary: summary, nextStep: nextStep)
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
            }
        }
        .padding(24)
        .frame(width: 470, height: 510)
        .onAppear {
            if let suggestion = model.captureSuggestedTitle {
                title = suggestion
            } else if let firstApp = model.recorder.artifacts.first(where: { $0.kind == .app }) {
                title = firstApp.displayName.components(separatedBy: " — ").first ?? "New checkpoint"
            }
        }
    }

    private func artifactIcon(_ kind: ArtifactKind) -> String {
        switch kind {
        case .app: return "macwindow"
        case .file: return "doc"
        case .url: return "link"
        case .selection: return "text.quote"
        case .note: return "note.text"
        }
    }
}
