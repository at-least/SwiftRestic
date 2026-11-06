import SwiftUI

/// The start-at-login step only the user can take, as the plan editor shows
/// it. The rules for when it shows are `LoginItemAdvice`'s; this reads only
/// model state, never the daemon.
struct LoginItemOfferLine: View {
    let offer: LoginItemAdvice.Offer

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LoginItemAdvice.caption(for: offer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if offer == .awaitingApproval {
                Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    .controlSize(.small)
            }
        }
    }
}
