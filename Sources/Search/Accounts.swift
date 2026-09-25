import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. It follows the box when the page
/// scrolls, and goes when the caret does.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every account, not a handful: six rows show, the rest scroll.
            ScrollView(showsIndicators: asked.credentials.count > 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(asked.credentials) { credential in
                        Row(credential: credential, fetching: browser.fetching == credential.id) {
                            browser.choose(credential)
                        }
                    }
                }
            }
            .frame(maxHeight: 6 * 44 + 22)
            .fixedSize(horizontal: false, vertical: asked.credentials.count <= 6)
            if isBitwardenLocked {
                Button {
                    browser.tuning = true
                    browser.managing = false
                    browser.dropChoice()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "shield")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(Palette.muted)
                        Text("Unlock Bitwarden…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text(asked.credentials.contains { $0.source == .bitwarden } || isBitwardenLocked
                     ? "From your keychain and Bitwarden"
                     : "From your keychain")
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private var isBitwardenLocked: Bool {
        if case .locked = Bitwarden.shared.state { return true }
        return false
    }

    private struct Row: View {
        let credential: Credential
        let fetching: Bool
        let pick: () -> Void
        @State private var hovering = false

        private var sourceSymbol: String {
            credential.source == .bitwarden ? "shield" : "key"
        }

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: sourceSymbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credential.user.isEmpty ? "No name" : credential.user)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(credential.host)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if fetching {
                        Ring(size: 10)
                        Text("Fetching…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fetching)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
