import CoreGraphics
import Foundation
import MiniGeometry

// Gerador de PDFs sintéticos com geometria conhecida (PLAN.md §15.1).
// Todo retângulo da verdade está em espaço de página (ver `PageGeometry`).

public enum Scenario: String, CaseIterable, Sendable {
    case book6x9
    case a4Report
    case latexArticleA4
    case twoColumnArticle
    case rotatedPages
    case offsetBoxes
    case cropMarks
    case arxivStamp
    case navigation
    case scannedPage
    case mixedSizes
}

/// Verdade de uma página.
///
/// - `inkBox`: união exata dos bounds de tinta dos glifos e dos traços
///   relevantes (inclui cabeçalho, rodapé e número de página; exclui `ignorableInk`).
/// - `lines`: tinta de cada linha de texto relevante (corpo e cabeçalho/rodapé),
///   na ordem em que foram desenhadas; `headerFooter` marca quais são de cabeçalho/rodapé.
/// - `columns`: tinta de cada coluna de texto do corpo (uma só em página de coluna única).
/// - `mediaBox`/`cropBox`/`trimBox`/`bleedBox`: caixas gravadas no arquivo, em espaço do usuário
///   (`cropBox`/`trimBox`/`bleedBox` nulos = ausentes no arquivo).
public struct PageTruth: Codable, Sendable {
    public let geometry: PageGeometry
    public let mediaBox: CGRect
    public let cropBox: CGRect?
    public let trimBox: CGRect?
    public let bleedBox: CGRect?
    public let inkBox: CGRect?
    public let ignorableInk: [CGRect]
    public let headerFooter: [CGRect]
    public let lines: [CGRect]
    public let columns: [CGRect]
    public let isScan: Bool

    public init(geometry: PageGeometry, mediaBox: CGRect, cropBox: CGRect?, trimBox: CGRect?, bleedBox: CGRect?,
                inkBox: CGRect?, ignorableInk: [CGRect], headerFooter: [CGRect], lines: [CGRect],
                columns: [CGRect], isScan: Bool) {
        self.geometry = geometry
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.trimBox = trimBox
        self.bleedBox = bleedBox
        self.inkBox = inkBox
        self.ignorableInk = ignorableInk
        self.headerFooter = headerFooter
        self.lines = lines
        self.columns = columns
        self.isScan = isScan
    }
}

/// `words` é o multiconjunto de palavras do texto extraível (vazio em scan,
/// que não tem camada de texto). `annotationCount` não inclui links.
public struct DocumentTruth: Codable, Sendable {
    public let pages: [PageTruth]
    public let bodyPointSize: CGFloat
    public let bodyXHeightPt: CGFloat
    public let outlineCount: Int
    public let linkCount: Int
    public let annotationCount: Int
    public let words: [String]

    public init(pages: [PageTruth], bodyPointSize: CGFloat, bodyXHeightPt: CGFloat, outlineCount: Int,
                linkCount: Int, annotationCount: Int, words: [String]) {
        self.pages = pages
        self.bodyPointSize = bodyPointSize
        self.bodyXHeightPt = bodyXHeightPt
        self.outlineCount = outlineCount
        self.linkCount = linkCount
        self.annotationCount = annotationCount
        self.words = words
    }
}

public struct SyntheticDocument: Sendable {
    public let scenario: Scenario
    public let data: Data
    public let truth: DocumentTruth

    public init(scenario: Scenario, data: Data, truth: DocumentTruth) {
        self.scenario = scenario
        self.data = data
        self.truth = truth
    }
}

public enum Corpus {
    public static func make(_ s: Scenario) -> SyntheticDocument {
        Assembler.assemble(s, Scenarios.plan(for: s))
    }

    /// Grava `<cenário>.pdf` e `<cenário>.truth.json` em `dir` (criado se preciso).
    /// Devolve todos os arquivos gravados, PDF e verdade de cada cenário em sequência.
    @discardableResult
    public static func writeAll(to dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var written: [URL] = []
        for s in Scenario.allCases {
            let doc = make(s)
            let pdf = dir.appendingPathComponent("\(s.rawValue).pdf")
            let json = dir.appendingPathComponent("\(s.rawValue).truth.json")
            try doc.data.write(to: pdf)
            try encoder.encode(doc.truth).write(to: json)
            written += [pdf, json]
        }
        return written
    }
}
