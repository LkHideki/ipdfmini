import CoreGraphics
import MiniGeometry
import PDFAnalysis

// Plano de layout: artefato central do pipeline. PLAN.md §4.
// Todas as estratégias produzem este tipo; um escritor só consome.

public struct Placement: Codable, Sendable, Equatable {
    public var sourcePage: Int
    /// Janela recortada da página de origem, em espaço de página.
    public var sourceRect: CGRect
    /// Espaço de página de origem → espaço da página de saída.
    public var transform: CGAffineTransform
    /// Sub-regiões (espaço de página de origem) a mascarar.
    public var hidden: [CGRect]

    public init(sourcePage: Int, sourceRect: CGRect, transform: CGAffineTransform, hidden: [CGRect] = []) {
        self.sourcePage = sourcePage
        self.sourceRect = sourceRect
        self.transform = transform
        self.hidden = hidden
    }

    /// Fator de escala uniforme da colocação.
    public var scale: CGFloat { (transform.a * transform.a + transform.b * transform.b).squareRoot() }
}

public enum Overlay: Codable, Sendable, Equatable {
    /// "p. 37 · 2/3"
    case pageIndicator(text: String, rect: CGRect)
    case progressBar(fraction: Double, rect: CGRect)
    case continuityMark(y: CGFloat)
}

public struct OutputPage: Codable, Sendable, Equatable {
    /// Sempre a proporção do viewport.
    public var sizePt: CGSize
    public var placements: [Placement]
    public var overlays: [Overlay]

    public init(sizePt: CGSize, placements: [Placement], overlays: [Overlay] = []) {
        self.sizePt = sizePt
        self.placements = placements
        self.overlays = overlays
    }
}

public enum StrategyID: String, Codable, Sendable, CaseIterable {
    case passthrough = "E0"
    case crop = "E1"
    case aggressiveCrop = "E2"
    case landscapeSlices = "E3"
    case portraitSlices = "E4"
    case columns = "E5"
    case reflow = "E6"
    case semantic = "E7"

    /// Custo de fidelidade: E0 = 0 … E7 = 7.
    public var fidelityCost: Int { StrategyID.allCases.firstIndex(of: self)! }
}

public enum PageClassMode: String, Codable, Sendable {
    /// Uma classe só.
    case all
    /// Ímpares e pares separados (margem de lombada).
    case oddEven
    /// Agrupamento por tamanho de página.
    case bySize
}

/// Ajustes reaplicáveis de um documento. PLAN.md §12.4.
public struct Recipe: Codable, Sendable, Equatable {
    public var id: String
    public var strategy: StrategyID
    public var legibility: Legibility
    /// Respiro em cada lado, em mm. PLAN.md §6.3.
    public var marginMM: Double
    public var classMode: PageClassMode
    /// Percentil usado para a mancha de referência da classe. PLAN.md §6.1.
    public var referencePercentile: Double
    /// Escala máxima (não ampliar além disso).
    public var maxScale: CGFloat

    public init(id: String = "default", strategy: StrategyID = .crop, legibility: Legibility = .standard,
                marginMM: Double = 2, classMode: PageClassMode = .oddEven, referencePercentile: Double = 0.95,
                maxScale: CGFloat = 1.6) {
        self.id = id
        self.strategy = strategy
        self.legibility = legibility
        self.marginMM = marginMM
        self.classMode = classMode
        self.referencePercentile = referencePercentile
        self.maxScale = maxScale
    }
}

public enum PlanWarning: Codable, Sendable, Equatable {
    /// Página com tinta fora da janela da classe: escala individual.
    case scaleException(page: Int, classScale: CGFloat, pageScale: CGFloat)
    case belowMinimumLegibility(xHeightMM: Double)
    case emptyPage(page: Int)
}

public struct LayoutPlan: Codable, Sendable, Equatable {
    public var profile: ViewportProfile
    public var pages: [OutputPage]
    public var recipe: Recipe
    public var warnings: [PlanWarning]

    public init(profile: ViewportProfile, pages: [OutputPage], recipe: Recipe, warnings: [PlanWarning] = []) {
        self.profile = profile
        self.pages = pages
        self.recipe = recipe
        self.warnings = warnings
    }
}

/// Estimativa barata de um candidato, sem gerar plano completo. PLAN.md §8.
public struct Estimate: Codable, Sendable, Equatable {
    public var strategy: StrategyID
    public var orientation: Orientation
    public var bodyXHeightMM: Double?
    public var smallestXHeightMM: Double?
    public var screensPerSourcePage: Double
    public var fidelityCost: Int
    public var risks: [String]

    public init(strategy: StrategyID, orientation: Orientation, bodyXHeightMM: Double?, smallestXHeightMM: Double?,
                screensPerSourcePage: Double, fidelityCost: Int, risks: [String] = []) {
        self.strategy = strategy
        self.orientation = orientation
        self.bodyXHeightMM = bodyXHeightMM
        self.smallestXHeightMM = smallestXHeightMM
        self.screensPerSourcePage = screensPerSourcePage
        self.fidelityCost = fidelityCost
        self.risks = risks
    }
}

public protocol AdaptationStrategy: Sendable {
    var id: StrategyID { get }
    func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate
    func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan
}
