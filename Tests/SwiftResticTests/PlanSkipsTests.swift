import Foundation
import Testing

@Suite("Plan skips")
struct PlanSkipsTests {
    /// A new plan's defaults, plus the one switch that ships off
    /// (`oneFileSystem`), so every skip is on.
    private func fullySkippingPlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.oneFileSystem = true
        return plan
    }

    @Test("a plan with every skip on lists seven switches in the editor's order")
    func everySkipOn() {
        let items = PlanSkips.on(in: fullySkippingPlan())
        #expect(items.map(\.title) == [
            PlanSkips.finderFiles,
            PlanSkips.systemFiles,
            PlanSkips.caches,
            PlanSkips.developerFiles,
            PlanSkips.cloudFiles,
            PlanSkips.timeMachineExclusions,
            PlanSkips.otherDisks,
        ])
    }

    @Test("each switch's help: the defaults' rules for the two defaults switches, each caption's own line, none where the title says it")
    func helps() {
        let plan = fullySkippingPlan()
        let expected: [(title: String, help: String?)] = [
            (PlanSkips.finderFiles, PlanSkips.rulesHelp(ExcludeCategory.finderFiles)),
            (PlanSkips.systemFiles, PlanSkips.rulesHelp(ExcludeCategory.systemFiles)),
            (PlanSkips.caches, PlanSkips.cachesHelp),
            (PlanSkips.developerFiles, ExcludeCategory.developerGroups.map(\.title).joined(separator: "\n")),
            (PlanSkips.cloudFiles, "Files kept only in iCloud Drive or OneDrive"),
            (PlanSkips.timeMachineExclusions, PlanSkips.timeMachineExclusionsCaption),
            (PlanSkips.otherDisks, nil),
        ]
        let items = PlanSkips.on(in: plan)
        #expect(items.count == expected.count)
        for (item, want) in zip(items, expected) {
            #expect(item.title == want.title)
            #expect(item.help == want.help)
        }
    }

    @Test("Developer files: every group's help when all are ticked, a partial set named in the title with no help")
    func developerFiles() {
        var plan = fullySkippingPlan()

        let all = PlanSkips.on(in: plan).first { $0.title == PlanSkips.developerFiles }
        #expect(all?.help == ExcludeCategory.developerGroups.map(\.title).joined(separator: "\n"))

        let partial: [ExcludeCategory] = [.python, .rust]
        plan.developerGroups = partial
        let item = PlanSkips.on(in: plan).first { $0.title.hasPrefix(PlanSkips.developerFiles) }
        #expect(item?.title == "\(PlanSkips.developerFiles): \(Format.list(partial.map(\.title)))")
        #expect(item?.help == nil)
    }

    @Test("a plan with every skip off lists nothing")
    func noSkips() {
        var plan = BackupPlan()
        plan.skipsFinderFiles = false
        plan.skipsSystemFiles = false
        plan.excludeCaches = false
        plan.developerGroups = []
        plan.excludeCloudFiles = false
        plan.skipsTimeMachineExclusions = false
        plan.oneFileSystem = false
        #expect(PlanSkips.on(in: plan).isEmpty)
    }

    @Test("a defaults switch's help lists its rules, one a line, each its pattern and what it leaves out")
    func rulesHelp() {
        // Non-empty: the derivation below must not pass vacuously on empty
        // defaults.
        #expect(!PlanSkips.rulesHelp(ExcludeCategory.finderFiles).isEmpty)
        for categories in [ExcludeCategory.finderFiles, ExcludeCategory.systemFiles] {
            #expect(PlanSkips.rulesHelp(categories) == ExcludeRule.defaults
                .filter { categories.contains($0.category) }
                .map { "\($0.pattern) — \($0.what)" }
                .joined(separator: "\n"))
        }
    }
}
