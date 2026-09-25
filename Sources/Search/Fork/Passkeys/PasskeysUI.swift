import SwiftUI

/// The passkeys Copper has made or brought in. Private key material never
/// leaves the keychain; this list only shows the labels needed to recognise it.
struct PasskeysSettings: View {
    @State private var rows: [PasskeyStore.Credential] = []

    var body: some View {
        Card {
            if rows.isEmpty {
                Text("No Copper passkeys yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(rows) { credential in
                    row(credential)
                    if credential.id != rows.last?.id { Rule() }
                }
            }
        }
        .onAppear { reload() }
    }

    @ViewBuilder private func row(_ credential: PasskeyStore.Credential) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.rpId)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(credential.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Forget") { forget(credential) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            Text(detail(credential))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func detail(_ credential: PasskeyStore.Credential) -> String {
        let created = credential.created.formatted(.dateTime.year().month(.abbreviated).day())
        let used = credential.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "never used"
        return "\(credential.origin ?? "Copper") · created \(created) · last used \(used)"
    }

    private func reload() { rows = PasskeyStore.all() }

    private func forget(_ credential: PasskeyStore.Credential) {
        Vault.prove("Forget the passkey for \(credential.rpId)") { ok in
            guard ok else { return }
            PasskeyStore.forget(id: credential.id)
            reload()
        }
    }
}
