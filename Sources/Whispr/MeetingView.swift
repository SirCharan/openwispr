import SwiftUI
import AppKit

/// Live meeting transcript: start/stop, You/Others lines, export Markdown.
struct MeetingView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(controller.isRunning ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.isRunning {
                    Button("Stop") { Task { await controller.stop() } }
                        .tint(.red)
                } else {
                    Button("Start recording") { Task { await controller.start() } }
                        .keyboardShortcut(.defaultAction)
                }
                Button(controller.summarizing ? "Summarizing…" : "Summarize") {
                    Task { await controller.summarize() }
                }
                .disabled(controller.lines.isEmpty || controller.isRunning || controller.summarizing)
                Button("Export…") { export() }
                    .disabled(controller.lines.isEmpty)
            }
            .padding(12)
            Divider()

            if let summary = controller.summary {
                ScrollView {
                    Text(LocalizedStringKey(summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .background(Color.accentColor.opacity(0.06))
                Divider()
            }

            if controller.lines.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Start recording to capture your mic (You) and system audio (Others).")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("System audio needs Screen Recording permission.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(controller.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.speaker)
                                .font(.caption.bold())
                                .foregroundStyle(line.speaker == "You" ? Color.accentColor : .orange)
                                .frame(width: 48, alignment: .trailing)
                            Text(line.text)
                        }
                        .id(line.id)
                        .padding(.vertical, 2)
                    }
                    .onChange(of: controller.lines.count) { _, _ in
                        if let last = controller.lines.last { proxy.scrollTo(last.id) }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "meeting-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? controller.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Hosts the meeting view in a resizable window.
@MainActor
final class MeetingWindowController {
    private var window: NSWindow?
    private var controller: MeetingController?

    func show(transcriber: Transcriber) {
        if window == nil {
            let ctrl = MeetingController(transcriber: transcriber)
            controller = ctrl
            let host = NSHostingController(rootView: MeetingView(controller: ctrl))
            let win = NSWindow(contentViewController: host)
            win.title = "Whispr Meeting"
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 560, height: 460))
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
