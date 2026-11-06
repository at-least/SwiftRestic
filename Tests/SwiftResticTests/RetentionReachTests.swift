import Foundation
import Testing

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

    @Test("choosing a window turns the rules on; Keep everything turns them off and keeps the buckets")
    func enabledFollowsTheChoice() {
        var policy = RetentionPolicy()
        policy.keepHourly = 3
        RetentionPolicy.Reach.keepEverything.apply(to: &policy)
        #expect(!policy.isEnabled)
        #expect(policy.keepHourly == 3, "turning rules off must not lower a saved rule")
        #expect(RetentionPolicy.Reach(policy: policy) == .keepEverything)
        #expect(!policy.isSafeToRun)

        RetentionPolicy.Reach.month.apply(to: &policy)
        #expect(policy.isEnabled)
        #expect(policy.keepDaily == 30)
        #expect(policy.isSafeToRun)
    }

    @Test("hand-edited rules decode as they were, above any range the picker offers")
    func customSurvivesDecoding() throws {
        let policy = try JSONDecoder().decode(RetentionPolicy.self, from: Data(#"{"keepDaily": 1000, "keepYearly": 500, "runPrune": true}"#.utf8))
        #expect(policy.keepDaily == 1000 && policy.keepYearly == 500)
        #expect(RetentionPolicy.Reach(policy: policy) == .custom)
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
