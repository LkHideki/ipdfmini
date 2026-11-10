import CoreGraphics
import MiniGeometry

// Tipos de dados da análise. PLAN.md §5 e §14.3.
// Contrato entre PDFAnalysis (produz) e LayoutEngine/PDFWriting/MiniKit
// (consomem). Só Foundation/CoreGraphics: nada de PDFKit aqui.
// Todo retângulo está em espaço de página (ver `PageGeometry`).

/// Caixas da página como estão no arquivo, em espaço do usuário.
public struct PageBoxes: Codable, Sendable, Equatable {
    public var media: CGRect
    public var crop: CGRect
    public var trim: CGRect?
    public var bleed: CGRect?
    public var art: CGRect?

    public init(media: CGRect, crop: CGRect, trim: CGRect? = nil, bleed: CGRect? = nil, art: CGRect? = nil) {
        self.media = media
        self.crop = crop
        self.trim = trim
        self.bleed = bleed
        self.art = art
    }
}

public enum PageKind: String, Codable, Sendable {
    case digitalText, scan, mixed, empty
}

public enum DocumentKind: String, Codable, Sendable {
    case book, twoColumnArticle, a4Report, slides, scannedBook, scannedSpread, comics, sheetMusic, form, unknown
}

public enum BlockType: String, Codable, Sendable {
    case paragraph, heading, equation, figure, table, caption, note, list, headerFooter, unknown
}

public struct Line: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var baseline: CGFloat
    public var xHeightPt: CGFloat
    public var words: [CGRect]

    public init(rect: CGRect, baseline: CGFloat, xHeightPt: CGFloat, words: [CGRect] = []) {
        self.rect = rect
        self.baseline = baseline
        self.xHeightPt = xHeightPt
        self.words = words
    }
}

public struct Block: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var type: BlockType
    public var lines: [Line]
    public var column: Int?

    public init(rect: CGRect, type: BlockType, lines: [Line], column: Int? = nil) {
        self.rect = rect
        self.type = type
        self.lines = lines
        self.column = column
    }
}

public enum AnalysisWarning: Codable, Sendable, Equatable {
    /// Caixa raster e caixa de texto/imagem divergem (fio, marca de corte, marca-d'água).
    case inkBoxDivergence(points: CGFloat)
    /// Região excluída do cálculo de tinta (carimbo arXiv, marcas de corte…).
    case ignoredRegion(CGRect, reason: String)
    case renderFailed(String)
    case noTextFound
}

public struct PageAnalysis: Codable, Sendable, Equatable {
    public var index: Int
    public var boxes: PageBoxes
    public var geometry: PageGeometry
    public var kind: PageKind
    /// Caixa de tinta em espaço de página; `nil` se a página está vazia.
    public var inkBox: CGRect?
    /// Linhas de texto detectadas, de cima para baixo.
    public var lines: [Line]
    /// Blocos em ordem de leitura (M1 pode deixar vazio; M3 preenche).
    public var blocks: [Block]
    /// Altura-x do corpo de texto (moda ponderada), em pontos de origem.
    public var bodyXHeightPt: CGFloat?
    /// Menor altura-x relevante (notas), em pontos de origem.
    public var smallestXHeightPt: CGFloat?
    public var warnings: [AnalysisWarning]

    public init(index: Int, boxes: PageBoxes, geometry: PageGeometry, kind: PageKind, inkBox: CGRect?,
                lines: [Line] = [], blocks: [Block] = [], bodyXHeightPt: CGFloat? = nil,
                smallestXHeightPt: CGFloat? = nil, warnings: [AnalysisWarning] = []) {
        self.index = index
        self.boxes = boxes
        self.geometry = geometry
        self.kind = kind
        self.inkBox = inkBox
        self.lines = lines
        self.blocks = blocks
        self.bodyXHeightPt = bodyXHeightPt
        self.smallestXHeightPt = smallestXHeightPt
        self.warnings = warnings
    }

    /// Caixa efetiva em espaço de página.
    public var pageBox: CGRect { geometry.pageBox }
}

public struct DocumentAnalysis: Codable, Sendable, Equatable {
    public static let analyzerVersion = 1

    public var sha256: String
    public var analyzerVersion: Int
    public var pageCount: Int
    public var pages: [PageAnalysis]
    public var kind: DocumentKind
    /// Altura-x do corpo no documento inteiro (moda ponderada entre páginas).
    public var bodyXHeightPt: CGFloat?
    public var title: String?
    public var author: String?

    public init(sha256: String, analyzerVersion: Int = DocumentAnalysis.analyzerVersion, pageCount: Int,
                pages: [PageAnalysis], kind: DocumentKind, bodyXHeightPt: CGFloat?, title: String? = nil, author: String? = nil) {
        self.sha256 = sha256
        self.analyzerVersion = analyzerVersion
        self.pageCount = pageCount
        self.pages = pages
        self.kind = kind
        self.bodyXHeightPt = bodyXHeightPt
        self.title = title
        self.author = author
    }
}
