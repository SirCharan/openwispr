import SwiftUI
import AppKit

/// Live meeting transcript: start/pause/stop, timestamped speaker lines, rename-at-stop, export.
struct MeetingView: View {
    @ObservedObject var controller: MeetingController
    var openAISettings: () -> Void = {}
    @State private var screenRecOK = CGPreflightScreenCaptureAccess()
    @State private var renames: [String: String] = [:]
    @State private var archive: [MeetingArchive.Entry] = []
    @State private var selected: String?   // nil = the live meeting
    @State private var pastLines: [MeetingLine] = []
    @State private var pastStats: MeetingStats?

    /// Small labelled dot: green while audio buffers keep arriving on that stream, red once
    /// they stop. Text carries the state too, so it does not rely on colour alone.
    private func streamDot(_ label: String, healthy: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(healthy ? Brand.ok : Brand.danger)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Brand.caption)
                .foregroundStyle(healthy ? Brand.muted : Brand.danger)
        }
        .help(healthy ? "\(label): audio arriving" : "\(label): no audio arriving")
        .accessibilityLabel("\(label) audio \(healthy ? "arriving" : "stopped")")
    }

    // MARK: past meetings

    private var showLive: Bool { controller.isRunning || !controller.lines.isEmpty }
    private var viewingPast: Bool { selected != nil && !controller.isRunning }
    private var shownLines: [MeetingLine] { viewingPast ? pastLines : controller.lines }
    private var shownStats: MeetingStats? { viewingPast ? pastStats : controller.stats }

    private func reload() {
        archive = MeetingArchive.list()
        if selected == nil && !showLive, let first = archive.first { select(first.stamp) }
        else if let s = selected, !archive.contains(where: { $0.stamp == s }) { selected = nil }
    }

    private func select(_ stamp: String?) {
        selected = stamp
        guard let stamp, let loaded = MeetingArchive.load(stamp: stamp) else { pastLines = []; pastStats = nil; return }
        pastLines = loaded.lines
        pastStats = loaded.stats
    }

    private static let rowDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, h:mm a"; return f
    }()

    private func row(title: String, detail: String, badge: Bool, active: Bool, dot: Color? = nil, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(title).font(Brand.serif(12)).foregroundStyle(Brand.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if badge {
                        Text("stats").font(.system(size: 10)).foregroundStyle(Brand.muted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line, lineWidth: 1))
                    }
                }
                Text(detail).font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(1)
            }
            .padding(.vertical, 6).padding(.horizontal, Brand.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Brand.surface : .clear, in: RoundedRectangle(cornerRadius: Brand.rSm))
            .overlay(RoundedRectangle(cornerRadius: Brand.rSm).strokeBorder(active ? Brand.line : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Brand.rSm))
        }
        .buttonStyle(.plain)
    }

    private var pastList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if showLive {
                    row(title: "Live", detail: controller.isRunning ? controller.status : "\(controller.lines.count) lines, unsaved view",
                        badge: false, active: selected == nil, dot: controller.isRunning ? Brand.danger : Brand.muted) { select(nil) }
                }
                ForEach(archive) { e in
                    row(title: Self.rowDate.string(from: e.date),
                        detail: [e.duration, "\(e.speakers.count) speaker\(e.speakers.count == 1 ? "" : "s")"].filter { !$0.isEmpty }.joined(separator: " · "),
                        badge: e.hasStats, active: selected == e.stamp && !controller.isRunning) { select(e.stamp) }
                }
            }
            .padding(Brand.s8)
        }
        .frame(width: 220)
        .background(Brand.bg)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showLive || !archive.isEmpty {
                pastList
                Divider()
            }
            detail
        }
        .frame(minWidth: 680, minHeight: 400)
        .background(Brand.bg)
        .onAppear { screenRecOK = CGPreflightScreenCaptureAccess(); reload() }
        .task { await controller.refreshSummaryChoice() }
        .onChange(of: controller.isRunning) { _, running in
            if running { selected = nil } else { reload() }
        }
        .sheet(isPresented: Binding(
            get: { controller.showRenameSheet && !controller.isRunning && !viewingPast },
            set: { controller.showRenameSheet = $0 }
        )) { renameSheet }
    }

    private var toolbar: some View {
        HStack(spacing: Brand.s8) {
            Circle()
                .fill(controller.isRunning ? (controller.isPaused ? Brand.warn : Brand.danger) : Brand.ok)
                .frame(width: 9, height: 9)
            if controller.isRunning {
                Text(controller.status).font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(1)
            }
            if controller.isRunning {
                // Per-stream capture health. Without this a stalled stream is
                // indistinguishable from a room where nobody is talking.
                streamDot("You", healthy: controller.micHealthy)
                streamDot("Others", healthy: controller.systemHealthy)
            }
            Spacer(minLength: 0)
            Picker("Language", selection: $controller.meetingLanguage) {
                ForEach(Languages.list, id: \.code) { lang in Text(lang.name).tag(lang.code ?? "auto") }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Brand.text)
            .frame(width: 116)
            .padding(.vertical, 2)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.rSm))
            .overlay(RoundedRectangle(cornerRadius: Brand.rSm).strokeBorder(Brand.line, lineWidth: 1))
            .help("Meeting language — lock to Hindi/English for mixed calls; Auto re-detects per chunk")
            if controller.isRunning {
                PaperButton(title: controller.isPaused ? "Resume" : "Pause", role: .secondary) {
                    Task { controller.isPaused ? await controller.resume() : await controller.pause() }
                }
                PaperButton(title: "Stop", role: .destructive) { Task { await controller.stop() } }
                    .accessibilityLabel("Stop recording")
                    .accessibilityIdentifier("Stop recording")
            } else {
                PaperButton(title: "Start recording", role: .primary) { Task { await controller.start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!screenRecOK) // pre-start check: no surprises at meeting time
                    .opacity(screenRecOK ? 1 : 0.5)
                    .accessibilityIdentifier("Start recording")
            }
            let noModel = controller.summaryChoice == SummaryChoice.none
            let noSummary = viewingPast || controller.lines.isEmpty || controller.isRunning || controller.summarizing || noModel
            PaperButton(title: controller.summarizing ? "Summarizing…" : "Summarize", role: .secondary) {
                Task { await controller.summarize() }
            }
            .disabled(noSummary).opacity(noSummary ? 0.5 : 1)
            .help(noModel ? "Set up an AI model to summarise" : "Summarise this meeting")
            PaperButton(title: "Export…", role: .secondary) { export() }
                .disabled(shownLines.isEmpty).opacity(shownLines.isEmpty ? 0.5 : 1)
        }
        .padding(12)
    }

    private func setupCard(title: String, line: String) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: Brand.s8) {
                Text(title).font(Brand.title).foregroundStyle(Brand.text)
                Text(line).font(Brand.body).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
                PaperButton(title: "Open AI settings", role: .secondary, action: openAISettings)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            toolbar
            if let banner = controller.banner {
                Text(banner)
                    .font(Brand.caption.bold())
                    .foregroundStyle(Brand.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(Brand.danger)
            }
            Divider()

            if !viewingPast, controller.summarizing {
                HStack(spacing: Brand.s8) {
                    ProgressView().controlSize(.small)
                    Text("Summarising with \(controller.summarizingWith)…").font(Brand.caption).foregroundStyle(Brand.muted)
                }
                .padding(Brand.s12).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            } else if !viewingPast, let err = controller.summaryError {
                setupCard(title: "Summary failed", line: err).padding(Brand.s12)
                Divider()
            } else if !viewingPast, !controller.lines.isEmpty, !controller.isRunning,
                      controller.summary == nil, controller.summaryChoice == SummaryChoice.none {
                setupCard(title: "Summaries need an AI model",
                          line: "Turn on Apple Intelligence, install Ollama, or add an API key.").padding(Brand.s12)
                Divider()
            }
            if !viewingPast, let summary = controller.summary {
                ScrollView {
                    Text(LocalizedStringKey(summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .background(Brand.coral.opacity(0.06))
                Divider()
            }

            if let st = shownStats, !controller.isRunning || viewingPast {
                statsBlock(st)
                Divider()
            }

            if shownLines.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: !screenRecOK || controller.needsScreenRec ? "exclamationmark.shield" : "person.2.wave.2")
                        .font(Brand.serif(36)).foregroundStyle(!screenRecOK || controller.needsScreenRec ? Brand.warn : Brand.muted)
                    if !screenRecOK || controller.needsScreenRec {
                        Text("Meetings need Screen Recording permission (that's how macOS exposes system audio). Click below — that adds OpenWispr to the list — then switch it ON and relaunch. A leftover \"Whispr\" entry from the old app can be removed.")
                            .foregroundStyle(Brand.muted).multilineTextAlignment(.center)
                        PaperButton(title: "Request permission + open settings", role: .secondary) {
                            CGRequestScreenCaptureAccess() // registers OpenWispr in the pane; without this the row never appears
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Button("I've enabled it — re-check") { screenRecOK = CGPreflightScreenCaptureAccess() }
                            .buttonStyle(.plain).font(Brand.caption).foregroundStyle(Brand.muted)
                    } else {
                        Text("Record a call without a bot. Your mic and the other side are captured and labelled after you stop.")
                            .font(Brand.body).foregroundStyle(Brand.text).multilineTextAlignment(.center)
                        Text("Transcripts are saved to Documents/OpenWispr. The first meeting downloads a 100 MB speaker model.")
                            .font(Brand.caption).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
                    }
                }
                .padding()
                .frame(maxWidth: 460)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(shownLines) { line in
                        TranscriptLine(line: line)
                            .id(line.id)
                            .listRowBackground(Brand.bg)
                    }
                    .id(selected ?? "live")
                    .scrollContentBackground(.hidden)
                    .background(Brand.bg)
                    .onChange(of: controller.lines.count) { _, _ in
                        if !viewingPast, let last = controller.lines.last { proxy.scrollTo(last.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statsBlock(_ st: MeetingStats) -> some View {
        VStack(alignment: .leading, spacing: Brand.s12) {
            HStack(spacing: Brand.s12) {
                StatTile(value: MeetingController.mmss(st.duration), label: "duration")
                StatTile(value: String(format: "%.1f", st.questionsPerHour), label: "questions/hr")
                StatTile(value: String(format: "%.1f", st.fillersPerMinute), label: "fillers/min")
                StatTile(value: "\(st.interruptions)", label: "interruptions")
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(st.speakers.filter { $0.talkSeconds > 0 }.sorted { $0.talkSeconds > $1.talkSeconds }, id: \.name) { sp in
                HStack(spacing: 10) {
                    Text(sp.name).font(Brand.body).foregroundStyle(Brand.text)
                        .frame(width: 90, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 4).fill(Brand.coral.opacity(0.85))
                            .frame(width: max(3, g.size.width * CGFloat(sp.sharePct / 100)), height: 14)
                    }
                    .frame(height: 14)
                    Text("\(Int(sp.sharePct.rounded()))%").font(Brand.mono(11)).foregroundStyle(Brand.muted)
                        .frame(width: 34, alignment: .trailing)
                    Text("\(Int(sp.wpm.rounded())) wpm · \(sp.turns) turns · longest \(MeetingController.mmss(sp.longestMonologue))\(sp.longMonologue ? " (long)" : "")")
                        .font(Brand.mono(10)).foregroundStyle(Brand.muted)
                }
            }
        }
        .padding(Brand.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.bg)
    }

    /// Post-meeting labeling: name each detected speaker (ck's flow).
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Label the speakers").font(Brand.title).foregroundStyle(Brand.text)
            Text("Type real names — the transcript and the saved file update everywhere.")
                .font(Brand.caption).foregroundStyle(Brand.muted)
            ForEach(controller.distinctSpeakers, id: \.self) { s in
                HStack {
                    Text(s).font(Brand.body)
                        .frame(width: 90, alignment: .trailing).foregroundStyle(Brand.muted)
                    TextField(s == "You" ? "your name (optional)" : "e.g. Priya", text: Binding(
                        get: { renames[s] ?? "" },
                        set: { renames[s] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Skip") { controller.showRenameSheet = false; renames = [:] }
                Button("Apply names") {
                    controller.renameSpeakers(renames)
                    controller.showRenameSheet = false
                    renames = [:]
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renames.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(Brand.s24)
        .frame(width: 380)
        .background(Brand.bg)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "meeting-\(selected ?? String(ISO8601DateFormatter().string(from: Date()).prefix(10))).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            if viewingPast, let stamp = selected {
                try? FileManager.default.removeItem(at: url)   // NSSavePanel already confirmed overwrite
                try? FileManager.default.copyItem(at: MeetingArchive.fileURL(stamp: stamp), to: url)
            } else {
                try? controller.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// One transcript line: mono timestamp at muted, speaker in body weight with the accent, then text.
private struct TranscriptLine: View {
    let line: MeetingLine
    var body: some View {
        HStack(alignment: .top, spacing: Brand.s8) {
            Text(MeetingController.mmss(line.start))
                .font(Brand.mono(11)).foregroundStyle(Brand.muted)
                .frame(width: 44, alignment: .trailing)
            Text(line.speaker)
                .font(Brand.body).foregroundStyle(line.speaker == "You" ? Brand.coral : Brand.info)
                .frame(width: 70, alignment: .trailing)
            Text(line.text).font(Brand.body).foregroundStyle(Brand.text)
        }
        .padding(.vertical, 2)
    }
}
