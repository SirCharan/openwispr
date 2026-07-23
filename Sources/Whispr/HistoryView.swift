import SwiftUI
import AppKit

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    init() { refresh() }
    func refresh() { entries = HistoryStore.load() }
    func clear() { HistoryStore.clear(); refresh() }
}

/// Read-only list of recent transcripts with copy-to-clipboard.
struct HistoryView: View {
    @StateObject private var model = HistoryModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.entries.count) transcript\(model.entries.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Clear") { model.clear() }.disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if model.entries.isEmpty {
                Spacer()
                Text("No transcripts yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(3)
                        HStack {
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { model.refresh() }
    }
}
