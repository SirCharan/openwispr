import SwiftUI

@MainActor
final class PerAppModel: ObservableObject {
    @Published var disabled: Set<String>
    @Published var rules = AppFormatting.rules
    func setRule(_ r: AppFormatting, id: String) { rules[id] = r; AppFormatting.rules = rules }
    @Published var apps: [(name: String, id: String)] = []
    init() {
        disabled = Set(Settings.disabledApps)
        refresh()
    }
    func refresh() { apps = AppMonitor.regularApps() }
    func setEnabled(_ enabled: Bool, id: String) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        Settings.disabledApps = Array(disabled)
    }
}

/// Per-app enable/disable: turn dictation off in specific apps.
struct PerAppView: View {
    @StateObject private var model = PerAppModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.s16) {
                HStack {
                    Text("Turn dictation off in specific apps.").font(Brand.body).foregroundStyle(Brand.muted)
                    Spacer()
                    PaperButton(title: "Refresh", role: .secondary) { model.refresh() }
                }
                PaperSection(title: "Running apps") {
                    if model.apps.isEmpty {
                        Text("No apps found. Open an app and refresh.").font(Brand.body).foregroundStyle(Brand.muted)
                    } else {
                        VStack(alignment: .leading, spacing: Brand.s12) {
                            ForEach(model.apps, id: \.id) { app in
                                HStack(alignment: .top) {
                                Toggle(isOn: Binding(
                                    get: { !model.disabled.contains(app.id) },
                                    set: { model.setEnabled($0, id: app.id) }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name).font(Brand.body).foregroundStyle(Brand.text)
                                        Text(app.id).font(Brand.caption).foregroundStyle(Brand.muted)
                                    }
                                }
                                Spacer()
                                FormattingMenu(rule: model.rules[app.id] ?? .unchanged) { model.setRule($0, id: app.id) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Brand.s24)
        }
        .background(Brand.bg)
        .onAppear { model.refresh() }
    }
}


/// Output rules for one app: lowercase-chat preset plus the two switches.
private struct FormattingMenu: View {
    let rule: AppFormatting
    let set: (AppFormatting) -> Void
    var body: some View {
        Menu {
            Button("Original") { set(.unchanged) }
            Button("Lowercase chat") { set(.lowercaseChat) }
            Divider()
            Toggle("Lowercase first letter", isOn: Binding(
                get: { rule.capitalization == .lowercaseFirst },
                set: { var r = rule; r.capitalization = $0 ? .lowercaseFirst : .keep; set(r) }))
            Toggle("Drop final period", isOn: Binding(
                get: { rule.finalPeriod == .drop },
                set: { var r = rule; r.finalPeriod = $0 ? .drop : .keep; set(r) }))
        } label: {
            Text(rule == .unchanged ? "Format: original" : rule == .lowercaseChat ? "Format: lowercase chat" : "Format: custom")
                .font(Brand.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
