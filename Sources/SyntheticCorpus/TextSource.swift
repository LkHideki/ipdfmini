import Foundation

/// Gerador com semente fixa: a saída não pode depender de `SystemRandomNumberGenerator`
/// nem de `hashValue` (aleatorizado por processo).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Palavras pseudoaleatórias (sílabas CV) com pontuação ocasional.
final class TextSource {
    private var rng: SplitMix64
    private var sentenceLength = 8
    private var sinceStop = 0
    private var capitalizeNext = true

    private static let onsets = ["b", "c", "d", "f", "g", "h", "j", "l", "m", "n", "p", "r", "s", "t", "v", "z", "qu", "ch"]
    private static let vowels = ["a", "e", "i", "o", "u"]
    private static let codas = ["", "", "", "n", "r", "s", "l", "m"]

    init(seed: UInt64) {
        rng = SplitMix64(state: seed)
        sentenceLength = int(in: 6...14)
    }

    func int(in range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }

    private func pick(_ a: [String]) -> String { a[Int.random(in: 0..<a.count, using: &rng)] }

    func word(maxSyllables: Int = 4) -> String {
        var w = ""
        for _ in 0..<int(in: 1...maxSyllables) {
            w += pick(Self.onsets) + pick(Self.vowels) + pick(Self.codas)
        }
        return w
    }

    /// Palavra com pontuação de frase.
    func token() -> String {
        var w = word()
        if capitalizeNext { w = w.prefix(1).uppercased() + w.dropFirst(); capitalizeNext = false }
        sinceStop += 1
        if sinceStop >= sentenceLength {
            sinceStop = 0
            sentenceLength = int(in: 6...14)
            capitalizeNext = true
            w += "."
        } else if int(in: 0...8) == 0 {
            w += ","
        }
        return w
    }

    /// Título curto, sem pontuação, com iniciais maiúsculas.
    func title(words n: Int) -> String {
        (0..<n).map { _ in
            let w = word(maxSyllables: 2)
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
