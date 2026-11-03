import SwiftUI
import AppKit
import KeyboardShortcuts

/// Shared observable state the home window binds to.
@MainActor
final class AppState: ObservableObject {
    @Published var status = "starting…"
    @Published var isRecording = false
    @Published var pane: HomePane = .dictations
    @Published var modelReady = true          // false → dictation no-ops; show the reload banner
    @Published var modelError: String?        // set when the speech model fails to load
}

extension Notification.Name {
    static let whisprModelChanged = Notification.Name("whispr.modelChanged")
    static let whisprReloadModel = Notification.Name("whispr.reloadModel")
    /// Correction toast proposing vocabulary terms. `userInfo["terms"]` is `[String]`.
    /// The toast never writes to the dictionary itself — the user confirms in the Dictionary pane.
    static let whisprStageVocab = Notification.Name("whispr.stageVocab")
}

enum HomePane: String, CaseIterable, Identifiable {
    case dictations = "Dictations"
    case insights = "Insights"
    case meetings = "Meetings"
    case importFile = "Transcribe File"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case models = "Models"
    case ai = "AI"
    case apps = "Apps"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dictations: "mic"
        case .insights: "chart.bar.xaxis"
        case .meetings: "person.2.wave.2"
        case .importFile: "waveform.badge.plus"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .models: "cpu"
        case .ai: "sparkles"
        case .apps: "app.badge"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct HomeView: View {
    @ObservedObject var state: AppState
    let meetingController: MeetingController
    let importModel: FileImportModel

    @State private var search = ""
    /// Held in state so dismissing animates, rather than waiting for a view reload.
    @State private var showSnippetTip = Settings.onboarded && !Settings.snippetsTipSeen
    private var pane: HomePane { state.pane }

    private func dismissSnippetTip() {
        Settings.snippetsTipSeen = true
        withAnimation(.easeOut(duration: 0.18)) { showSnippetTip = false }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Brand.line).frame(width: 1)
            detail
        }
        .background(Brand.bg)
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: - Sidebar

    private static let groups: [(String, [HomePane])] = [
        ("Capture", [.dictations, .meetings, .importFile]),
        ("Learn", [.insights]),
        ("Personalize", [.dictionary, .snippets, .apps]),
        ("System", [.models, .ai, .settings, .about]),
    ]

    private var statusColor: Color {
        state.isRecording ? Brand.danger : (state.status.hasPrefix("ready") ? Brand.ok : Brand.muted)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Brand.s4) {
            HStack(spacing: 0) {
                Text("O").font(Brand.serif(24)).foregroundStyle(Brand.coral) + Text("penWispr").font(Brand.serif(24)).foregroundStyle(Brand.text)
            }
            .padding(.bottom, 2)
            Text("Hi, \(NSFullUserName().components(separatedBy: " ").first ?? NSFullUserName())")
                .font(Brand.caption).foregroundStyle(Brand.muted)
                .padding(.bottom, Brand.s8)

            ScrollView {
                VStack(alignment: .leading, spacing: Brand.s4) {
                    ForEach(Self.groups, id: \.0) { title, panes in
                        Text(title).font(Brand.serif(13)).foregroundStyle(Brand.muted)
                            .padding(.top, Brand.s12).padding(.horizontal, 10)
                        ForEach(panes) { p in
                            sidebarRow(p)
                            // Sits directly under the row it points at, so no overlay anchoring is needed.
                            if p == .snippets, showSnippetTip {
                                SnippetTip(
                                    onOpen: { state.pane = .snippets; dismissSnippetTip() },
                                    onDismiss: dismissSnippetTip
                                )
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: Brand.s8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ModelManager().selectedModel).font(Brand.caption).foregroundStyle(Brand.text).lineLimit(1)
                    Text(state.status).font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(2)
                }
            }
            .padding(.top, Brand.s8)
            .accessibilityElement(children: .combine)
        }
        .padding(Brand.s16)
        .frame(width: 230)
    }

    private func sidebarRow(_ p: HomePane) -> some View {
        Button {
            state.pane = p
        } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).frame(width: 18)
                Text(p.rawValue)
                Spacer()
            }
            .font(.system(size: 13.5, weight: pane == p ? .semibold : .regular))
            .foregroundStyle(pane == p ? Brand.text : Brand.muted)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: Brand.rMd - 2).fill(pane == p ? Brand.coralSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.rawValue)
        .accessibilityIdentifier("sidebar: \(p.rawValue)")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .dictations: DictationsPane(state: state, search: $search)
        case .insights: InsightsPane()
        case .meetings: MeetingView(controller: meetingController).background(Brand.bg)
        case .importFile: FileImportView(model: importModel).background(Brand.bg)
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .models: ModelsPane()
        case .ai: AISettingsView()
        case .apps: PerAppView()
        case .settings: SettingsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Snippets coach-mark

/// Shown once, under the Snippets sidebar row, after onboarding finishes. Snippets are invisible
/// until you open the tab, and nothing else in the app mentions them.
private struct SnippetTip: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text("Say “add my email” while dictating and your address pastes itself.")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.muted)
                .help("Dismiss")
            }
            Button("Show me", action: onOpen)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Brand.coral)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.coralSoft))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line))
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .transition(.opacity)
    }
}

// MARK: - Dictations pane (stats + date-grouped feed)

private struct DictationsPane: View {
    @ObservedObject var state: AppState
    @Binding var search: String
    @State private var entries: [HistoryEntry] = []
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.s16) {
            if let err = state.modelError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech model didn't load").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.text)
                        Text(err).font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(2)
                    }
                    Spacer()
                    Button("Reload") { NotificationCenter.default.post(name: .whisprReloadModel, object: nil) }
                        .buttonStyle(.borderedProminent).tint(Brand.coral)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.coralSoft))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.coral.opacity(0.4)))
            }
            statsRow
            HStack(spacing: Brand.s8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).font(Brand.body)
                TextField("Search transcripts", text: $search).textFieldStyle(.plain).font(Brand.body)
            }
            .padding(Brand.s8)
            .background(RoundedRectangle(cornerRadius: Brand.rSm + 2).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.rSm + 2).stroke(Brand.line))
            HStack(spacing: Brand.s8) {
                Text("Hold \(AppController.hotkeyHint) anywhere, speak, release. Your words paste at the cursor.")
                    .font(Brand.caption).foregroundStyle(Brand.muted)
                Spacer()
                if !entries.isEmpty {
                    Text(entries.count >= HistoryStore.cap ? "Last \(HistoryStore.cap)" : "Last \(entries.count)")
                        .font(Brand.caption).foregroundStyle(Brand.muted)
                    Menu {
                        Button("Clear history…", role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Brand.muted)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More")
                }
            }
            feed
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refresh() }
        .onChange(of: state.status) { _, _ in refresh() }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { HistoryStore.clear(); refresh() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes every saved transcript. Your stats stay.") }
    }

    private func refresh() { entries = HistoryStore.load() }

    private var filtered: [HistoryEntry] {
        search.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private var statsRow: some View {
        let s = Stats.overview()
        return HStack(spacing: Brand.s12) {
            StatTile(value: "\(s.streakDays)", label: "day streak")
            StatTile(value: format(s.lifetimeWords), label: "words, all time")
            StatTile(value: "\(s.lifetimeDictations)", label: "dictations")
            StatTile(value: s.avgWPM > 0 ? "\(s.avgWPM)" : "—", label: "avg wpm")
            StatTile(value: "\(s.meetingsCount)", label: "meetings")
        }
        .frame(height: 78)
    }

    private func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                if filtered.isEmpty {
                    VStack(spacing: Brand.s4) {
                        Text(search.isEmpty ? "Nothing dictated yet. Tap \(AppController.hotkeyHint) and talk."
                                            : "No dictations match \u{2018}\(search)\u{2019}")
                            .font(Brand.title).foregroundStyle(Brand.text)
                        if search.isEmpty {
                            Text("Your transcripts show up here, newest first.")
                                .font(Brand.body).foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.top, Brand.s32).frame(maxWidth: .infinity)
                } else {
                    ForEach(groups, id: \.0) { title, items in
                        Text(title.uppercased())
                            .font(Brand.caption).foregroundStyle(Brand.muted)
                            .padding(.top, Brand.s8)
                        ForEach(items) { e in row(e) }
                    }
                }
            }
        }
    }

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let title = cal.isDateInToday(day) ? "Today"
                      : cal.isDateInYesterday(day) ? "Yesterday"
                      : day.formatted(.dateTime.month(.wide).day())
            return (title, grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var hoverID: UUID?
    @State private var copiedID: UUID?
    @FocusState private var editFocused: Bool

    private func copy(_ e: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
        copiedID = e.id
        let id = e.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == id { copiedID = nil } }
    }

    private func row(_ e: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(e.date.formatted(.dateTime.hour().minute()))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Brand.muted)
                .padding(.top, 2)
            if editingID == e.id {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5)).foregroundStyle(Brand.text)
                    .focused($editFocused)
                    .onSubmit { commitEdit(e) }
                    .onChange(of: editFocused) { _, focused in
                        if !focused && editingID == e.id { commitEdit(e) } // click-away saves too
                    }
                    .onExitCommand { editingID = nil } // Esc cancels
                    .onAppear { editFocused = true }
            } else {
                Text(e.text).font(.system(size: 13.5)).foregroundStyle(Brand.text)
                    .onTapGesture(count: 2) { editingID = e.id; editText = e.text }
            }
            Spacer(minLength: 0)
            if e.raw != nil {
                if e.reverted == true {
                    Text("reverted").font(.system(size: 10)).foregroundStyle(Brand.muted)
                } else {
                    Text("cleaned").font(.system(size: 10, weight: .medium)).foregroundStyle(Brand.coral)
                    Button("Revert to raw") {
                        if let raw = e.raw {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(raw, forType: .string)
                        }
                        HistoryStore.revert(id: e.id)
                        refresh()
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Brand.muted)
                }
            }
            if editingID != e.id, hoverID == e.id || copiedID == e.id {
                Button(action: { copy(e) }) {
                    Image(systemName: copiedID == e.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copiedID == e.id ? Brand.coral : Brand.muted)
                .help(copiedID == e.id ? "Copied" : "Copy transcript")
                .padding(.top, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(editingID == e.id ? Brand.coral : Brand.line))
        .onHover { hoverID = $0 ? e.id : (hoverID == e.id ? nil : hoverID) }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.text, forType: .string)
            }
            Button("Correct…") { editingID = e.id; editText = e.text }
        }
    }

    /// Save the edit; spelling-level changes (not rephrases) offer the dictionary toast.
    private func commitEdit(_ e: HistoryEntry) {
        let edited = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        guard !edited.isEmpty, edited != e.text else { return }
        HistoryStore.update(id: e.id, text: edited)
        refresh()
        let pairs = CorrectionsWatcher.corrections(original: e.text, edited: edited)
        if !pairs.isEmpty { CorrectionToast.shared.show(pairs) }
    }
}

// MARK: - Models pane

private struct ModelsPane: View {
    @State private var model = ModelManager().selectedModel
    @AppStorage("language") private var language = "auto"
    @AppStorage("outputMode") private var outputMode = "original"

    var body: some View {
        Form {
            PSection("Whisper model") {
                Picker("Model", selection: $model) {
                    ForEach(ModelManager.available, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, new in
                    NotificationCenter.default.post(name: .whisprModelChanged, object: new)
                }
                Text("Switching downloads the model if needed, then reloads. Turbo = best accuracy; tiny/base = fastest.")
                    .font(Brand.caption).foregroundStyle(Brand.muted)
                Text("large-v3 is the full model turbo was distilled from. It is slower and a bigger download; whether it transcribes your language better is worth testing rather than assuming.")
                    .font(Brand.caption).foregroundStyle(Brand.muted)
            }
            PSection("Language") {
                Picker("Spoken language", selection: $language) {
                    ForEach(Languages.list, id: \.code) { lang in Text(lang.name).tag(lang.code ?? "auto") }
                }
                Picker("Type as", selection: $outputMode) {
                    Text("Original script").tag("original")
                    Text("Roman letters (kaise ho)").tag("roman")
                    Text("English translation").tag("translate")
                }
                Text("Speak Hindi (or any language) and type it in Roman letters, or let Whisper translate to English. Applies to dictation and meetings. Note: English translation needs a non-turbo model — pick \"medium\" for the best Hindi→English quality; the turbo model transcribes only.")
                    .font(Brand.caption).foregroundStyle(Brand.muted)
            }
        }
        .paperForm()
    }
}

// MARK: - Settings pane (trigger/behavior/cleanup/appearance/permissions)

private struct SettingsPane: View {
    var body: some View {
        SettingsView()
            .scrollContentBackground(.hidden)
            .background(Brand.bg)
    }
}

// MARK: - About pane

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.circle.fill").font(.system(size: 56)).foregroundStyle(Brand.coral)
            Text("OpenWispr").font(Brand.serif(34)).foregroundStyle(Brand.text)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") — local voice dictation & meeting transcription")
                .foregroundStyle(Brand.muted)
            Text("100% on-device via WhisperKit · MIT licensed").font(Brand.caption).foregroundStyle(Brand.muted)
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://whispr-black-chi.vercel.app")!)
                Link("GitHub", destination: URL(string: "https://github.com/SirCharan/whispr")!)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window controller

@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show(state: AppState, meetingController: MeetingController, importModel: FileImportModel) {
        if window == nil {
            let view = HomeView(state: state, meetingController: meetingController, importModel: importModel)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "OpenWispr"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 960, height: 640))
            // follow the user: .moveToActiveSpace on normal Spaces, .fullScreenAuxiliary over a fullscreen app; didBecomeActive re-order below covers the Space switch macOS does on activation
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = win
            // macOS may switch Spaces when activation lands; re-order so .moveToActiveSpace pulls the window along
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let win = self?.window, win.isVisible else { return }
                    win.orderFrontRegardless()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100)) // let the window finish closing
                    DockPolicy.update()
                }
            }
        }
        // macOS 14+ cooperative activation: LSUIElement apps aren't activated by LaunchServices on open,
        // and the window must follow the user's Space.
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKey()
        NSApp.activate()
        DockPolicy.update() // Dock icon while a window is open
    }
}
