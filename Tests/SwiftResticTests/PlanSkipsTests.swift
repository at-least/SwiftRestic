import Foundation
import Testing

@Suite("Plan skips")
struct PlanSkipsTests {
    @Test("what every plan leaves out names its rules in the tooltip, one a line, then developer files, the cache tag and online-only files")
    func alwaysHelp() {
        let lines = PlanSkips.alwaysHelp.components(separatedBy: "\n")
        #expect(lines.count == ExcludeRule.defaults.count + 3)
        #expect(lines.last == "Files kept only in iCloud Drive or OneDrive")
        #expect(lines.first == "\(ExcludeRule.defaults[0].pattern) — \(ExcludeRule.defaults[0].what)")
        #expect(PlanSkips.always.contains("developer files"))
    }
}

@Suite("Exclude categories")
struct ExcludeCategoryTests {
    @Test("every plan passes the developer rules, and none of them is a simulator, container or virtual machine")
    func developerRulesAreAppliedAndKeepNoOnlyCopy() {
        let applied = Set(BackupPlan().excludesToPass)
        for rule in ExcludeRule.developer {
            #expect(applied.contains(rule.pattern), "\(rule.pattern)")
            #expect(!rule.why.contains("what was inside"), "\(rule.pattern)")
        }
        for machine in ["~/Library/Developer/CoreSimulator/Devices", "~/.android/avd", "~/.lima/*/disk", "~/.vagrant.d/boxes"] {
            #expect(!applied.contains(machine), "\(machine)")
        }
        #expect(BackupPlan.excludeMarkers == [".rustc_info.json", "project.assets.json"])
    }
}
