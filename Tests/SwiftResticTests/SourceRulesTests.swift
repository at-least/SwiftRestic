import Foundation
import Testing

struct SourceFile {
    /// From the repository's root.
    let path: String
    let lines: [String]
}

extension SourceFile {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Swift files of a folder, or the one file. A path that is gone
    /// throws, so a renamed path fails its rule instead of passing it empty.
    static func swiftFiles(under path: String) throws -> [SourceFile] {
        let url = repositoryRoot.appendingPathComponent(path)
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let paths = isDirectory
            ? try FileManager.default.subpathsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".swift") }.sorted().map { "\(path)/\($0)" }
            : [path]
        return try paths.map { path in
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            return SourceFile(path: path, lines: text.components(separatedBy: "\n"))
        }
    }

    /// `path:line` for each line the rule names.
    func places(where breaksTheRule: (Int) -> Bool) -> [String] {
        lines.indices.filter(breaksTheRule).map { "\(path):\($0 + 1)" }
    }
}

enum SourceRule {
    static func uiFrameworkImports(in file: SourceFile) -> [String] {
        file.places { index in
            ["import AppKit", "import SwiftUI", "import Cocoa"].contains { file.lines[index].contains($0) }
        }
    }

    static func grdbImportsOutsideTheIndex(in file: SourceFile) -> [String] {
        let name = file.path.split(separator: "/").last ?? ""
        let isTheIndex = file.path == "Sources/SwiftRestic/Services/Index/\(name)" && name.hasPrefix("SnapshotIndex")
        return isTheIndex ? [] : file.places { file.lines[$0].hasPrefix("import GRDB") }
    }

    static func importsOfTheAppModule(in file: SourceFile) throws -> [String] {
        let importOfTheApp = try Regex(#"^\s*(@testable\s+)?import\s+SwiftRestic(\s|$)"#)
        return file.places { file.lines[$0].firstMatch(of: importOfTheApp) != nil }
    }

    /// A modifier chain is the run of lines starting with "." around the
    /// `.textSelection` line, with the line the run hangs from.
    static func labelsOnSelectableText(in file: SourceFile) -> [String] {
        let lines = file.lines
        func isModifier(_ index: Int) -> Bool {
            lines[index].drop { $0 == " " || $0 == "\t" }.hasPrefix(".")
        }
        var places: [String] = []
        for index in lines.indices where lines[index].contains(".textSelection(.enabled)") {
            var first = index
            while first > 0, isModifier(first) { first -= 1 }
            var last = index
            while last < lines.count - 1, isModifier(last + 1) { last += 1 }
            places += (first ... last)
                .filter { lines[$0].contains(".accessibilityLabel(") }
                .map { "\(file.path):\($0 + 1)" }
        }
        return places
    }
}

/// Rules on the text of the sources, which the compiler does not enforce.
@Suite("source rules")
struct SourceRulesTests {
    /// Core, Models and the restic engine stay free of UI frameworks, so a
    /// port off macOS does not inherit AppKit. An import guard only: the
    /// runner still calls Darwin.read. NSString (expandTilde) is Foundation's
    /// and allowed.
    @Test(
        "the portable layer imports no UI framework",
        arguments: [
            "Sources/SwiftRestic/Core",
            "Sources/SwiftRestic/Models",
            "Sources/SwiftRestic/Services/ResticService.swift",
            "Sources/SwiftRestic/Services/ResticClient.swift",
            "Sources/SwiftRestic/Services/Index",
        ]
    )
    func portableLayerImportsNoUIFramework(path: String) throws {
        let places = try SourceFile.swiftFiles(under: path).flatMap(SourceRule.uiFrameworkImports)
        #expect(places.isEmpty, "AppKit, SwiftUI or Cocoa imported in the portable layer at \(places)")
    }

    @Test("an import of SwiftUI in a portable file is named with its line")
    func uiFrameworkImportIsCaught() {
        let file = SourceFile(path: "Core/Sample.swift", lines: ["import Foundation", "import SwiftUI"])
        #expect(SourceRule.uiFrameworkImports(in: file) == ["Core/Sample.swift:2"])
    }

    /// GRDB stays inside the snapshot index: every other layer reads it
    /// through SnapshotIndex's own types, so the database can be swapped
    /// without a sweep.
    @Test("GRDB is imported only by the snapshot index's files")
    func grdbStaysInsideTheIndex() throws {
        let places = try SourceFile.swiftFiles(under: "Sources").flatMap(SourceRule.grdbImportsOutsideTheIndex)
        #expect(places.isEmpty, "GRDB imported outside Services/Index/SnapshotIndex*.swift at \(places)")
    }

    @Test("an import of GRDB is caught in a view and in the index's folder beside SnapshotIndex, and allowed in SnapshotIndex's files")
    func grdbImportIsCaughtOutsideTheIndex() {
        func places(_ path: String) -> [String] {
            SourceRule.grdbImportsOutsideTheIndex(in: SourceFile(path: path, lines: ["import GRDB"]))
        }
        #expect(places("Sources/SwiftRestic/Views/RootView.swift") == ["Sources/SwiftRestic/Views/RootView.swift:1"])
        #expect(places("Sources/SwiftRestic/Services/Index/Backfill.swift") == ["Sources/SwiftRestic/Services/Index/Backfill.swift:1"])
        #expect(places("Sources/SwiftRestic/Services/Index/SnapshotIndex+Files.swift").isEmpty)
    }

    /// The test target compiles the app's sources itself (project.yml) and
    /// has no SwiftRestic module. An import of it resolves against a module
    /// an earlier build left in DerivedData (only a warning, "missing a
    /// dependency on 'SwiftRestic'"), and a clean checkout then fails with
    /// "Unable to resolve module dependency: 'SwiftRestic'".
    @Test("no test file imports the app as a module")
    func testsDoNotImportTheApp() throws {
        let places = try SourceFile.swiftFiles(under: "Tests/SwiftResticTests").flatMap(SourceRule.importsOfTheAppModule)
        #expect(places.isEmpty, "a test file imports SwiftRestic at \(places); the test target has no such module")
    }

    @Test("a plain and a testable import of the app are caught; an import of a module that only starts with its name is not")
    func importOfTheAppIsCaught() throws {
        let file = SourceFile(
            path: "Tests/Sample.swift",
            lines: ["import SwiftRestic", "  @testable import SwiftRestic", "import SwiftResticSupport"]
        )
        #expect(try SourceRule.importsOfTheAppModule(in: file) == ["Tests/Sample.swift:1", "Tests/Sample.swift:2"])
    }

    /// A Text with both .textSelection(.enabled) and .accessibilityLabel
    /// makes SwiftUI recurse until the stack overflows when any accessibility
    /// client reads it (seen on macOS 27.0.1). The label goes on the row
    /// around it.
    @Test("no selectable Text carries an accessibility label")
    func selectableTextHasNoAccessibilityLabel() throws {
        let places = try SourceFile.swiftFiles(under: "Sources").flatMap(SourceRule.labelsOnSelectableText)
        #expect(places.isEmpty, ".accessibilityLabel on a selectable Text crashes accessibility clients, at \(places)")
    }

    @Test("a label is caught before and after .textSelection in one modifier chain, and not in the next statement's chain")
    func labelOnSelectableTextIsCaught() {
        let file = SourceFile(
            path: "Views/Sample.swift",
            lines: [
                "Text(name)",
                "    .accessibilityLabel(\"Name\")",
                "    .textSelection(.enabled)",
                "    .accessibilityLabel(\"Again\")",
                "Text(other)",
                "    .accessibilityLabel(\"Other\")",
            ]
        )
        #expect(SourceRule.labelsOnSelectableText(in: file) == ["Views/Sample.swift:2", "Views/Sample.swift:4"])
    }
}
