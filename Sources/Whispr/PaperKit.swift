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

/// Number plus label. Fills its row height so tiles in a row stay equal.
struct StatTile: View {
    let value: String
    let label: String
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Brand.s4) {
            Text(value).font(Brand.serif(26)).monospacedDigit().foregroundStyle(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(Brand.body).foregroundStyle(Brand.text)
            Text(hint ?? " ").font(Brand.caption).foregroundStyle(Brand.muted).lineLimit(2)
                .opacity(hint == nil ? 0 : 1)
            Spacer(minLength: 0)
        }
        .padding(Brand.s12)
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
            Text(title).font(.system(size: 13, weight: .medium))
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
