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
    // M3: segmentação em blocos, colunas e fatiamento.
    case arxivTwoColumn
    case reportWithFigures
    case tallFigure
}

/// Bloco de verdade (mesma língua de `PDFAnalysis.Block`, sem depender dela).
///
/// - `rect`: tinta exata do bloco, em espaço de página: união da tinta registrada
///   enquanto o bloco esteve aberto no `Canvas`. Blocos de uma página são disjuntos e
///   sua união é a `inkBox`.
/// - `type`: nome de `BlockType` (paragraph, heading, equation, figure, table, caption,
///   note, list, headerFooter).
/// - `column`: índice da coluna (0 = esquerda) dentro da seção de colunas; nulo =
///   largura total, e também toda página de coluna única.
/// - `readingOrder`: 0..n-1 por página; igual à ordem do array.
/// - `lines`: tinta de cada linha, de cima para baixo; vazio em figura, tabela e equação
///   (blocos atômicos).
public struct BlockTruth: Codable, Sendable, Equatable {
    public let rect: CGRect
    public let type: String
    public let column: Int?
    public let readingOrder: Int
    public let lines: [CGRect]

    public init(rect: CGRect, type: String, column: Int?, readingOrder: Int, lines: [CGRect]) {
        self.rect = rect
        self.type = type
        self.column = column
        self.readingOrder = readingOrder
        self.lines = lines
    }
}

/// Verdade de uma página.
///
/// - `inkBox`: união exata dos bounds de tinta dos glifos e dos traços
///   relevantes (inclui cabeçalho, rodapé e número de página; exclui `ignorableInk`).
/// - `lines`: tinta de cada linha de texto relevante (corpo e cabeçalho/rodapé),
///   na ordem em que foram desenhadas; `headerFooter` marca quais são de cabeçalho/rodapé.
/// - `columns`: tinta de cada coluna de texto do corpo (uma só em página de coluna única).
/// - `blocks`: segmentação de referência em ordem de leitura; vazia nos cenários
///   anteriores ao M3 (e em JSON antigo).
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
    public let blocks: [BlockTruth]

    public init(geometry: PageGeometry, mediaBox: CGRect, cropBox: CGRect?, trimBox: CGRect?, bleedBox: CGRect?,
                inkBox: CGRect?, ignorableInk: [CGRect], headerFooter: [CGRect], lines: [CGRect],
                columns: [CGRect], isScan: Bool, blocks: [BlockTruth] = []) {
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
        self.blocks = blocks
    }

    // `blocks` é aditivo: JSON gravado antes do M3 não tem a chave.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        geometry = try c.decode(PageGeometry.self, forKey: .geometry)
        mediaBox = try c.decode(CGRect.self, forKey: .mediaBox)
        cropBox = try c.decodeIfPresent(CGRect.self, forKey: .cropBox)
        trimBox = try c.decodeIfPresent(CGRect.self, forKey: .trimBox)
        bleedBox = try c.decodeIfPresent(CGRect.self, forKey: .bleedBox)
        inkBox = try c.decodeIfPresent(CGRect.self, forKey: .inkBox)
        ignorableInk = try c.decode([CGRect].self, forKey: .ignorableInk)
        headerFooter = try c.decode([CGRect].self, forKey: .headerFooter)
        lines = try c.decode([CGRect].self, forKey: .lines)
        columns = try c.decode([CGRect].self, forKey: .columns)
        isScan = try c.decode(Bool.self, forKey: .isScan)
        blocks = try c.decodeIfPresent([BlockTruth].self, forKey: .blocks) ?? []
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
