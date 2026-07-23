import SwiftUI

@MainActor
final class PerAppModel: ObservableObject {
    @Published var disabled: Set<String>
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
        VStack(spacing: 0) {
            HStack {
                Text("Turn dictation off in specific apps.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.refresh() }
            }.padding(12)
            Divider()
            List(model.apps, id: \.id) { app in
                Toggle(isOn: Binding(
                    get: { !model.disabled.contains(app.id) },
                    set: { model.setEnabled($0, id: app.id) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.id).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }
}
