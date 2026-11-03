import SwiftUI

/// Surface with a 1 px line border.
struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Brand.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.rMd))
            .overlay(RoundedRectangle(cornerRadius: Brand.rMd).strokeBorder(Brand.line, lineWidth: 1))
    }
}

/// Shared floating-panel chrome: pill, idle widget, toast and prompt.
extension View {
    func panelStyle() -> some View {
        background(
            RoundedRectangle(cornerRadius: Brand.rLg).fill(Brand.surface)
                .overlay(RoundedRectangle(cornerRadius: Brand.rLg).strokeBorder(Brand.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
    }
}

/// Serif heading above a card.
struct PaperSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Brand.s8) {
            Text(title).font(Brand.title).foregroundStyle(Brand.text)
            PaperCard { content }
        }
    }
}

/// Number plus label (and optional hint), tight. Rows should use `.fixedSize(horizontal: false, vertical: true)` so tiles share the tallest height.
struct StatTile: View {
    let value: String
    let label: String
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Brand.serif(26)).monospacedDigit().foregroundStyle(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(Brand.body).foregroundStyle(Brand.text)
            if let hint { Text(hint).font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(2) }
        }
        .padding(.horizontal, Brand.s12).padding(.vertical, Brand.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.rMd))
        .overlay(RoundedRectangle(cornerRadius: Brand.rMd).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

enum PaperButtonRole { case primary, secondary, destructive }

struct PaperButton: View {
    let title: String
    var role: PaperButtonRole = .secondary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(fg)
                .padding(.vertical, 7).padding(.horizontal, Brand.s16)
                .background(role == .primary ? Brand.coral : .clear, in: RoundedRectangle(cornerRadius: Brand.rSm))
                .overlay(RoundedRectangle(cornerRadius: Brand.rSm)
                    .strokeBorder(role == .primary ? .clear : Brand.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Brand.rSm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
    private var fg: Color {
        switch role {
        case .primary: Brand.onAccent
        case .secondary: Brand.text
        case .destructive: Brand.danger
        }
    }
}

/// Form section on Paper Studio: serif heading, surface rows.
struct PSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        Section {
            Group { content }.listRowBackground(Brand.surface)
        } header: {
            Text(title).font(Brand.title).foregroundStyle(Brand.text).textCase(nil)
        }
    }
}

extension View {
    /// Grouped form with no system grey/white surfaces.
    func paperForm() -> some View {
        self.formStyle(.grouped).scrollContentBackground(.hidden).background(Brand.bg)
    }
}
