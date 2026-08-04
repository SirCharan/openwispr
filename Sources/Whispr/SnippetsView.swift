import SwiftUI

@MainActor
final class SnippetsModel: ObservableObject {
    @Published var items: [Snippet] { didSet { SnippetStore.save(items) } }
    init() { items = SnippetStore.load() }

    func add(triggers: String, expansion: String) {
        let list = Self.parse(triggers)
        guard !list.isEmpty else { return }
        items.append(Snippet(triggers: list, to: expansion))
    }

    func remove(_ offsets: IndexSet) { items.remove(atOffsets: offsets) }

    /// Adds the starter rows that are not already present. Their expansions are empty until
    /// the user fills them in, and an empty expansion never fires.
    func addPresets() { items.append(contentsOf: SnippetStore.missingPresets(from: items)) }

    var hasAllPresets: Bool { SnippetStore.missingPresets(from: items).isEmpty }

    /// Triggers are edited as one comma-separated field: "add my email, add my e-mail".
    static func parse(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func join(_ triggers: [String]) -> String { triggers.joined(separator: ", ") }
}

/// Editor for voice snippets: say a trigger phrase, get the expansion pasted.
struct SnippetsView: View {
    @StateObject private var model = SnippetsModel()
    @State private var triggers = ""
    @State private var expansion = ""

    var body: some View {
        Form {
            Section("New snippet") {
                TextField("Trigger phrases, comma separated", text: $triggers,
                          prompt: Text("add my email, add my e-mail"))
                    .help("Comma-separated. Every phrase here expands to the same text, so add the ways you actually say it.")
                TextField("Expands to…", text: $expansion, axis: .vertical).lineLimit(1...4)
                    .help("Pasted exactly as typed, even with an AI rewrite style on. Leave it empty and this snippet stays off.")
                Button("Add snippet") {
                    model.add(triggers: triggers, expansion: expansion)
                    triggers = ""
                    expansion = ""
                }
                .disabled(SnippetsModel.parse(triggers).isEmpty)
                Text("Use a phrase, not a bare word: \"add my email\" expands, while \"email\" on its own would fire in every sentence that mentions one.")
                    .foregroundStyle(.secondary).font(.caption)
            }
            Section("Snippets") {
                Button("Add my details") { model.addPresets() }
                    .disabled(model.hasAllPresets)
                    .help("Adds starter rows for email, LinkedIn, X, GitHub, phone and signature. Fill in the ones you want.")
                if model.items.isEmpty {
                    Text("No snippets yet. Say a trigger while dictating and it expands.")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    List {
                        ForEach($model.items) { $item in
                            SnippetRow(item: $item)
                        }
                        .onDelete { model.remove($0) }
                    }.frame(minHeight: 160)
                }
                Text("Where two triggers overlap, the longer phrase wins, so the order of this list does not matter. A snippet with no expansion is ignored.")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

/// One editable row. Triggers round-trip through a comma-separated field, so the binding is
/// held locally and written back on every edit.
private struct SnippetRow: View {
    @Binding var item: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Trigger phrases, comma separated", text: Binding(
                get: { SnippetsModel.join(item.triggers) },
                set: { item.triggers = SnippetsModel.parse($0) }
            ))
            .font(.body.bold())
            .help("Comma-separated. Every phrase here expands to the same text.")
            TextField("Expands to…", text: $item.to, axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(item.to.isEmpty ? .secondary : .primary)
                .help(item.to.isEmpty
                      ? "Empty, so this snippet is off. Type what the phrase should paste."
                      : "Pasted exactly as typed, even with an AI rewrite style on.")
        }
        .padding(.vertical, 2)
    }
}
