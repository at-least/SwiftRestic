import Foundation
import Testing

/// A deterministic pseudo-random generator (SplitMix64), so a property failure
/// reproduces exactly: the seed in the test is the whole input.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Property tests for the console's shell-like tokenizer.
///
/// One example per quirk is not enough for a parser: these run hundreds of
/// generated inputs against invariants that must hold for every input, seeded
/// so a failure names the exact case to reproduce.
@Suite("Tokenizer properties")
struct TokenizerPropertyTests {
    /// A pool without whitespace, quotes or backslashes: characters that can
    /// appear in a token verbatim.
    private static let plainCharacters = Array("abcXYZ019._-/:@+=,%[]{}()!$^&*;<>|\u{00E9}\u{4E2D}")

    private func randomToken(_ generator: inout SeededGenerator, length: Int) -> String {
        String((0 ..< length).map { _ in
            Self.plainCharacters[Int(generator.next() % UInt64(Self.plainCharacters.count))]
        })
    }

    @Test("space-joined tokens survive a tokenize round trip")
    func roundTrip() {
        var generator = SeededGenerator(seed: 1)
        for _ in 0 ..< 300 {
            let count = Int(generator.next() % 6)
            let tokens = (0 ..< count).map { _ in randomToken(&generator, length: Int(generator.next() % 12) + 1) }
            let line = tokens.joined(separator: "  ") // two spaces: no empty-token luck
            #expect(CommandLineTokenizer.tokenize(line) == tokens, "line: \(line)")
        }
    }

    @Test("arbitrary plain text is a fixed point of join-and-retokenize")
    func canonicalFormIsStable() {
        // No quotes or backslashes: quoting is the only thing that can make a
        // space-joined token list ambiguous, so for this alphabet the joined
        // line the console shows must mean exactly the same arguments when run.
        let alphabet = Array("ab de")
        var generator = SeededGenerator(seed: 2)
        for _ in 0 ..< 500 {
            let length = Int(generator.next() % 24)
            let input = String((0 ..< length).map { _ in
                alphabet[Int(generator.next() % UInt64(alphabet.count))]
            })
            let tokens = CommandLineTokenizer.tokenize(input)
            #expect(
                CommandLineTokenizer.tokenize(tokens.joined(separator: " ")) == tokens,
                "input: \(input.debugDescription) is not stable under re-tokenization"
            )
        }
    }

    @Test("arbitrary input never crashes, and only quotes can produce an empty token")
    func arbitraryInputIsSafe() {
        // Quotes, escapes, every kind of whitespace.
        let alphabet = Array("a b'c\"d\\ e\t\n")
        var generator = SeededGenerator(seed: 2)
        for _ in 0 ..< 500 {
            let length = Int(generator.next() % 24)
            let input = String((0 ..< length).map { _ in
                alphabet[Int(generator.next() % UInt64(alphabet.count))]
            })
            let tokens = CommandLineTokenizer.tokenize(input)
            // An empty argument can only come from an explicit empty quote
            // pair — `''` — the same as in a shell. Anything else would be the
            // tokenizer inventing an argument nobody typed.
            #expect(
                tokens.allSatisfy { !$0.isEmpty } || input.contains("'") || input.contains("\""),
                "input: \(input.debugDescription) produced an empty token without any quotes"
            )
        }
    }

    @Test("single quotes protect every character except the quote itself")
    func singleQuoteWrapping() {
        // The quote itself is the one character single quotes cannot carry.
        let safeInsideSingleQuotes = Array("a b\"c\\de\tf")
        var generator = SeededGenerator(seed: 3)
        for _ in 0 ..< 300 {
            let length = Int(generator.next() % 20)
            let body = String((0 ..< length).map { _ in
                safeInsideSingleQuotes[Int(generator.next() % UInt64(safeInsideSingleQuotes.count))]
            })
            #expect(
                CommandLineTokenizer.tokenize("'\(body)'") == [body],
                "'\(body.debugDescription)' did not survive single-quote wrapping"
            )
        }
    }
}
