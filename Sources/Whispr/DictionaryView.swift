import SwiftUI

@MainActor
final class DictionaryModel: ObservableObject {
    @Published var data: DictionaryData { didSet { DictionaryStore.save(data) } }
    init() { data = DictionaryStore.load() }

    /// Returns false when nothing was added, so the caller can say why instead of
    /// clearing the field and looking broken.
    @discardableResult
    func addVocab(_ term: String) -> Bool {
        let v = term.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        // case-insensitive: "Notes" and "notes" are the same entry to the matcher
        guard !data.vocab.contains(where: { $0.lowercased() == v.lowercased() }) else { return false }
        data.vocab.append(v)
        return true
    }
    func removeVocab(_ term: String) { data.vocab.removeAll { $0 == term } }
    func updateVocab(old: String, new: String) {
        let v = new.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != old, let i = data.vocab.firstIndex(of: old) else { return }
        if data.vocab.contains(v) { data.vocab.remove(at: i) } // edited into an existing term = merge
        else { data.vocab[i] = v }
    }
    @discardableResult
    func addReplacement(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return false }
        guard !data.replacements.contains(where: { $0.from.lowercased() == f.lowercased() }) else { return false }
        data.replacements.append(Replacement(from: f, to: to.trimmingCharacters(in: .whitespaces)))
        return true
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
    @State private var vocabNote: String?        // "Already in the list" etc.
    @State private var replacementNote: String?
    @State private var staged: [String] = []     // terms queued by the correction toast
    @State private var fromToast = false         // the field currently holds a toast suggestion

    private let stagedPrompt = "Suggested from your edit — press Add to keep it."
    private var vocabTrimmed: String { newVocab.trimmingCharacters(in: .whitespaces) }
    private var fromTrimmed: String { newFrom.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section("Vocabulary — fuzzy-corrected toward these spellings") {
                HStack {
                    TextField("e.g. WhisperKit, Kubernetes", text: $newVocab)
                        .onSubmit { commitNewVocab() }
                    Button("Add") { commitNewVocab() }
                        .disabled(vocabTrimmed.isEmpty)
                }
                if let vocabNote {
                    Text(vocabNote).foregroundStyle(.secondary).font(.caption)
                }
                if model.data.vocab.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary).font(.caption)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(model.data.vocab, id: \.self) { term in vocabRow(term).id(term) }
                        }
                        .frame(minHeight: 160)
                        .onChange(of: model.data.vocab) { _, list in
                            if let last = list.last { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            Section("Replacements — exact phrase → text") {
                HStack {
                    TextField("from", text: $newFrom)
                        .onSubmit { commitNewReplacement() }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("to", text: $newTo)
                        .onSubmit { commitNewReplacement() }
                    Button("Add") { commitNewReplacement() }
                        .disabled(fromTrimmed.isEmpty)
                }
                if let replacementNote {
                    Text(replacementNote).foregroundStyle(.secondary).font(.caption)
                }
                if !model.data.replacements.isEmpty {
                    List {
                        ForEach(model.data.replacements) { r in replacementRow(r) }
                    }.frame(minHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .whisprStageVocab)) { note in
            let terms = (note.userInfo?["terms"] as? [String]) ?? []
            guard !terms.isEmpty else { return }
            newVocab = terms[0]
            staged = Array(terms.dropFirst())
            fromToast = true
            vocabNote = stagedPrompt
        }
    }

    // MARK: - Adding

    private func commitNewVocab() {
        guard !vocabTrimmed.isEmpty else { return }
        if model.addVocab(newVocab) {
            if fromToast { Stats.noteFixAccepted(1) }   // Insights: "fixes you taught it"
            if staged.isEmpty {
                newVocab = ""; vocabNote = nil; fromToast = false
            } else {
                newVocab = staged.removeFirst()
                vocabNote = stagedPrompt
            }
        } else {
            vocabNote = "\"\(vocabTrimmed)\" is already in the list."   // keep the text so it can be edited
        }
    }

    private func commitNewReplacement() {
        guard !fromTrimmed.isEmpty else { return }
        if model.addReplacement(from: newFrom, to: newTo) {
            newFrom = ""; newTo = ""; replacementNote = nil
        } else {
            replacementNote = "\"\(fromTrimmed)\" already has a replacement."
        }
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
                label: {
                    HStack(spacing: 6) {
                        Text(term)
                        if DictionaryStore.defaultIsRealWord(term), term == term.lowercased() {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .help("Common English word — it can capture similar words in your dictations. Consider removing it.")
                        }
                    }
                },
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
            }
            // Delete stays visible: hidden until hover, it reads as a missing feature.
            Button(action: delete) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Delete")
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
