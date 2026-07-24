import SwiftUI
import AppKit

/// Shared observable state the main window binds to.
@MainActor
final class AppState: ObservableObject {
    @Published var status = "starting…"
    @Published var isRecording = false
}

/// The app's home window: status, how-to, quick actions, recent transcripts.
struct MainView: View {
    @ObservedObject var state: AppState
    let onSettings: () -> Void
    let onMeeting: () -> Void
    let onImport: () -> Void

    @State private var recent: [HistoryEntry] = []

    private var hotkeyHint: String {
        Settings.hotkeyMode == "fn"
            ? "fn"
            : (KeyboardShortcuts.getShortcut(for: .dictate).map(String.init(describing:)) ?? "⌘⇧D")
    }

    var body: some View {
        VStack(spacing: 0) {
            // header: status + the one instruction that matters
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.isRecording ? .red : (state.status.hasPrefix("ready") ? Color.green : .secondary))
                        .frame(width: 9, height: 9)
                    Text(state.status).font(.callout).foregroundStyle(.secondary)
                }
                Text("Hold ") + Text(hotkeyHint).bold().foregroundStyle(Theme.accent) + Text(" anywhere, speak, release — your words paste at the cursor.")
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 10) {
                actionButton("gearshape", "Settings", onSettings)
                actionButton("person.2.wave.2", "Record Meeting", onMeeting)
                actionButton("waveform.badge.plus", "Transcribe File", onImport)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Recent transcripts").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10)
                if recent.isEmpty {
                    Text("Nothing yet — hold \(hotkeyHint) and say something.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(recent) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).lineLimit(2)
                            Text(e.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 480, height: 440)
        .onAppear { recent = Array(HistoryStore.load().prefix(5)) }
        .onChange(of: state.status) { _, _ in recent = Array(HistoryStore.load().prefix(5)) }
    }

    private func actionButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }
}

import KeyboardShortcuts

/// Hosts the main window; shown at launch and from the menu.
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show(state: AppState, onSettings: @escaping () -> Void,
              onMeeting: @escaping () -> Void, onImport: @escaping () -> Void) {
        if window == nil {
            let view = MainView(state: state, onSettings: onSettings, onMeeting: onMeeting, onImport: onImport)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Whispr"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
