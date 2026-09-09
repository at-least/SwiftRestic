import Foundation
import Testing

/// The reach question and the bucket machinery, pinned at the model: picking
/// a window must write exactly the window its name promises, hand-edited
/// rules must read back as Custom, and the toggles the answer does not name
/// must survive every rewrite.
@Suite("Retention reach presets")
struct RetentionReachTests {
    @Test("the default policy reads as the standard buckets")
    func standardRoundTrip() {
        let policy = RetentionPolicy()
        #expect(RetentionPolicy.Reach(policy: policy) == .standard)

        var rewritten = policy
        RetentionPolicy.Reach.standard.apply(to: &rewritten)
        #expect(rewritten.keepHourly == 24 && rewritten.keepDaily == 7)
        #expect(rewritten.keepWeekly == 4 && rewritten.keepMonthly == 12 && rewritten.keepYearly == 3)
        #expect(RetentionPolicy.Reach(policy: rewritten) == .standard)
    }

    @Test("each window writes exactly its name — no leftover buckets")
    func windowsAreExact() {
        for (reach, daily) in [(RetentionPolicy.Reach.month, 30), (.quarter, 90), (.year, 365)] {
            var policy = RetentionPolicy()
            reach.apply(to: &policy)
            #expect(policy.keepHourly == 0, "\(reach) must zero the hourly bucket")
            #expect(policy.keepDaily == daily)
            #expect(policy.keepWeekly == 0 && policy.keepMonthly == 0 && policy.keepYearly == 0)
            // The rewrite must land the policy back on the choice that wrote
            // it — the picker may never silently disagree with the buckets.
            #expect(RetentionPolicy.Reach(policy: policy) == reach)
        }
    }

    @Test("hand-edited rules read as Custom, and Custom changes nothing")
    func customIsDerivedAndInert() {
        var policy = RetentionPolicy()
        policy.keepHourly = 3
        #expect(RetentionPolicy.Reach(policy: policy) == .custom)

        let before = policy
        RetentionPolicy.Reach.custom.apply(to: &policy)
        #expect(policy == before)
    }

    @Test("prune and the enabled toggle survive every rewrite")
    func togglesSurvive() {
        var policy = RetentionPolicy()
        policy.runPrune = true
        policy.isEnabled = true
        RetentionPolicy.Reach.year.apply(to: &policy)
        #expect(policy.runPrune, "choosing a window must not silently turn pruning off")
        #expect(policy.isEnabled)

        policy.isEnabled = false
        RetentionPolicy.Reach.month.apply(to: &policy)
        #expect(policy.isEnabled == false)
    }

    @Test("a preset chosen while disabled still lands when re-enabled")
    func presetsDoNotDependOnEnabled() {
        var policy = RetentionPolicy()
        policy.isEnabled = false
        RetentionPolicy.Reach.quarter.apply(to: &policy)
        #expect(policy.keepDaily == 90)
        #expect(policy.isSafeToRun == false, "a disabled policy must still read unsafe to run")
        policy.isEnabled = true
        #expect(policy.isSafeToRun)
    }
}

extension RetentionReachTests {
    @Test("choosing a preset from a hand-edited policy zeroes what the hand set")
    func presetOverHandEdit() {
        var policy = RetentionPolicy()
        policy.keepLast = 5
        policy.keepWeekly = 8
        RetentionPolicy.Reach.month.apply(to: &policy)
        #expect(policy.keepLast == 0, "the window's promise includes zeroing keep-last")
        #expect(policy.keepWeekly == 0)
        #expect(policy.keepDaily == 30)
        #expect(RetentionPolicy.Reach(policy: policy) == .month)
    }
}
