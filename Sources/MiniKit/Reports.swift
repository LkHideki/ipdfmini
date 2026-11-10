import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFWriting

// Relatórios da fachada. Codable para `--json`; textos em português para a CLI e o app.

/// Resumo da análise para exibição (a análise completa vai em `PlanResult.analysis`).
public struct AnalysisSummary: Codable, Sendable, Equatable {
    public struct SizeGroup: Codable, Sendable, Equatable {
        public var size: CGSize
        public var pages: Int
    }

    public var kind: DocumentKind
    public var pageCount: Int
    /// Altura-x do corpo na origem (pt).
    public var bodyXHeightPt: Double?
    /// Corpo equivalente na origem, em escala 1:1 (altura-x / 0,47).
    public var bodyPointSizeEquivalent: Double?
    public var pageKinds: [String: Int]
    /// Tamanhos de página exibidos (com /Rotate), na ordem da primeira aparição.
    public var sizeGroups: [SizeGroup]
    /// Avisos da análise, já em texto, com o número da página (base 1).
    public var warnings: [String]

    public init(_ doc: DocumentAnalysis) {
        kind = doc.kind
        pageCount = doc.pageCount
        bodyXHeightPt = doc.bodyXHeightPt.map(Double.init)
        bodyPointSizeEquivalent = doc.bodyXHeightPt.map { Double($0) / Legibility.xHeightRatio }
        var kinds: [String: Int] = [:]
        var groups: [SizeGroup] = []
        var warnings: [String] = []
        for p in doc.pages {
            kinds[p.kind.rawValue, default: 0] += 1
            let s = p.pageBox.size
            if let i = groups.firstIndex(where: { abs($0.size.width - s.width) <= 1 && abs($0.size.height - s.height) <= 1 }) {
                groups[i].pages += 1
            } else {
                groups.append(SizeGroup(size: s, pages: 1))
            }
            warnings += p.warnings.map { "p. \(p.index + 1): \(Describe.analysisWarning($0))" }
        }
        pageKinds = kinds
        sizeGroups = groups
        self.warnings = warnings
    }
}

/// Um candidato da tabela do §8.
public struct CandidateSummary: Codable, Sendable, Equatable {
    public var strategy: StrategyID
    public var profileID: String
    public var orientation: Orientation
    public var bodyXHeightMM: Double?
    /// Corpo equivalente no vidro (pt).
    public var bodyPointSizeEquivalent: Double?
    public var smallestPointSizeEquivalent: Double?
    public var screensPerSourcePage: Double
    public var fidelityCost: Int
    /// "meetsTarget", "meetsMinimum" ou "belowMinimum".
    public var tier: String
    public var risks: [String]

    public init(_ c: Candidate, legibility: Legibility) {
        let e = c.estimate
        strategy = e.strategy
        profileID = c.profile.id
        orientation = e.orientation
        bodyXHeightMM = e.bodyXHeightMM
        bodyPointSizeEquivalent = e.bodyXHeightMM.map(Legibility.pointSizeEquivalent(xHeightMM:))
        smallestPointSizeEquivalent = e.smallestXHeightMM.map(Legibility.pointSizeEquivalent(xHeightMM:))
        screensPerSourcePage = e.screensPerSourcePage
        fidelityCost = e.fidelityCost
        tier = switch LegibilityTier(e.bodyXHeightMM, legibility) {
        case .meetsTarget: "meetsTarget"
        case .meetsMinimum: "meetsMinimum"
        case .belowMinimum: "belowMinimum"
        }
        risks = e.risks
    }

    /// "Recorte: 9,4 pt, 1 tela" (§8).
    public var line: String {
        let body = bodyPointSizeEquivalent.map { "\(Describe.number($0)) pt" } ?? "? pt"
        let screens = Describe.number(screensPerSourcePage)
        return "\(strategy.displayName): \(body), \(screens) \(screensPerSourcePage == 1 ? "tela" : "telas")"
    }
}

public struct PlanResult: Sendable, Equatable {
    public var analysis: DocumentAnalysis
    /// Na ordem da regra do §8.
    public var candidates: [CandidateSummary]
    public var chosenIndex: Int
    public var mode: ConversionMode
    public var plan: LayoutPlan

    public var chosen: CandidateSummary { candidates[chosenIndex] }
}

/// JSON de `plan --json`: sem a análise completa (essa sai em `analyze --json`).
public struct PlanReport: Codable, Sendable, Equatable {
    public var analysis: AnalysisSummary
    public var candidates: [CandidateSummary]
    public var chosenIndex: Int
    public var mode: ConversionMode
    public var plan: LayoutPlan

    public init(_ r: PlanResult) {
        analysis = AnalysisSummary(r.analysis)
        candidates = r.candidates
        chosenIndex = r.chosenIndex
        mode = r.mode
        plan = r.plan
    }
}

public struct ConversionReport: Codable, Sendable, Equatable {
    public var input: String
    public var output: String
    public var analysis: AnalysisSummary
    public var candidates: [CandidateSummary]
    public var chosenIndex: Int
    public var mode: ConversionMode
    public var plan: LayoutPlan
    public var write: WriteReport
    /// `nil` quando a validação foi desligada.
    public var validation: ValidationReport?

    public var chosen: CandidateSummary { candidates[chosenIndex] }
    /// Sem validação conta como aprovado: quem desligou assumiu o risco.
    public var passed: Bool { validation?.passed ?? true }
}

// MARK: - Textos

public extension StrategyID {
    /// Nome curto usado na tabela de candidatos (§8).
    var displayName: String {
        switch self {
        case .passthrough: "Passagem direta"
        case .crop: "Recorte"
        case .aggressiveCrop: "Recorte agressivo"
        case .landscapeSlices: "Paisagem"
        case .portraitSlices: "Fatias em retrato"
        case .columns: "Colunas"
        case .reflow: "Reflow"
        case .semantic: "Conversão semântica"
        }
    }
}

public enum Describe {
    /// Uma casa decimal, vírgula, sem ",0" (o padrão da tabela do §8).
    public static func number(_ x: Double, decimals: Int = 1) -> String {
        guard x.isFinite else { return "—" }
        var s = String(format: "%.\(decimals)f", x)
        if decimals > 0 {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    public static func size(_ s: CGSize) -> String { "\(number(Double(s.width))) × \(number(Double(s.height))) pt" }

    public static func documentKind(_ k: DocumentKind) -> String {
        switch k {
        case .book: "livro"
        case .twoColumnArticle: "artigo em duas colunas"
        case .a4Report: "relatório A4/Letter"
        case .slides: "slides"
        case .scannedBook: "livro escaneado"
        case .scannedSpread: "scan de página dupla"
        case .comics: "quadrinhos"
        case .sheetMusic: "partitura"
        case .form: "formulário"
        case .unknown: "desconhecido"
        }
    }

    public static func pageKind(_ k: String) -> String {
        switch PageKind(rawValue: k) {
        case .digitalText: "texto digital"
        case .scan: "scan"
        case .mixed: "misto"
        case .empty: "vazia"
        case nil: k
        }
    }

    public static func analysisWarning(_ w: AnalysisWarning) -> String {
        switch w {
        case .inkBoxDivergence(let d): "caixa de tinta diverge do texto em \(number(Double(d))) pt (fio, marca ou marca-d'água?)"
        case .ignoredRegion(_, let reason): "região ignorada no cálculo (\(reason))"
        case .renderFailed(let m): "falha de renderização: \(m)"
        case .noTextFound: "sem texto extraível"
        }
    }

    public static func planWarning(_ w: PlanWarning) -> String {
        switch w {
        case let .scaleException(page, classScale, pageScale):
            "p. \(page + 1): exceção de escala (\(number(Double(pageScale), decimals: 3)) contra \(number(Double(classScale), decimals: 3)) da classe)"
        case .belowMinimumLegibility(let mm):
            "corpo abaixo do mínimo de legibilidade: \(number(Legibility.pointSizeEquivalent(xHeightMM: mm))) pt equivalente"
        case .emptyPage(let page): "p. \(page + 1): página vazia"
        }
    }

    public static func writeWarning(_ w: WriteWarning) -> String {
        switch w {
        case let .aspectMismatch(page, err): "saída p. \(page + 1): proporção fora do viewport (\(number(err * 100, decimals: 3))%)"
        case .sizeBudgetExceeded(let r): "arquivo \(number(r, decimals: 2))× a origem (meta ≤ 1,1×)"
        case .overlaysIgnored(let n): "\(n) sobreposições ignoradas pelo BoxWriter"
        case .producerNotApplied: "campo Producer não gravado (xref não clássica)"
        }
    }
}
