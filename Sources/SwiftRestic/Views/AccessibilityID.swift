/// The identifiers the UI tests find elements by. The UI test target compiles
/// this file too (project.yml), so a renamed identifier fails its build.
enum AccessibilityID {
    enum Welcome {
        static let backUpAFolder = "welcome.backUpAFolder"
    }

    enum FirstBackup {
        static let source = "firstBackup.source"
        static let changeSource = "firstBackup.changeSource"
        static let destination = "firstBackup.destination"
        static let password = "firstBackup.password"
        static let confirmPassword = "firstBackup.confirmPassword"
        static let requirement = "firstBackup.requirement"
        static let backUp = "firstBackup.backUp"
    }

    enum BackUpAFolderPanel {
        static let destination = "backUpAFolderPanel.destination"
    }

    enum Plan {
        static let total = "plan.total"
        static let backUpNow = "plan.backUpNow"
        static let edit = "plan.edit"
        static let frequency = "plan.frequency"
        static let nextBackup = "plan.nextBackup"
    }

    enum PlanEditor {
        static let save = "planEditor.save"
    }

    enum PathList {
        static let add = "pathList.add"
    }

    enum RestorePane {
        static let tree = "restorePane.tree"
        static let restore = "restorePane.restore"
    }

    enum FileVersions {
        static let list = "fileVersions.list"
    }

    enum FindFiles {
        static let results = "findFiles.results"
    }

    enum RepositoryEditor {
        static let chooseFolder = "repositoryEditor.chooseFolder"
        static let password = "repositoryEditor.password"
        static let confirmPassword = "repositoryEditor.confirmPassword"
        static let requirement = "repositoryEditor.requirement"
        static let save = "repositoryEditor.save"
    }

    enum PasswordPrompt {
        static let password = "passwordPrompt.password"
        static let failure = "passwordPrompt.failure"
        static let save = "passwordPrompt.save"
    }

    enum Repository {
        static let size = "repository.size"
    }

    enum Activity {
        static let table = "activity.table"
    }

    enum RestoreSheet {
        static let chooseFolder = "restoreSheet.chooseFolder"
        static let restore = "restoreSheet.restore"
    }
}
