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

/// Linha de texto. Em `Block.lines` (M3), `rect` é colado à tinta da linha
/// (perfil do raster dentro do bloco), não a caixa tipográfica: o fatiamento
/// corta nos vãos entre linhas e não pode atravessar ascendentes/descendentes.
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

/// Folha do XY-cut (PLAN.md §5.6). Contrato com o LayoutEngine (E3–E6):
/// - `rect` colado à tinta, em espaço de página;
/// - blocos de uma página são disjuntos e, juntos, cobrem toda a tinta da
///   página (fora das `ignoredRegion`): todo pixel de tinta está em exatamente um;
/// - `lines` em blocos de texto: linhas coladas à tinta, de cima para baixo, cada
///   tinta do bloco dentro de uma linha; em figura/tabela/equação pode ser vazio
///   (bloco atômico, nunca fatiado);
/// - `column`: índice da coluna (0 = mais à esquerda) dentro da seção; `nil` =
///   largura total (título, resumo, figura larga).
public struct Block: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var type: BlockType
    public var lines: [Line]
    public var column: Int?

    /// Bloco que nunca pode ser cortado por fatia.
    public var isAtomic: Bool { [.figure, .table, .equation].contains(type) }

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
    /// Tinta sem os blocos `.headerFooter` (raster, apertada); base do E2.
    /// `nil` = nada de cabeçalho/rodapé detectado (ou só ele na página): use `inkBox`.
    public var bodyInkBox: CGRect?
    /// Linhas de texto detectadas, de cima para baixo.
    public var lines: [Line]
    /// Blocos em ordem de leitura (contrato em `Block`). Vazio = análise sem
    /// segmentação; consumidores caem para `lines`/`inkBox`.
    public var blocks: [Block]
    /// Altura-x do corpo de texto (moda ponderada), em pontos de origem.
    public var bodyXHeightPt: CGFloat?
    /// Menor altura-x relevante (notas), em pontos de origem.
    public var smallestXHeightPt: CGFloat?
    public var warnings: [AnalysisWarning]

    public init(index: Int, boxes: PageBoxes, geometry: PageGeometry, kind: PageKind, inkBox: CGRect?,
                lines: [Line] = [], blocks: [Block] = [], bodyXHeightPt: CGFloat? = nil,
                smallestXHeightPt: CGFloat? = nil, warnings: [AnalysisWarning] = [], bodyInkBox: CGRect? = nil) {
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
        self.bodyInkBox = bodyInkBox
    }

    /// Caixa efetiva em espaço de página.
    public var pageBox: CGRect { geometry.pageBox }

    /// Folga em volta da caixa tipográfica de um bloco removido (antialiasing).
    public static let removedBlockMarginPt: CGFloat = 1

    /// Blocos `.headerFooter` que ficaram fora de `bodyInkBox`, ou seja, o que o
    /// E2 remove; com `removedBlockMarginPt` de folga. Bloco colado no corpo (que
    /// `bodyInkBox` manteve) tem o centro dentro da faixa vertical do corpo e fica.
    public var removedHeaderFooter: [CGRect] {
        guard let body = bodyInkBox else { return [] }
        return blocks.filter { $0.type == .headerFooter && ($0.rect.midY > body.maxY || $0.rect.midY < body.minY) }
            .map { $0.rect.insetBy(dx: -Self.removedBlockMarginPt, dy: -Self.removedBlockMarginPt) }
    }
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
