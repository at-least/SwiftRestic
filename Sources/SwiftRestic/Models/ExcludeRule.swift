import Foundation

/// The kind of thing an exclude rule leaves out — the one layer the
/// plan page's Excluding card and the editor's lists group rules by, in
/// this order, the user's own last.
enum ExcludeCategory: Int, CaseIterable, Comparable, Sendable {
    case finder
    case appState
    case indexes
    case drives
    case startupDisk
    case javascript
    case python
    case apple
    case toolchains
    case buildTools
    case versionManagers
    case simulators
    case machines
    case yours

    var title: String {
        switch self {
        case .finder: "Finder & Trash"
        case .appState: "Apps’ caches & state"
        case .indexes: "Search indexes"
        case .drives: "Drives’ own bookkeeping"
        case .startupDisk: "Startup disk"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .apple: "Xcode & Swift"
        case .toolchains: "Toolchains & packages"
        case .buildTools: "Other build tools"
        case .versionManagers: "Version managers"
        case .simulators: "Simulators"
        case .machines: "Containers & virtual machines"
        case .yours: "Added by you"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One rule the app offers: a new plan's default, the developer switch's,
/// or the switch's marker — with what it leaves out and why that is safe,
/// the label every surface shows beside it.
struct ExcludeRule: Hashable, Sendable {
    /// What restic is passed: an `--exclude` pattern, or for a marker the
    /// file name `--exclude-if-present` takes.
    let pattern: String
    let category: ExcludeCategory
    /// What the rule leaves out, a short noun phrase.
    let what: String
    /// Who puts it back, or why nothing has to.
    let why: String
    var isMarker = false

    init(_ pattern: String, _ category: ExcludeCategory, _ what: String, _ why: String, isMarker: Bool = false) {
        self.pattern = pattern
        self.category = category
        self.what = what
        self.why = why
        self.isMarker = isMarker
    }

    /// The rule as a list shows it: the pattern, or the marker's folders.
    var line: String { isMarker ? "Folders holding \(pattern)" : pattern }

    var label: String { "\(what) · \(why)" }

    /// Noise the Finder, package managers and caches regenerate on their
    /// own. Nothing here may be the only copy of anything — a restored Git
    /// working copy without its object store is "not a git repository". A
    /// plan gets the ones that can match under its path
    /// (`BackupPlan.defaultExcludes(for:)`). The first six are the list
    /// builds before 2026-10-21 offered, unchanged and first.
    static let defaults: [ExcludeRule] = [
        ExcludeRule(".DS_Store", .finder, "Finder’s window settings", "Finder writes them again"),
        ExcludeRule("**/node_modules", .javascript, "npm packages", "npm install fetches them again"),
        ExcludeRule("~/Library/Caches", .appState, "Apps’ caches", "apps fill them again"),
        ExcludeRule("~/Library/Containers/*/Data/Library/Caches", .appState, "Sandboxed apps’ caches", "apps fill them again"),
        ExcludeRule("~/.Trash", .finder, "The Trash", "already thrown away"),
        ExcludeRule("~/Library/Application Support/Steam", .appState, "Steam’s games", "Steam downloads them again"),
        // Per-user state macOS and the apps rebuild by themselves: logs,
        // Spotlight's index, saved window state, the per-app cookie and
        // session stores (losing one means signing in again in that app,
        // nothing else), app-group caches, Mail's Envelope Index — a
        // SQLite trio Mail rebuilds from the messages it indexes, which
        // the pattern leaves alone — and Photos' search index and
        // analysis caches, rebuilt from the library's database and
        // originals.
        ExcludeRule("~/Library/Logs", .appState, "Apps’ logs", "written afresh as apps run"),
        ExcludeRule("~/Library/Metadata/CoreSpotlight", .indexes, "Spotlight’s index of app content", "Spotlight rebuilds it"),
        ExcludeRule("~/Library/Saved Application State", .appState, "Apps’ reopened windows", "saved again at each quit"),
        ExcludeRule("~/Library/HTTPStorages", .appState, "Apps’ web cookies and sessions", "losing one means signing in again in that app"),
        ExcludeRule("~/Library/Group Containers/*/Library/Caches", .appState, "App groups’ caches", "apps fill them again"),
        ExcludeRule("~/Library/Mail/V*/MailData/Envelope Index*", .indexes, "Mail’s message index", "Mail rebuilds it from the messages, which stay"),
        ExcludeRule("~/Pictures/*.photoslibrary/database/search", .indexes, "Photos’ search index", "Photos rebuilds it from the library"),
        ExcludeRule("~/Pictures/*.photoslibrary/resources/caches", .appState, "Photos’ analysis caches", "Photos rebuilds them from the originals"),
        // A volume's own root bookkeeping — Spotlight's and the
        // file-system events' journals, the trash, Versions' store and
        // editors' temp files — which the volume rebuilds and none of
        // which is the user's files. A plan of /Volumes, of one volume,
        // or of / gets them.
        ExcludeRule("/Volumes/*/.Spotlight-V100", .drives, "Spotlight’s index of the drive", "Spotlight rebuilds it"),
        ExcludeRule("/Volumes/*/.fseventsd", .drives, "The drive’s change journal", "macOS writes it again"),
        ExcludeRule("/Volumes/*/.Trashes", .drives, "The drive’s Trash", "already thrown away"),
        ExcludeRule("/Volumes/*/.DocumentRevisions-V100", .drives, "macOS’s store of document versions", "macOS’s own, not your files"),
        ExcludeRule("/Volumes/*/.TemporaryItems", .drives, "Apps’ temporary files", "apps delete them when done"),
        // The startup disk's own, which the system rebuilds: the sealed
        // System volume (a walk of / would otherwise read the Data volume
        // under /System/Volumes a second time through the firmlinks, the
        // volume holds swap, Preboot and Recovery beside it, and Time
        // Machine never backs it up either), the swap and sleep images,
        // the per-user temp and cache folders, and the system-wide temp,
        // caches and logs. A plan of / gets them all, and is the only one
        // that gets /System; a plan of /private, /private/var or /Library
        // gets the ones below it.
        ExcludeRule("/System", .startupDisk, "The sealed System volume", "macOS installs it; Time Machine skips it too"),
        ExcludeRule("/private/var/vm", .startupDisk, "Swap and sleep images", "macOS writes them again"),
        ExcludeRule("/private/var/folders", .startupDisk, "Per-user temporary files and caches", "macOS fills them again"),
        ExcludeRule("/private/tmp", .startupDisk, "Temporary files", "cleared at restart"),
        ExcludeRule("/Library/Caches", .startupDisk, "System-wide caches", "filled again on demand"),
        ExcludeRule("/Library/Logs", .startupDisk, "System-wide logs", "written afresh"),
    ]

    /// What developer tools rebuild, passed to restic when a plan's
    /// developer switch (`excludeDeveloperFiles`) is on: the ones that fit
    /// its path (`BackupPlan.developerExcludes(for:)`), with the Cargo
    /// marker (`developerMarkers`) beside them. The defaults' bar holds —
    /// nothing here may be the only copy of anything — and where a tool
    /// folder also holds the user's own words, the disposable subfolder is
    /// named, never the folder: `~/.gradle`'s gradle.properties,
    /// `~/.lima`'s lima.yaml, `~/.android`'s keys, `~/.cocoapods`' private
    /// spec repos and `~/.cache`'s working folders stay by staying out of
    /// the list. Kept out on purpose: `**/target`, a generic name the
    /// Cargo marker answers for exactly; virtualenvs by their marker,
    /// pyvenv.cfg, because a project made one in place (`python -m venv .`)
    /// keeps the user's code beside it, which restic would leave out with
    /// the virtualenv — they go by their usual names instead, and one
    /// named otherwise is backed up; `**/vendor`, `**/build`, `**/bin` and
    /// `**/dist`, which hold vendored or built source that is not always
    /// regenerable; `~/Library/Developer/Xcode/Archives`, the only copy of
    /// a shipped build's dSYMs; `~/.cargo/bin`, its cargo-installed
    /// executables.
    static let developer: [ExcludeRule] = [
        // Python: virtualenvs by the names the venv docs and the tools
        // give them, bytecode, and the test and type tools' own caches.
        ExcludeRule("**/.venv", .python, "Virtualenvs", "pip installs them again"),
        ExcludeRule("**/venv", .python, "Virtualenvs", "pip installs them again"),
        ExcludeRule("**/__pycache__", .python, "Python bytecode", "Python compiles it again"),
        ExcludeRule("**/.mypy_cache", .python, "mypy’s cache", "mypy rebuilds it"),
        ExcludeRule("**/.pytest_cache", .python, "pytest’s cache", "pytest rebuilds it"),
        ExcludeRule("**/.ruff_cache", .python, "Ruff’s cache", "Ruff rebuilds it"),
        ExcludeRule("**/.tox", .python, "tox environments", "tox creates them again"),
        ExcludeRule("**/.nox", .python, "nox environments", "nox creates them again"),
        // JavaScript: the frameworks' build state; node_modules is already
        // a default. The package managers' global caches are the home
        // folder's.
        ExcludeRule("**/.next", .javascript, "Next.js build output", "next build makes it again"),
        ExcludeRule("**/.nuxt", .javascript, "Nuxt build output", "nuxt build makes it again"),
        ExcludeRule("**/.svelte-kit", .javascript, "SvelteKit build output", "vite build makes it again"),
        ExcludeRule("**/.parcel-cache", .javascript, "Parcel’s cache", "Parcel rebuilds it"),
        ExcludeRule("**/.turbo", .javascript, "Turborepo’s cache", "Turborepo rebuilds it"),
        ExcludeRule("~/.npm", .javascript, "npm’s download cache", "npm downloads again"),
        ExcludeRule("~/Library/pnpm/store", .javascript, "pnpm’s package store", "pnpm downloads again"),
        ExcludeRule("~/.bun/install/cache", .javascript, "Bun’s package cache", "Bun downloads again"),
        ExcludeRule("~/.yarn/berry/cache", .javascript, "Yarn’s package cache", "Yarn downloads again"),
        // Apple: Xcode's per-project build folders, SwiftPM's, the
        // dependency managers' checkouts, and the per-device symbol dumps
        // Xcode re-extracts from a connected device.
        ExcludeRule("**/DerivedData", .apple, "Xcode’s build products", "Xcode builds them again"),
        ExcludeRule("**/.build", .apple, "Swift package build output", "swift build makes it again"),
        ExcludeRule("**/Pods", .apple, "CocoaPods checkouts", "pod install fetches them again"),
        ExcludeRule("**/Carthage/Build", .apple, "Carthage builds", "carthage builds them again"),
        ExcludeRule("~/.cocoapods/repos/trunk", .apple, "CocoaPods’ spec index", "pod repo update fetches it again"),
        ExcludeRule("~/.cocoapods/repos/master", .apple, "CocoaPods’ spec index", "pod repo update fetches it again"),
        ExcludeRule("~/Library/Developer/Xcode/*DeviceSupport", .apple, "Device symbol files", "Xcode copies them from the device again"),
        // The toolchains' downloaded modules and the JVM's: redownloaded
        // from the registries on demand, while the binaries and the
        // settings beside them are not caches.
        ExcludeRule("~/.cargo/registry", .toolchains, "Rust crates", "cargo downloads them again"),
        ExcludeRule("~/.cargo/git", .toolchains, "Rust Git dependencies", "cargo downloads them again"),
        ExcludeRule("~/.rustup/toolchains", .toolchains, "Rust toolchains", "rustup installs them again"),
        ExcludeRule("~/go/pkg/mod", .toolchains, "Go modules", "go downloads them again"),
        ExcludeRule("~/.m2/repository", .toolchains, "Maven artifacts", "Maven downloads them again"),
        ExcludeRule("~/.gradle/caches", .toolchains, "Gradle’s cache", "Gradle downloads again"),
        ExcludeRule("~/.gradle/wrapper", .toolchains, "Gradle distributions", "the wrapper downloads them again"),
        ExcludeRule("~/.gradle/jdks", .toolchains, "Gradle’s JDKs", "Gradle downloads them again"),
        ExcludeRule("~/.gradle/daemon", .toolchains, "Gradle daemon state and logs", "Gradle writes them again"),
        ExcludeRule("**/.dart_tool", .toolchains, "Dart build state", "dart pub get rebuilds it"),
        ExcludeRule("~/.pub-cache", .toolchains, "Dart packages", "dart pub downloads them again"),
        ExcludeRule("~/Library/Android/sdk", .toolchains, "The Android SDK", "Android Studio installs it again"),
        // Other build tools' caches, and Terraform's working folder — the
        // lockfile beside it stays, so the next init redoes this resolve.
        ExcludeRule("**/.zig-cache", .buildTools, "Zig’s cache", "zig build rebuilds it"),
        ExcludeRule("**/.terraform", .buildTools, "Terraform providers and modules", "terraform init fetches them again"),
        ExcludeRule("**/.direnv", .buildTools, "direnv environments", "direnv builds them again"),
        ExcludeRule("**/.stack-work", .buildTools, "Haskell Stack build output", "stack build makes it again"),
        ExcludeRule("**/_build", .buildTools, "Elixir and OCaml build output", "mix or dune builds it again"),
        ExcludeRule("~/.cache/pre-commit", .buildTools, "pre-commit’s hook environments", "pre-commit installs them again"),
        // Version managers' installed toolchains, redownloaded on demand;
        // the shims and version files beside them stay.
        ExcludeRule("~/.nvm/versions", .versionManagers, "Node versions (nvm)", "nvm installs them again"),
        ExcludeRule("~/.pyenv/versions", .versionManagers, "Python versions (pyenv)", "pyenv installs them again"),
        ExcludeRule("~/.rbenv/versions", .versionManagers, "Ruby versions (rbenv)", "rbenv installs them again"),
        ExcludeRule("~/.asdf/installs", .versionManagers, "Tool versions (asdf)", "asdf installs them again"),
        ExcludeRule("~/.local/share/mise/installs", .versionManagers, "Tool versions (mise)", "mise installs them again"),
        ExcludeRule("~/.sdkman/candidates", .versionManagers, "SDK versions (SDKMAN!)", "sdk installs them again"),
        // Simulators and SwiftUI previews: the devices are recreated on
        // demand, but whatever was installed inside them is not backed up
        // — the switch's trade, said where it is turned on.
        ExcludeRule("~/Library/Developer/CoreSimulator/Devices", .simulators, "Simulator devices", "recreated empty — what was inside is not kept"),
        ExcludeRule("~/Library/Developer/CoreSimulator/Caches", .simulators, "Simulator caches", "Simulator fills them again"),
        ExcludeRule("~/Library/Developer/Xcode/UserData/Previews", .simulators, "SwiftUI preview devices", "Xcode recreates them"),
        ExcludeRule("~/.android/avd", .simulators, "Android emulators", "recreated empty — what was inside is not kept"),
        // Container and virtual-machine disk images — what lives inside
        // the machine is not backed up (OrbStack's own FAQ recommends the
        // exclusion), while the machine's configuration beside the disks
        // stays. Only the disk files are named, never ~/.lima or
        // ~/.colima wholesale.
        ExcludeRule("~/Library/Containers/com.docker.docker/Data/vms", .machines, "Docker Desktop’s disk", "what was inside is not kept"),
        ExcludeRule("~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", .machines, "OrbStack’s disk", "what was inside is not kept"),
        ExcludeRule("~/.lima/*/disk", .machines, "Lima machines’ disks", "what was inside is not kept"),
        ExcludeRule("~/.lima/*/diffdisk", .machines, "Lima machines’ disks", "what was inside is not kept"),
        ExcludeRule("~/.lima/*/basedisk", .machines, "Lima machines’ base images", "Lima downloads them again"),
        ExcludeRule("~/.colima/_lima/*/disk", .machines, "Colima machines’ disks", "what was inside is not kept"),
        ExcludeRule("~/.colima/_lima/*/diffdisk", .machines, "Colima machines’ disks", "what was inside is not kept"),
        ExcludeRule("~/.colima/_lima/*/basedisk", .machines, "Colima machines’ base images", "Colima downloads them again"),
        ExcludeRule("~/.local/share/containers/podman/machine", .machines, "Podman machines", "what was inside is not kept"),
        ExcludeRule("~/.vagrant.d/boxes", .machines, "Vagrant boxes", "vagrant downloads them again"),
    ]

    /// A folder holding one of these files has its contents left out
    /// (restic's `--exclude-if-present`), the marker file itself kept —
    /// how the Cargo target is skipped, whose generic name is not safe to
    /// exclude by pattern: a user's folder that is only named target stays,
    /// a folder with the marker, which a build writes into the target
    /// folder (not into ~/.cargo), does not. Applies to every path.
    static let developerMarkers: [ExcludeRule] = [
        ExcludeRule(".rustc_info.json", .toolchains, "Cargo build output, the marker kept", "cargo build makes it again", isMarker: true),
    ]

    /// Every rule the app knows by its pattern, for labelling a stored row.
    private static let byPattern: [String: ExcludeRule] = Dictionary(
        (defaults + developer).map { ($0.pattern, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// One category's rows, as the Excluding card and the editor's lists
    /// show them.
    struct Section: Identifiable, Equatable {
        let category: ExcludeCategory
        let rows: [Row]
        var id: ExcludeCategory { category }
    }

    /// A row: the line as shown, and the rule's label when the app offered
    /// it — a pattern the user typed has none.
    struct Row: Identifiable, Equatable {
        let line: String
        let rule: ExcludeRule?
        var id: String { line }
    }

    /// `stored` — a plan's own patterns, as typed — then `developer`, the
    /// switch's rules for its folder, sorted into their categories in the
    /// categories' order, each keeping the order it came in. A stored
    /// pattern the app offers wears that rule's label and category; any
    /// other is the user's own. A line already shown is not shown again.
    static func sections(stored: [String], developer: [ExcludeRule] = []) -> [Section] {
        var seen = Set<String>()
        let rows = (stored.map { Row(line: $0, rule: byPattern[$0]) } + developer.map { Row(line: $0.line, rule: $0) })
            .filter { seen.insert($0.line).inserted }
        return ExcludeCategory.allCases.compactMap { category in
            let inCategory = rows.filter { ($0.rule?.category ?? .yours) == category }
            return inCategory.isEmpty ? nil : Section(category: category, rows: inCategory)
        }
    }
}
