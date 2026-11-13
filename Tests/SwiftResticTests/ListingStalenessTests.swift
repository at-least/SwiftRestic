import Foundation
import Testing

@Suite("Listings re-read on activation")
struct ListingStalenessTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A read listing is re-read once it is older than the threshold, and not before")
    func readListingAgesOut() {
        let fresh = now.addingTimeInterval(-AppModel.listingStaleAfter + 1)
        let old = now.addingTimeInterval(-AppModel.listingStaleAfter)
        #expect(!AppModel.isListingStale(outcome: .loaded, loadedAt: fresh, isLoading: false, now: now))
        #expect(AppModel.isListingStale(outcome: .loaded, loadedAt: old, isLoading: false, now: now))
    }

    @Test("A listing being read, a failed one and one never read are left alone")
    func onlyIdleReadListings() {
        let old = now.addingTimeInterval(-AppModel.listingStaleAfter * 10)
        #expect(!AppModel.isListingStale(outcome: .loaded, loadedAt: old, isLoading: true, now: now))
        #expect(!AppModel.isListingStale(outcome: .failed("Not connected."), loadedAt: old, isLoading: false, now: now))
        #expect(!AppModel.isListingStale(outcome: .idle, loadedAt: nil, isLoading: false, now: now))
        #expect(!AppModel.isListingStale(outcome: nil, loadedAt: nil, isLoading: false, now: now))
    }
}
