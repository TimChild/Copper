import SwiftUI

/// The passkeys Copper has made or brought in. Private key material never
/// leaves the keychain; this list only shows the labels needed to recognise it.
struct PasskeysSettings: View {
    @State private var rows: [PasskeyStore.Credential] = []

    var body: some View {
        // Settings' own lines (UX pass 2026-10-07): the empty state spans the
        // card like every other row, and Forget is a pill like every other
        // action, not a grey word.
        Card {
            if rows.isEmpty {
                Line("No passkeys yet", "When a site offers to make one, Copper keeps it here and Touch ID signs you in with it") {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(rows) { credential in
                    Line(credential.rpId, "\(credential.label) · \(detail(credential))") {
                        Pill("Forget") { forget(credential) }
                            .accessibilityLabel("Forget the passkey for \(credential.rpId)")
                    }
                    if credential.id != rows.last?.id { Rule() }
                }
            }
        }
        .onAppear { reload() }
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
