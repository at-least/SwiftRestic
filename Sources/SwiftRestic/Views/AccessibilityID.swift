/// The identifiers the UI tests find elements by. The UI test target compiles
/// this file too (project.yml), so a renamed identifier fails its build.
enum AccessibilityID {
    enum Welcome {
        static let backUpAFolder = "welcome.backUpAFolder"
    }

    enum FirstBackup {
        static let chooseSource = "firstBackup.chooseSource"
        static let disk = "firstBackup.disk"
        static let password = "firstBackup.password"
        static let confirmPassword = "firstBackup.confirmPassword"
        static let requirement = "firstBackup.requirement"
        static let backUp = "firstBackup.backUp"
    }

    enum Plan {
        static let total = "plan.total"
    }
}
