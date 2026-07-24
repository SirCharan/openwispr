import SwiftUI
import AppKit
import KeyboardShortcuts

/// Shared observable state the home window binds to.
@MainActor
final class AppState: ObservableObject {
    @Published var status = "starting…"
    @Published var isRecording = false
    @Published var pane: HomePane = .dictations
}

extension Notification.Name {
    static let whisprModelChanged = Notification.Name("whispr.modelChanged")
}

// Landing-page design tokens (web/index.html) translated to SwiftUI.
enum Brand {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)        // #0a0a0b
    static let surface = Color(red: 0.078, green: 0.078, blue: 0.086)   // #141416
    static let line = Color(red: 0.149, green: 0.149, blue: 0.165)      // #26262a
    static let text = Color(red: 0.949, green: 0.949, blue: 0.941)      // #f2f2f0
    static let muted = Color(red: 0.545, green: 0.545, blue: 0.569)     // #8b8b91
    static let coral = Color(red: 1.0, green: 0.365, blue: 0.329)       // #ff5d54
    static let coralSoft = coral.opacity(0.12)

    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
}

enum HomePane: String, CaseIterable, Identifiable {
    case dictations = "Dictations"
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
    private var pane: HomePane { state.pane }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Brand.line).frame(width: 1)
            detail
        }
        .background(Brand.bg)
        .preferredColorScheme(.dark) // the home window IS the brand surface
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("Whis").font(Brand.serif(24)) + Text("p").font(Brand.serif(24)).foregroundStyle(Brand.coral) + Text("r").font(Brand.serif(24))
            }
            .padding(.bottom, 2)
            Text("Hi, \(NSFullUserName().components(separatedBy: " ").first ?? NSFullUserName())")
                .font(.caption).foregroundStyle(Brand.muted)
                .padding(.bottom, 14)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).font(.system(size: 12))
                TextField("Search…", text: $search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line))
            .padding(.bottom, 14)

            ForEach(HomePane.allCases) { p in
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
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pane == p ? Brand.coralSoft : .clear))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(state.isRecording ? .red : (state.status.hasPrefix("ready") ? .green : Brand.muted))
                    .frame(width: 8, height: 8)
                Text(state.status).font(.caption2).foregroundStyle(Brand.muted).lineLimit(2)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 230)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .dictations: DictationsPane(state: state, search: $search)
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

// MARK: - Dictations pane (stats + date-grouped feed)

private struct DictationsPane: View {
    @ObservedObject var state: AppState
    @Binding var search: String
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statsRow
            HStack(spacing: 8) {
                Text("Hold").foregroundStyle(Brand.muted)
                Text(AppController.hotkeyHint).bold().foregroundStyle(Brand.coral)
                Text("anywhere · speak · release — your words paste at the cursor.").foregroundStyle(Brand.muted)
            }
            .font(.system(size: 13))
            feed
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refresh() }
        .onChange(of: state.status) { _, _ in refresh() }
    }

    private func refresh() { entries = HistoryStore.load() }

    private var filtered: [HistoryEntry] {
        search.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private var statsRow: some View {
        let s = Stats.summary(entries: entries)
        return HStack(spacing: 12) {
            statCard("flame.fill", "\(s.streakDays)", "day streak")
            statCard("textformat", format(s.totalWords), "words dictated")
            statCard("speedometer", s.avgWPM > 0 ? "\(s.avgWPM)" : "—", "avg WPM")
            statCard("person.2.fill", "\(s.meetings)", "meetings")
        }
    }

    private func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func statCard(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Brand.coral).font(.system(size: 15))
            Text(value).font(Brand.serif(26)).foregroundStyle(Brand.text)
            Text(label).font(.caption).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line))
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                if filtered.isEmpty {
                    Text(search.isEmpty ? "Nothing yet — hold \(AppController.hotkeyHint) and say something."
                                        : "No transcripts match “\(search)”.")
                        .font(.callout).foregroundStyle(Brand.muted).padding(.top, 30)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(groups, id: \.0) { title, items in
                        Text(title.uppercased())
                            .font(.caption.bold()).foregroundStyle(Brand.muted)
                            .padding(.top, 10)
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

    private func row(_ e: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(e.date.formatted(.dateTime.hour().minute()))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Brand.muted)
                .padding(.top, 2)
            Text(e.text).font(.system(size: 13.5)).foregroundStyle(Brand.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line))
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.text, forType: .string)
            }
        }
    }
}

// MARK: - Models pane

private struct ModelsPane: View {
    @State private var model = ModelManager().selectedModel
    @AppStorage("language") private var language = "auto"

    var body: some View {
        Form {
            Section("Whisper model") {
                Picker("Model", selection: $model) {
                    ForEach(ModelManager.available, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, new in
                    NotificationCenter.default.post(name: .whisprModelChanged, object: new)
                }
                Text("Switching downloads the model if needed, then reloads. Turbo = best accuracy; tiny/base = fastest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Spoken language", selection: $language) {
                    ForEach(Languages.list, id: \.code) { lang in Text(lang.name).tag(lang.code ?? "auto") }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg)
    }
}

// MARK: - Settings pane (trigger/behavior/cleanup/appearance/permissions)

private struct SettingsPane: View {
    var body: some View {
        SettingsView(currentModel: ModelManager().selectedModel, models: ModelManager.available,
                     onReloadModel: { NotificationCenter.default.post(name: .whisprModelChanged, object: $0) })
            .scrollContentBackground(.hidden)
            .background(Brand.bg)
    }
}

// MARK: - About pane

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.circle.fill").font(.system(size: 56)).foregroundStyle(Brand.coral)
            Text("Whispr").font(Brand.serif(34)).foregroundStyle(Brand.text)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") — local voice dictation & meeting transcription")
                .foregroundStyle(Brand.muted)
            Text("100% on-device via WhisperKit · MIT licensed").font(.caption).foregroundStyle(Brand.muted)
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
            win.title = "Whispr"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 960, height: 640))
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
