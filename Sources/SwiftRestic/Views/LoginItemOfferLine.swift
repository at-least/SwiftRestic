import SwiftUI

/// The start-at-login caveat and its one step, as the Overview's Next runs
/// card and the plan editor's footer show it — one view, so the two say
/// the same words beside the same button. The rules for when it shows are
/// `LoginItemAdvice`'s; this reads only model state, never the daemon.
struct LoginItemOfferLine: View {
    @Environment(AppModel.self) private var model
    let offer: LoginItemAdvice.Offer
    /// Runs after a Start at Login click has gone to the model — the
    /// editor's cue to confirm the click in the offer's place.
    var onStartAtLogin: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LoginItemAdvice.caption(for: offer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch offer {
            case .startAtLogin:
                // "Start", not macOS's "Open at Login": the Settings switch
                // it turns on reads "Start SwiftRestic at login".
                Button("Start at Login") {
                    model.requestStartsAtLogin(true)
                    onStartAtLogin()
                }
                .controlSize(.small)
                .accessibilityLabel("Start SwiftRestic at login")
            case .awaitingApproval:
                Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    .controlSize(.small)
            case .moveToApplications:
                // Nothing to click: registering from here is refused, and
                // the caption says where the app has to be.
                EmptyView()
            }
        }
    }
}
