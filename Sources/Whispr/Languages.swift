import Foundation

/// Curated language list for the picker. `code == nil` means auto-detect.
/// Requires a multilingual model (large-v3-turbo default, or small/base/tiny — not the .en variants).
enum Languages {
    static let list: [(name: String, code: String?)] = [
        ("Auto-detect", nil),
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"), ("Russian", "ru"),
        ("Hindi", "hi"), ("Chinese", "zh"), ("Japanese", "ja"), ("Korean", "ko"), ("Arabic", "ar"),
    ]

    static func name(for code: String) -> String {
        list.first { ($0.code ?? "auto") == code }?.name ?? "Auto-detect"
    }
}
