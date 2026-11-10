import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFWriting
import SyntheticCorpus
@testable import MiniKit

/// PDFs gerados ficam no diretório temporário do sistema.
enum TestFiles {
    static let root: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("MiniKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// Grava o PDF do cenário (uma vez por processo de teste).
    static func source(_ s: Scenario) throws -> URL {
        try CorpusCache.withLock {
            let u = url("\(s.rawValue).pdf")
            if !FileManager.default.fileExists(atPath: u.path) { try CorpusCache.doc(s).data.write(to: u) }
            return u
        }
    }
}

/// Cada cenário é gerado uma vez só, em série: geração concorrente já travou
/// o processo na criação de fontes do CoreText (SPIKES.md S3).
enum CorpusCache {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var docs: [Scenario: SyntheticDocument] = [:]

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func doc(_ s: Scenario) -> SyntheticDocument {
        withLock {
            if let d = docs[s] { return d }
            let d = Corpus.make(s)
            docs[s] = d
            return d
        }
    }
}

/// Livros 6×9 do aceite do M1 (os demais cenários são Letter/A4).
let bookScenarios: [Scenario] = [.book6x9, .mixedSizes, .cropMarks, .rotatedPages]

struct Converted: Sendable {
    let scenario: Scenario
    let truth: DocumentTruth
    let report: ConversionReport
    let source: URL
    let output: URL
}

/// Converte cada cenário uma vez só, compartilhado entre os testes.
actor ConversionCache {
    static let shared = ConversionCache()
    private var tasks: [String: Task<Converted, Error>] = [:]
    private var analyses: [Scenario: Task<DocumentAnalysis, Error>] = [:]

    /// `removeHeaders`: `ConversionOptions.removeHeaderFooter`; `mode`: modo forçado (padrão auto);
    /// `split`: `ConversionOptions.allowSplitting` (padrão desligado, como no app e na CLI).
    func converted(_ s: Scenario, removeHeaders: Bool = false, mode: ConversionMode = .auto,
                   split: Bool = false) async throws -> Converted {
        let key = "\(s.rawValue)|\(removeHeaders)|\(mode.rawValue)|\(split)"
        if let t = tasks[key] { return try await t.value }
        let t = Task {
            let src = try TestFiles.source(s)
            let out = TestFiles.url("\(s.rawValue).\(removeHeaders ? "e2" : "mini").\(mode.rawValue)\(split ? ".split" : "").pdf")
            let report = try await Converter().convert(input: src, output: out,
                                                       options: ConversionOptions(mode: mode, removeHeaderFooter: removeHeaders,
                                                                                  allowSplitting: split))
            return Converted(scenario: s, truth: CorpusCache.doc(s).truth, report: report, source: src, output: out)
        }
        tasks[key] = t
        return try await t.value
    }

    func analysis(_ s: Scenario) async throws -> DocumentAnalysis {
        if let t = analyses[s] { return try await t.value }
        let t = Task { try await Converter().analyze(input: try TestFiles.source(s)) }
        analyses[s] = t
        return try await t.value
    }
}

/// Mesma regra de agrupamento por tamanho do LayoutEngine (3%, mínimo 2 pt).
func sizeGroups(_ sizes: [CGSize]) -> [Int] {
    func close(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) <= max(2, 0.03 * max(abs(x), abs(y))) }
    var reps: [CGSize] = []
    return sizes.map { s in
        if let g = reps.firstIndex(where: { close($0.width, s.width) && close($0.height, s.height) }) { return g }
        reps.append(s)
        return reps.count - 1
    }
}

extension CGRect {
    func maxEdgeDistance(to o: CGRect) -> CGFloat {
        Swift.max(abs(minX - o.minX), abs(maxX - o.maxX), abs(minY - o.minY), abs(maxY - o.maxY))
    }
}
