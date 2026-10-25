import Foundation

/// The kind of thing a rule the app offers leaves out. The defaults'
/// categories are what the plan editor's two defaults switches cover
/// (`finderFiles`, `systemFiles`); the developer rules' (`developerGroups`)
/// are what its developer switch is ticked by, one checkbox each, so their
/// raw values are what a configuration stores.
enum ExcludeCategory: String, CaseIterable, Codable, Sendable {
    case finder
    case appState
    case indexes
    case drives
    case startupDisk
    case python
    case javascript
    case apple
    case rust
    case go
    case jvm
    case dart
    case ruby
    case php
    case dotnet
    case elixir
    case haskell
    case scala
    case julia
    case r
    case cpp
    case zig
    case ocaml
    case otherTools
    case simulators
    case machines

    var title: String {
        switch self {
        case .finder: "Finder & Trash"
        case .appState: "Apps’ caches & state"
        case .indexes: "Search indexes"
        case .drives: "Drives’ own bookkeeping"
        case .startupDisk: "Startup disk"
        case .python: "Python"
        case .javascript: "JavaScript & TypeScript"
        case .apple: "Swift & Xcode"
        case .rust: "Rust"
        case .go: "Go"
        case .jvm: "Java & Kotlin"
        case .dart: "Dart & Flutter"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .dotnet: ".NET"
        case .elixir: "Elixir & Erlang"
        case .haskell: "Haskell"
        case .scala: "Scala"
        case .julia: "Julia"
        case .r: "R"
        case .cpp: "C & C++"
        case .zig: "Zig"
        case .ocaml: "OCaml"
        case .otherTools: "Other tools"
        case .simulators: "Simulators"
        case .machines: "Containers & virtual machines"
        }
    }

    /// The developer switch's groups, in the categories' order.
    static let developerGroups: [ExcludeCategory] = Array(allCases.drop { $0 != .python })

    /// The defaults' categories the plan editor's Finder & Trash switch
    /// turns on and off.
    static let finderFiles: Set<ExcludeCategory> = [.finder]
    /// The defaults' categories its app caches & system files switch does.
    static let systemFiles: Set<ExcludeCategory> = [.appState, .indexes, .drives, .startupDisk]
}

/// One rule the app offers: a new plan's default, the developer switch's,
/// or a developer group's marker — with what it leaves out and why that is safe,
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
    /// working copy without its object store is "not a git repository".
    /// A plan gets them all, whatever its path; one naming the path or a
    /// folder above it is not passed (`ResticService.pattern(_:covers:)`).
    /// The first five are the list
    /// older builds offered, unchanged and first, but for
    /// `**/node_modules`, which went to the developer switch's JavaScript
    /// rules: plans saved with it keep it as their own row.
    static let defaults: [ExcludeRule] = [
        ExcludeRule(".DS_Store", .finder, "Finder’s window settings", "Finder writes them again"),
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
        // which is the user's files.
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
        // caches and logs.
        ExcludeRule("/System", .startupDisk, "The sealed System volume", "macOS installs it; Time Machine skips it too"),
        ExcludeRule("/private/var/vm", .startupDisk, "Swap and sleep images", "macOS writes them again"),
        ExcludeRule("/private/var/folders", .startupDisk, "Per-user temporary files and caches", "macOS fills them again"),
        ExcludeRule("/private/tmp", .startupDisk, "Temporary files", "cleared at restart"),
        ExcludeRule("/Library/Caches", .startupDisk, "System-wide caches", "filled again on demand"),
        ExcludeRule("/Library/Logs", .startupDisk, "System-wide logs", "written afresh"),
    ]

    /// What developer tools rebuild, one group per language or tool
    /// (`ExcludeCategory.developerGroups`): a group ticked under a plan's
    /// developer switch adds its rules
    /// (`BackupPlan.developerExcludes(groups:)`) to the plan's list,
    /// and its marker, if it has one (`developerMarkers`), is passed while
    /// it is ticked. Each pattern belongs to one group. The defaults' bar
    /// holds — nothing here may be the only copy of anything — and where a
    /// tool folder also holds the user's own words, the disposable
    /// subfolder is named, never the folder: `~/.gradle`'s
    /// gradle.properties, `~/.lima`'s lima.yaml, `~/.android`'s keys,
    /// `~/.cocoapods`' private spec repos, `~/.gem`'s credentials,
    /// `~/.stack`'s config.yaml, `~/.julia/dev`'s packages under
    /// development and `~/.cache`'s working folders stay by staying out of
    /// the list. Kept out on purpose: `**/target`, a generic name the Cargo
    /// marker answers for exactly, and `**/obj`, which the NuGet marker
    /// does; virtualenvs by their marker, pyvenv.cfg, because a project
    /// made one in place (`python -m venv .`) keeps the user's code beside
    /// it, which restic would leave out with the virtualenv — they go by
    /// their usual names instead, and one named otherwise is backed up;
    /// `**/vendor`, `**/build`, `**/bin`, `**/dist`, `**/deps` and
    /// `**/out`, generic names that can hold vendored or built source that
    /// is not always regenerable; `**/.Rproj.user`, where RStudio keeps
    /// unsaved editor buffers; `**/.gradle`, which would match
    /// `~/.gradle`; `~/Library/Developer/Xcode/Archives`, the only copy of
    /// a shipped build's dSYMs; `~/.cargo/bin` and `~/.dotnet/tools`,
    /// installed executables.
    static let developer: [ExcludeRule] = [
        // Python: virtualenvs by the names the venv docs and the tools
        // give them, bytecode, the test and type tools' own caches, and
        // the interpreters and package stores under the home folder.
        ExcludeRule("**/.venv", .python, "Virtualenvs", "pip installs them again"),
        ExcludeRule("**/venv", .python, "Virtualenvs", "pip installs them again"),
        ExcludeRule("**/__pycache__", .python, "Python bytecode", "Python compiles it again"),
        ExcludeRule("**/.mypy_cache", .python, "mypy’s cache", "mypy rebuilds it"),
        ExcludeRule("**/.pytest_cache", .python, "pytest’s cache", "pytest rebuilds it"),
        ExcludeRule("**/.ruff_cache", .python, "Ruff’s cache", "Ruff rebuilds it"),
        ExcludeRule("**/.tox", .python, "tox environments", "tox creates them again"),
        ExcludeRule("**/.nox", .python, "nox environments", "nox creates them again"),
        ExcludeRule("~/.cache/uv", .python, "uv’s package cache", "uv downloads again"),
        ExcludeRule("~/.local/share/uv/python", .python, "Python versions (uv)", "uv installs them again"),
        ExcludeRule("~/.pyenv/versions", .python, "Python versions (pyenv)", "pyenv installs them again"),
        ExcludeRule("~/miniconda3/pkgs", .python, "Conda’s package cache", "conda downloads again"),
        ExcludeRule("~/miniforge3/pkgs", .python, "Conda’s package cache", "conda downloads again"),
        ExcludeRule("~/anaconda3/pkgs", .python, "Conda’s package cache", "conda downloads again"),
        // JavaScript: the packages a project installs, the frameworks'
        // build state, and the package managers' and Node versions'
        // stores, which are the home folder's.
        ExcludeRule("**/node_modules", .javascript, "npm packages", "npm install fetches them again"),
        ExcludeRule("**/.next", .javascript, "Next.js build output", "next build makes it again"),
        ExcludeRule("**/.nuxt", .javascript, "Nuxt build output", "nuxt build makes it again"),
        ExcludeRule("**/.svelte-kit", .javascript, "SvelteKit build output", "vite build makes it again"),
        ExcludeRule("**/.parcel-cache", .javascript, "Parcel’s cache", "Parcel rebuilds it"),
        ExcludeRule("**/.turbo", .javascript, "Turborepo’s cache", "Turborepo rebuilds it"),
        ExcludeRule("**/.angular/cache", .javascript, "Angular’s build cache", "ng build rebuilds it"),
        ExcludeRule("~/.npm", .javascript, "npm’s download cache", "npm downloads again"),
        ExcludeRule("~/Library/pnpm/store", .javascript, "pnpm’s package store", "pnpm downloads again"),
        ExcludeRule("~/.bun/install/cache", .javascript, "Bun’s package cache", "Bun downloads again"),
        ExcludeRule("~/.yarn/berry/cache", .javascript, "Yarn’s package cache", "Yarn downloads again"),
        ExcludeRule("~/.nvm/versions", .javascript, "Node versions (nvm)", "nvm installs them again"),
        ExcludeRule("~/.volta/tools/image", .javascript, "Node versions (Volta)", "Volta installs them again"),
        // Apple: Xcode's per-project build folders, SwiftPM's, the
        // dependency managers' checkouts, the per-device symbol dumps
        // Xcode re-extracts from a connected device, and that device's own
        // files, which CoreDevice mounts into the home folder (`mount`:
        // devicefs, fskit) and restic fails to read (invalid argument,
        // xattr file too large) — seen on macOS 27 with an iPhone attached.
        ExcludeRule("**/DerivedData", .apple, "Xcode’s build products", "Xcode builds them again"),
        ExcludeRule("**/.build", .apple, "Swift package build output", "swift build makes it again"),
        ExcludeRule("**/Pods", .apple, "CocoaPods checkouts", "pod install fetches them again"),
        ExcludeRule("**/Carthage/Build", .apple, "Carthage builds", "carthage builds them again"),
        ExcludeRule("~/.cocoapods/repos/trunk", .apple, "CocoaPods’ spec index", "pod repo update fetches it again"),
        ExcludeRule("~/.cocoapods/repos/master", .apple, "CocoaPods’ spec index", "pod repo update fetches it again"),
        ExcludeRule("~/Library/Developer/Xcode/*DeviceSupport", .apple, "Device symbol files", "Xcode copies them from the device again"),
        ExcludeRule("~/Library/Developer/CoreDevice/DeviceFS", .apple, "Connected devices’ files", "they stay on the device"),
        // Rust: the downloaded crates and toolchains; a target folder goes
        // by its marker (`developerMarkers`).
        ExcludeRule("~/.cargo/registry", .rust, "Rust crates", "cargo downloads them again"),
        ExcludeRule("~/.cargo/git", .rust, "Rust Git dependencies", "cargo downloads them again"),
        ExcludeRule("~/.rustup/toolchains", .rust, "Rust toolchains", "rustup installs them again"),
        ExcludeRule("~/go/pkg/mod", .go, "Go modules", "go downloads them again"),
        ExcludeRule("~/.goenv/versions", .go, "Go versions (goenv)", "goenv installs them again"),
        // The JVM's downloaded artifacts and distributions; the settings
        // beside them are not caches.
        ExcludeRule("~/.m2/repository", .jvm, "Maven artifacts", "Maven downloads them again"),
        ExcludeRule("~/.gradle/caches", .jvm, "Gradle’s cache", "Gradle downloads again"),
        ExcludeRule("~/.gradle/wrapper", .jvm, "Gradle distributions", "the wrapper downloads them again"),
        ExcludeRule("~/.gradle/jdks", .jvm, "Gradle’s JDKs", "Gradle downloads them again"),
        ExcludeRule("~/.gradle/daemon", .jvm, "Gradle daemon state and logs", "Gradle writes them again"),
        ExcludeRule("~/.konan/dependencies", .jvm, "Kotlin/Native’s toolchain downloads", "Kotlin downloads them again"),
        ExcludeRule("~/Library/Android/sdk", .jvm, "The Android SDK", "Android Studio installs it again"),
        ExcludeRule("**/.dart_tool", .dart, "Dart build state", "dart pub get rebuilds it"),
        ExcludeRule("~/.pub-cache", .dart, "Dart packages", "dart pub downloads them again"),
        ExcludeRule("~/fvm/versions", .dart, "Flutter versions (FVM)", "fvm installs them again"),
        // Ruby: gems Bundler installed into a project, and the gems and
        // Rubies under the home folder — `~/.gem`'s credentials stay.
        ExcludeRule("**/vendor/bundle", .ruby, "Gems installed into a project", "bundle install fetches them again"),
        ExcludeRule("~/.gem/ruby", .ruby, "Installed gems", "gem install fetches them again"),
        ExcludeRule("~/.gem/specs", .ruby, "RubyGems’ index cache", "gem downloads it again"),
        ExcludeRule("~/.bundle/cache", .ruby, "Bundler’s cache", "Bundler downloads again"),
        ExcludeRule("~/.rbenv/versions", .ruby, "Ruby versions (rbenv)", "rbenv installs them again"),
        ExcludeRule("~/.rubies", .ruby, "Ruby versions (ruby-install)", "ruby-install installs them again"),
        ExcludeRule("~/.rvm/rubies", .ruby, "Ruby versions (RVM)", "rvm installs them again"),
        ExcludeRule("~/.rvm/gems", .ruby, "RVM’s gems", "gem install fetches them again"),
        // PHP: the test and style tools' caches and Composer's downloads;
        // a project's vendor folder is not named (above).
        ExcludeRule("**/.phpunit.cache", .php, "PHPUnit’s cache", "PHPUnit rebuilds it"),
        ExcludeRule("**/.phpunit.result.cache", .php, "PHPUnit’s results cache", "PHPUnit writes it again"),
        ExcludeRule("**/.php-cs-fixer.cache", .php, "PHP CS Fixer’s cache", "PHP CS Fixer rebuilds it"),
        ExcludeRule("~/.composer/cache", .php, "Composer’s download cache", "Composer downloads again"),
        // .NET: NuGet's global packages; a project's obj folder goes by
        // its marker.
        ExcludeRule("~/.nuget/packages", .dotnet, "NuGet packages", "dotnet restore downloads them again"),
        // Elixir and Erlang: Mix's and rebar3's build folder — dune, OCaml's
        // build tool, writes one by the same name — the language server's
        // build, and the package caches.
        ExcludeRule("**/_build", .elixir, "Elixir, Erlang and OCaml build output", "mix, rebar3 or dune builds it again"),
        ExcludeRule("**/.elixir_ls", .elixir, "ElixirLS’s build", "ElixirLS rebuilds it"),
        ExcludeRule("~/.hex/packages", .elixir, "Hex packages", "mix downloads them again"),
        ExcludeRule("~/.cache/rebar3", .elixir, "rebar3’s cache", "rebar3 downloads again"),
        // Haskell: Stack's and Cabal's build folders and stores, and
        // GHCup's compilers; `~/.stack/config.yaml` stays.
        ExcludeRule("**/.stack-work", .haskell, "Haskell Stack build output", "stack build makes it again"),
        ExcludeRule("**/dist-newstyle", .haskell, "Cabal build output", "cabal build makes it again"),
        ExcludeRule("~/.stack/programs", .haskell, "Stack’s compilers", "stack installs them again"),
        ExcludeRule("~/.stack/snapshots", .haskell, "Stack’s built packages", "stack builds them again"),
        ExcludeRule("~/.stack/pantry", .haskell, "Stack’s package index", "stack downloads it again"),
        ExcludeRule("~/.cabal/packages", .haskell, "Cabal’s downloads", "cabal downloads them again"),
        ExcludeRule("~/.cabal/store", .haskell, "Cabal’s built packages", "cabal builds them again"),
        ExcludeRule("~/.cache/cabal/packages", .haskell, "Cabal’s downloads", "cabal downloads them again"),
        ExcludeRule("~/.local/state/cabal/store", .haskell, "Cabal’s built packages", "cabal builds them again"),
        ExcludeRule("~/.ghcup/ghc", .haskell, "GHC versions (GHCup)", "ghcup installs them again"),
        ExcludeRule("~/.ghcup/cache", .haskell, "GHCup’s downloads", "ghcup downloads again"),
        // Scala: the build server's and the editor's per-project state,
        // and Ivy's and sbt's downloads.
        ExcludeRule("**/.bloop", .scala, "Bloop’s build state", "Bloop rebuilds it"),
        ExcludeRule("**/.metals", .scala, "Metals’ index", "Metals rebuilds it"),
        ExcludeRule("**/.bsp", .scala, "Build-server connection files", "sbt or Mill writes them again"),
        ExcludeRule("~/.ivy2/cache", .scala, "Ivy’s download cache", "sbt downloads again"),
        ExcludeRule("~/.sbt/boot", .scala, "sbt’s launcher downloads", "sbt downloads them again"),
        // Julia: packages, artifacts, precompiled code, registries and
        // juliaup's Julias; packages under development (`dev`) stay.
        ExcludeRule("~/.julia/packages", .julia, "Julia packages", "Pkg downloads them again"),
        ExcludeRule("~/.julia/artifacts", .julia, "Julia artifacts", "Pkg downloads them again"),
        ExcludeRule("~/.julia/compiled", .julia, "Julia’s precompiled code", "Julia compiles it again"),
        ExcludeRule("~/.julia/registries", .julia, "Julia registries", "Pkg downloads them again"),
        ExcludeRule("~/.julia/juliaup", .julia, "Julia versions (juliaup)", "juliaup installs them again"),
        ExcludeRule("**/renv/library", .r, "R packages a project installed", "renv::restore() installs them again"),
        ExcludeRule("**/*.Rcheck", .r, "R CMD check output", "R CMD check writes it again"),
        // C and C++: CLion's build folders, the language servers' indexes,
        // and Conan's and vcpkg's packages.
        ExcludeRule("**/cmake-build-*", .cpp, "CLion’s CMake builds", "CLion builds them again"),
        ExcludeRule("**/.cache/clangd", .cpp, "clangd’s index", "clangd rebuilds it"),
        ExcludeRule("**/.ccls-cache", .cpp, "ccls’ index", "ccls rebuilds it"),
        ExcludeRule("**/vcpkg_installed", .cpp, "vcpkg packages a project installed", "vcpkg installs them again"),
        ExcludeRule("~/.conan2/p", .cpp, "Conan’s packages", "conan install fetches them again"),
        ExcludeRule("~/.conan/data", .cpp, "Conan’s packages", "conan install fetches them again"),
        ExcludeRule("**/.zig-cache", .zig, "Zig’s cache", "zig build rebuilds it"),
        ExcludeRule("**/zig-cache", .zig, "Zig’s cache", "zig build rebuilds it"),
        ExcludeRule("**/zig-out", .zig, "Zig build output", "zig build makes it again"),
        ExcludeRule("~/.cache/zig", .zig, "Zig’s global cache", "zig build rebuilds it"),
        ExcludeRule("**/_opam", .ocaml, "A project’s opam switch", "opam installs it again"),
        ExcludeRule("~/.opam/download-cache", .ocaml, "opam’s downloads", "opam downloads them again"),
        // Tools of no one language: Terraform's working folder — the
        // lockfile beside it stays, so the next init redoes this resolve —
        // direnv's and pre-commit's environments, and the multi-language
        // version managers' installs; their shims and version files stay.
        ExcludeRule("**/.terraform", .otherTools, "Terraform providers and modules", "terraform init fetches them again"),
        ExcludeRule("**/.direnv", .otherTools, "direnv environments", "direnv builds them again"),
        ExcludeRule("~/.cache/pre-commit", .otherTools, "pre-commit’s hook environments", "pre-commit installs them again"),
        ExcludeRule("~/.asdf/installs", .otherTools, "Tool versions (asdf)", "asdf installs them again"),
        ExcludeRule("~/.local/share/mise/installs", .otherTools, "Tool versions (mise)", "mise installs them again"),
        ExcludeRule("~/.sdkman/candidates", .otherTools, "SDK versions (SDKMAN!)", "sdk installs them again"),
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
    /// how a build folder whose generic name is not safe to exclude by
    /// pattern is skipped: a user's folder that is only named target or
    /// obj stays, a folder holding the file the build writes into it does
    /// not. Cargo writes its marker into the target folder (not into
    /// ~/.cargo); NuGet's restore writes project.assets.json into a
    /// project's obj folder. Each applies to every path while its group is
    /// ticked.
    static let developerMarkers: [ExcludeRule] = [
        ExcludeRule(".rustc_info.json", .rust, "Cargo build output, the marker kept", "cargo build makes it again", isMarker: true),
        ExcludeRule("project.assets.json", .dotnet, ".NET intermediate build output, the marker kept", "dotnet build makes it again", isMarker: true),
    ]
}
