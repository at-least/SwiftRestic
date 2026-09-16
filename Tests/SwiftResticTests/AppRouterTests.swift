import Foundation
import Testing

/// The router's intent slot: one ask at a time, cleared the moment it is
/// seen, replaced while unconsumed. These rules are what let a menu command
/// fired while the window is closed survive until the window exists — the
/// property the old `pendingNewRepository` flag had and the notification
/// seam lacked.
@MainActor
@Suite("app router")
struct AppRouterTests {
    @Test("request parks an intent; taking it returns and clears it")
    func requestAndTake() {
        let router = AppRouter()
        router.request(.newRepository)
        #expect(router.pendingIntent == .newRepository)
        #expect(router.takePendingIntent() == .newRepository)
        #expect(router.pendingIntent == nil)
        #expect(router.takePendingIntent() == nil)
    }

    @Test("a second unconsumed ask replaces the first")
    func lastAskWins() {
        let router = AppRouter()
        router.request(.newPlan)
        router.request(.showFind)
        #expect(router.takePendingIntent() == .showFind)
    }
}
