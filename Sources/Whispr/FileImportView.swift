import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class FileImportModel: ObservableObject {
    enum State { case idle, working(String), done(String), failed(String) }
    @Published var state: State = .idle
    private let transcriber: Transcriber

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func transcribe(_ url: URL) {
        state = .working(url.lastPathComponent)
        Task {
            do {
                let raw = try await transcriber.transcribeFile(url.path, language: Settings.languageCode)
                let text = TextProcessor.process(raw, options: Settings.textOptions)
                if !text.isEmpty { HistoryStore.add(text) }
                state = .done(text.isEmpty ? "(no speech found)" : text)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Transcribe an audio file: open-panel button + drag-and-drop; result copyable, saved to History.
struct FileImportView: View {
    @ObservedObject var model: FileImportModel
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .idle:
                dropZone
            case .working(let name):
                ProgressView("Transcribing \(name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let text):
                ScrollView {
                    Text(text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Transcribe another…") { model.state = .idle }
                }
            case .failed(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
                    Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { model.state = .idle }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 320)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Drop an audio file here").font(.title3)
            Text("mp3 · m4a · wav · mp4 · flac — transcribed on-device, saved to History")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose file…") { openPanel() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropActive ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 2, dash: [7]))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.transcribe(url) } }
            }
            return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.transcribe(url) }
    }
}

/// Hosts the file-import view in a window.
@MainActor
final class FileImportWindowController {
    private var window: NSWindow?
    private var model: FileImportModel?

    func show(transcriber: Transcriber) {
        if window == nil {
            let m = FileImportModel(transcriber: transcriber)
            model = m
            let win = NSWindow(contentViewController: NSHostingController(rootView: FileImportView(model: m)))
            win.title = "Transcribe File"
            win.styleMask = [.titled, .closable, .resizable]
            win.isReleasedWhenClosed = false
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
