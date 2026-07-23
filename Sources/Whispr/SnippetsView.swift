import SwiftUI

@MainActor
final class SnippetsModel: ObservableObject {
    @Published var items: [Replacement] { didSet { SnippetStore.save(items) } }
    init() { items = SnippetStore.load() }

    func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        items.append(Replacement(from: t, to: expansion))
    }
    func remove(_ offsets: IndexSet) { items.remove(atOffsets: offsets) }
}

/// Editor for voice snippets: say the trigger, get the expansion pasted.
struct SnippetsView: View {
    @StateObject private var model = SnippetsModel()
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        Form {
            Section("New snippet") {
                TextField("Trigger phrase (e.g. my email)", text: $trigger)
                TextField("Expands to…", text: $expansion, axis: .vertical).lineLimit(1...4)
                Button("Add snippet") { model.add(trigger: trigger, expansion: expansion); trigger = ""; expansion = "" }
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Snippets") {
                if model.items.isEmpty {
                    Text("No snippets yet. Say the trigger while dictating and it expands.")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    List {
                        ForEach(model.items) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.from).bold()
                                Text(s.to).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .onDelete { model.remove($0) }
                    }.frame(minHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
    }
}
