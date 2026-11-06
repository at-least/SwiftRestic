import Foundation
import Testing

@Suite("Plan skips")
struct PlanSkipsTests {
    @Test("the page lists what every plan leaves out first, then the switches that are on, in the editor's order")
    func listing() {
        var plan = BackupPlan()
        plan.skipsMachines = true
        #expect(PlanSkips.on(in: plan).map(\.title) == [
            PlanSkips.always, PlanSkips.developerFiles, PlanSkips.machines, PlanSkips.cloudFiles,
        ])
        plan.skipsDeveloperFiles = false
        plan.skipsMachines = false
        plan.excludeCloudFiles = false
        #expect(PlanSkips.on(in: plan).map(\.title) == [PlanSkips.always])
    }

    @Test("what every plan leaves out names its rules in the tooltip, one a line, and the cache tag")
    func alwaysHelp() {
        let lines = PlanSkips.alwaysHelp.components(separatedBy: "\n")
        #expect(lines.count == ExcludeRule.defaults.count + 1)
        #expect(lines.first == "\(ExcludeRule.defaults[0].pattern) — \(ExcludeRule.defaults[0].what)")
    }
}

@Suite("Exclude categories")
struct ExcludeCategoryTests {
    @Test("the two switches' groups are exactly the developer rules' categories, the defaults' never among them")
    func groupsMatchTheRules() {
        let groups = ExcludeCategory.rebuildableGroups + ExcludeCategory.machineGroups
        let developerCategories = Set((ExcludeRule.developer + ExcludeRule.developerMarkers).map(\.category))
        let defaultCategories = Set(ExcludeRule.defaults.map(\.category))
        #expect(Set(groups) == developerCategories)
        #expect(groups.count == developerCategories.count)
        #expect(defaultCategories.isDisjoint(with: groups))
    }

    @Test("what may be the only copy stays with the machines' switch: no rebuildable rule says what was inside is lost")
    func rebuildableRulesKeepNoOnlyCopy() {
        for rule in ExcludeRule.developer where ExcludeCategory.rebuildableGroups.contains(rule.category) {
            #expect(!rule.why.contains("what was inside"), "\(rule.pattern)")
        }
    }
}
