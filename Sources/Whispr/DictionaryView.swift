import SwiftUI

@MainActor
final class DictionaryModel: ObservableObject {
    @Published var data: DictionaryData { didSet { DictionaryStore.save(data) } }
    init() { data = DictionaryStore.load() }

    func addVocab(_ term: String) {
        let v = term.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !data.vocab.contains(v) else { return }
        data.vocab.append(v)
    }
    func removeVocab(_ offsets: IndexSet) { data.vocab.remove(atOffsets: offsets) }
    func addReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        data.replacements.append(Replacement(from: f, to: to.trimmingCharacters(in: .whitespaces)))
    }
    func removeReplacement(_ offsets: IndexSet) { data.replacements.remove(atOffsets: offsets) }
}

/// Editor for the custom dictionary: fuzzy-matched vocabulary + exact replacements.
struct DictionaryView: View {
    @StateObject private var model = DictionaryModel()
    @State private var newVocab = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section("Vocabulary — fuzzy-corrected toward these spellings") {
                HStack {
                    TextField("e.g. WhisperKit, Kubernetes", text: $newVocab)
                    Button("Add") { model.addVocab(newVocab); newVocab = "" }
                }
                if model.data.vocab.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary).font(.caption)
                } else {
                    List {
                        ForEach(model.data.vocab, id: \.self) { Text($0) }
                            .onDelete { model.removeVocab($0) }
                    }.frame(minHeight: 80)
                }
            }
            Section("Replacements — exact phrase → text") {
                HStack {
                    TextField("from", text: $newFrom)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("to", text: $newTo)
                    Button("Add") { model.addReplacement(from: newFrom, to: newTo); newFrom = ""; newTo = "" }
                }
                if !model.data.replacements.isEmpty {
                    List {
                        ForEach(model.data.replacements) { r in Text("\(r.from)  →  \(r.to)") }
                            .onDelete { model.removeReplacement($0) }
                    }.frame(minHeight: 80)
                }
            }
        }
        .formStyle(.grouped)
    }
}
