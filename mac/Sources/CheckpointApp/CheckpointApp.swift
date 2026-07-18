import AppKit
import SwiftUI

extension Notification.Name {
    static let checkpointFocusComposer = Notification.Name("checkpoint.focusComposer")
}

final class CheckpointAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct CheckpointApplication: App {
    @NSApplicationDelegateAdaptor(CheckpointAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("CHECKPOINT", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 600, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Memory") {
                Button("Browse Memories…") {
                    model.openMemories()
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
                }

                Button(model.recorder.memoryState == .on ? "Pause Memory" : "Turn Memory On") {
                    model.toggleMemory()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Erase Last 15 Minutes…") {
                    model.eraseLastFifteenMinutes()
                }

                Divider()

                Toggle(
                    "Visual Fallback · Screenshots Never Saved",
                    isOn: Binding(
                        get: { model.visualFallbackEnabled },
                        set: { model.setVisualFallback($0) }
                    )
                )
            }
        }

        MenuBarExtra {
            CheckpointMenuBarPanel(model: model)
        } label: {
            Image(systemName: model.recorder.memoryState == .on
                ? "brain.head.profile.fill"
                : "pause.circle")
                .accessibilityLabel(
                    model.recorder.memoryState == .on ? "CHECKPOINT — Memory On" : "CHECKPOINT — Memory Paused"
                )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CheckpointMenuBarPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("checkpoint.didCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var confirmsErase = false
    @FocusState private var composerFocused: Bool

    private let accent = Color(red: 0.24, green: 0.48, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.13))
                    Image(systemName: "brain.head.profile.fill")
                        .foregroundStyle(accent)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("CHECKPOINT")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.7)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.recorder.memoryState == .on ? accent : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(model.recorder.memoryState == .on ? "Memory is on" : "Memory is paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(
                    didCompleteOnboarding
                        ? (model.recorder.memoryState == .on ? "Pause" : "Resume")
                        : "Set Up"
                ) {
                    if didCompleteOnboarding {
                        model.toggleMemory()
                    } else {
                        openCheckpoint()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                currentContext

                if didCompleteOnboarding {
                    HStack(spacing: 8) {
                        TextField("Ask your memory…", text: $model.composer)
                            .textFieldStyle(.plain)
                            .focused($composerFocused)
                            .onSubmit(askFromMenuBar)

                        Button(action: askFromMenuBar) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isSending
                        )
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                } else {
                    Text("Open CHECKPOINT to finish the one-minute setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: openCheckpoint) {
                    HStack {
                        Label("Open CHECKPOINT", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    model.openMemories()
                    openCheckpoint()
                } label: {
                    HStack {
                        Label("Browse memories", systemImage: "clock.arrow.circlepath")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(model.capturedObservationCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!didCompleteOnboarding)
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                if didCompleteOnboarding {
                    Toggle(
                        isOn: Binding(
                            get: { model.publicEnrichmentEnabled },
                            set: { model.setPublicEnrichment($0) }
                        )
                    ) {
                        Label("Fresh public context", systemImage: "globe.americas")
                            .font(.callout)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 14)

                    Toggle(
                        isOn: Binding(
                            get: { model.visualFallbackEnabled },
                            set: { model.setVisualFallback($0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Visual fallback", systemImage: "text.viewfinder")
                                .font(.callout)
                            Text("Process once in memory · never save screenshots")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    Label("Private until you finish setup", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }

                Divider().padding(.leading, 14)

                HStack(spacing: 16) {
                    Button {
                        confirmsErase = true
                    } label: {
                        Label("Erase 15 min", systemImage: "eraser")
                    }
                    .buttonStyle(.plain)
                    .disabled(!didCompleteOnboarding)

                    Spacer()

                    Button {
                        model.showsConnections = true
                        openCheckpoint()
                    } label: {
                        Label("Connections", systemImage: "link")
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.plain)
                    .help("Quit CHECKPOINT")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .background(Color.primary.opacity(0.025))
        }
        .frame(width: 340)
        .confirmationDialog(
            "Erase recent memory?",
            isPresented: $confirmsErase,
            titleVisibility: .visible
        ) {
            Button("Erase last 15 minutes", role: .destructive) {
                model.eraseLastFifteenMinutes()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var currentContext: some View {
        if !didCompleteOnboarding {
            HStack(spacing: 10) {
                Image(systemName: "hand.wave.fill")
                    .foregroundStyle(accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to CHECKPOINT")
                        .font(.callout.weight(.medium))
                    Text("One quick setup, then just keep working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.recorder.memoryState == .paused {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing new is being remembered")
                        .font(.callout.weight(.medium))
                    Text("Your existing memory is still searchable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let observation = model.recorder.recentObservations.first {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(observation.extraction?.likelyIntent ?? "Using \(observation.applicationName)")
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(model.memoryActivity.detail)
                        Text("·")
                        Text("\(model.capturedObservationCount) remembered")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.memoryActivity.title)
                        .font(.callout.weight(.medium))
                    Text(model.memoryActivity.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func askFromMenuBar() {
        guard !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        openCheckpoint()
        model.submit()
    }

    private func openCheckpoint() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .checkpointFocusComposer, object: nil)
        }
    }
}
