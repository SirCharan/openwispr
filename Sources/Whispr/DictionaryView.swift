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
    func removeVocab(_ term: String) { data.vocab.removeAll { $0 == term } }
    func updateVocab(old: String, new: String) {
        let v = new.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != old, let i = data.vocab.firstIndex(of: old) else { return }
        if data.vocab.contains(v) { data.vocab.remove(at: i) } // edited into an existing term = merge
        else { data.vocab[i] = v }
    }
    func addReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        data.replacements.append(Replacement(from: f, to: to.trimmingCharacters(in: .whitespaces)))
    }
    func removeReplacement(id: UUID) { data.replacements.removeAll { $0.id == id } }
    func updateReplacement(id: UUID, from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, let i = data.replacements.firstIndex(where: { $0.id == id }) else { return }
        data.replacements[i].from = f
        data.replacements[i].to = to.trimmingCharacters(in: .whitespaces)
    }
}

/// Editor for the custom dictionary: fuzzy-matched vocabulary + exact replacements.
/// Rows edit inline (double-click or pencil; Return/blur commits, Esc cancels), delete via hover ✕.
struct DictionaryView: View {
    @StateObject private var model = DictionaryModel()
    @State private var newVocab = ""
    @State private var newFrom = ""
    @State private var newTo = ""
    // one row in edit mode at a time (shared across both sections)
    @State private var editingVocab: String?       // original term being edited
    @State private var editingReplacement: UUID?
    @State private var editText = ""
    @State private var editTo = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        Form {
            Section("Vocabulary — fuzzy-corrected toward these spellings") {
                HStack {
                    TextField("e.g. WhisperKit, Kubernetes", text: $newVocab)
                        .onSubmit { model.addVocab(newVocab); newVocab = "" }
                    Button("Add") { model.addVocab(newVocab); newVocab = "" }
                }
                if model.data.vocab.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary).font(.caption)
                } else {
                    List {
                        ForEach(model.data.vocab, id: \.self) { term in vocabRow(term) }
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
                        ForEach(model.data.replacements) { r in replacementRow(r) }
                    }.frame(minHeight: 80)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: rows

    @ViewBuilder
    private func vocabRow(_ term: String) -> some View {
        if editingVocab == term {
            TextField("", text: $editText)
                .textFieldStyle(.roundedBorder)
                .focused($editFocused)
                .onSubmit { commitVocab(term) }
                .onExitCommand { editingVocab = nil }
                .onChange(of: editFocused) { _, focused in
                    if !focused, editingVocab == term { commitVocab(term) }
                }
        } else {
            EditableRow(
                label: { Text(term) },
                edit: { beginVocabEdit(term) },
                delete: { model.removeVocab(term) }
            )
        }
    }

    @ViewBuilder
    private func replacementRow(_ r: Replacement) -> some View {
        if editingReplacement == r.id {
            HStack {
                TextField("from", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .focused($editFocused)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("to", text: $editTo)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { commitReplacement(r.id) }
                    .keyboardShortcut(.defaultAction)
            }
            .onExitCommand { editingReplacement = nil }
        } else {
            EditableRow(
                label: { Text("\(r.from)  →  \(r.to)") },
                edit: { beginReplacementEdit(r) },
                delete: { model.removeReplacement(id: r.id) }
            )
        }
    }

    // MARK: edit lifecycle

    private func beginVocabEdit(_ term: String) {
        editingReplacement = nil
        editingVocab = term
        editText = term
        editFocused = true
    }
    private func commitVocab(_ original: String) {
        guard editingVocab == original else { return }
        model.updateVocab(old: original, new: editText)
        editingVocab = nil
    }
    private func beginReplacementEdit(_ r: Replacement) {
        editingVocab = nil
        editingReplacement = r.id
        editText = r.from
        editTo = r.to
        editFocused = true
    }
    private func commitReplacement(_ id: UUID) {
        guard editingReplacement == id else { return }
        model.updateReplacement(id: id, from: editText, to: editTo)
        editingReplacement = nil
    }
}

/// Display row with hover-visible pencil (edit) + ✕ (delete); double-click also edits.
private struct EditableRow<Label: View>: View {
    @ViewBuilder let label: () -> Label
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            label()
            Spacer()
            if hovering {
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Edit")
                Button(action: delete) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Delete")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { edit() }
        .contextMenu {
            Button("Edit") { edit() }
            Button("Delete", role: .destructive) { delete() }
        }
    }
}
