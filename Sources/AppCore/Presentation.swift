import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import MiniKit
import PDFAnalysis

// Textos e mapeamentos da interface, fora do SwiftUI para serem testáveis.

public enum ExportNaming {
    /// "{título} — mini.pdf". Título do PDF quando presta; senão o nome do arquivo.
    public static func defaultFileName(title: String?, sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        var base = cleanTitle(title) ?? stem
        // "/" e ":" não podem ir para o nome no Finder.
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = stem.isEmpty ? "documento" : stem }
        if base.count > 200 { base = String(base.prefix(200)) }
        return "\(base) — mini.pdf"
    }

    /// Descarta títulos que são lixo de gerador ("Microsoft Word - x.docx", "untitled").
    static func cleanTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - "] where t.hasPrefix(prefix) {
            t.removeFirst(prefix.count)
        }
        let lower = t.lowercased()
        for ext in [".docx", ".doc", ".pptx", ".ppt", ".tex", ".dvi", ".pdf", ".odt", ".pages", ".indd"] where lower.hasSuffix(ext) {
            t.removeLast(ext.count)
            break
        }
        t = t.trimmingCharacters(in: .whitespaces)
        let junk: Set<String> = ["untitled", "sem título", "document", "documento", "unknown"]
        return t.isEmpty || junk.contains(t.lowercased()) ? nil : t
    }
}

/// Selo de aviso numa miniatura de página de saída.
public enum PageBadge: String, CaseIterable, Sendable, Comparable {
    case smallText, scaleException, emptyPage

    public var title: String {
        switch self {
        case .smallText: "Letra pequena"
        case .scaleException: "Exceção de escala"
        case .emptyPage: "Página vazia"
        }
    }

    /// SF Symbol do selo.
    public var symbol: String {
        switch self {
        case .smallText: "textformat.size.smaller"
        case .scaleException: "arrow.up.left.and.down.right.magnifyingglass"
        case .emptyPage: "doc"
        }
    }

    public static func < (a: PageBadge, b: PageBadge) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum PageBadges {
    /// Selos por página de saída (índice = página de saída).
    ///
    /// "Letra pequena" usa a altura-x da própria página de origem quando medida
    /// (página de notas, tabela em corpo menor), senão a do documento, e compara
    /// com o mínimo do perfil de legibilidade da receita.
    public static func compute(plan: LayoutPlan, analysis: DocumentAnalysis) -> [[PageBadge]] {
        var empty = Set<Int>(), exceptions = Set<Int>()
        for w in plan.warnings {
            switch w {
            case .emptyPage(let p): empty.insert(p)
            case .scaleException(let p, _, _): exceptions.insert(p)
            case .belowMinimumLegibility: break
            }
        }
        let minimum = plan.recipe.legibility.minimumMM
        let pages = Dictionary(analysis.pages.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        return plan.pages.map { out in
            var set = Set<PageBadge>()
            for p in out.placements {
                if empty.contains(p.sourcePage) { set.insert(.emptyPage) }
                if exceptions.contains(p.sourcePage) { set.insert(.scaleException) }
                guard let page = pages[p.sourcePage], page.inkBox != nil,
                      let body = page.bodyXHeightPt ?? analysis.bodyXHeightPt, body > 0 else { continue }
                if Legibility.finalXHeightMM(sourceXHeightPt: Double(body), scale: Double(p.scale)) < minimum {
                    set.insert(.smallText)
                }
            }
            return set.sorted()
        }
    }
}

public enum Labels {
    /// Ordem do seletor de modo; casos novos de `ConversionMode` (E3–E5) entram no fim
    /// com o nome da estratégia, sem precisar mexer aqui.
    static let modeOrder: [String] = ["auto", "crop", "aggressive", "passthrough"]
    static let modeNames: [String: String] = [
        "auto": "Automático", "crop": "Recorte", "aggressive": "Recorte sem cabeçalho/rodapé",
        "passthrough": "Passagem direta",
    ]

    public static var modes: [ConversionMode] {
        ConversionMode.allCases.sorted { a, b in
            let ia = modeOrder.firstIndex(of: a.rawValue) ?? Int.max, ib = modeOrder.firstIndex(of: b.rawValue) ?? Int.max
            return ia != ib ? ia < ib : a.rawValue < b.rawValue
        }
    }

    /// Modos do seletor: os de fatias e colunas só com a divisão de páginas permitida.
    public static func modes(allowSplitting: Bool) -> [ConversionMode] {
        modes.filter { allowSplitting || !$0.splitsPages }
    }

    /// Interruptor do inspetor e a linha que explica o custo.
    public static let allowSplittingTitle = "Permitir dividir páginas (fatias e colunas)"
    public static let allowSplittingFooter = "Cada página do original pode virar várias telas no iPad. Desligado, cada página do original vira exatamente uma tela."

    public static func mode(_ m: ConversionMode) -> String {
        if let n = modeNames[m.rawValue] { return n }
        return strategy(for: m).map(strategy) ?? m.rawValue
    }

    /// Estratégia que um modo força; `nil` para o automático.
    public static func strategy(for m: ConversionMode) -> StrategyID? {
        switch m.rawValue {
        case "auto": nil
        case "crop": .crop
        case "aggressive": .aggressiveCrop
        case "passthrough": .passthrough
        default: StrategyID(rawValue: m.rawValue) ?? StrategyID.allCases.first { "\($0)" == m.rawValue }
        }
    }

    /// Modo que força uma estratégia (clique na tabela de candidatos).
    public static func mode(forcing s: StrategyID) -> ConversionMode? {
        ConversionMode.allCases.first { strategy(for: $0) == s }
    }

    public static func strategy(_ s: StrategyID) -> String {
        s == .aggressiveCrop ? "Recorte sem cabeçalho/rodapé" : s.displayName
    }

    public static func classMode(_ c: PageClassMode) -> String {
        switch c {
        case .all: "Todas as páginas"
        case .oddEven: "Ímpares e pares"
        case .bySize: "Por tamanho de página"
        }
    }

    public static let classModes: [PageClassMode] = [.all, .oddEven, .bySize]

    public static func profile(_ p: ViewportProfile) -> String {
        let names: [String: String] = [
            "books.portrait.fullscreen": "Books · retrato",
            "books.landscape.fullscreen": "Books · paisagem",
            "fullscreen.portrait": "Tela cheia · retrato",
            "fullscreen.landscape": "Tela cheia · paisagem",
            "safearea.portrait": "Área segura · retrato",
        ]
        return names[p.id] ?? p.id
    }

    public static func tier(_ t: String) -> String {
        switch t {
        case "meetsTarget": "no alvo de conforto"
        case "meetsMinimum": "acima do mínimo, abaixo do alvo"
        case "belowMinimum": "abaixo do mínimo legível"
        default: t
        }
    }

    /// "Recorte · retrato: 9,4 pt, 1 tela", com o nome de modo da interface. A
    /// orientação distingue a mesma estratégia no perfil escolhido e no girado.
    public static func candidate(_ c: CandidateSummary) -> String {
        let body = c.bodyPointSizeEquivalent.map { "\(Describe.number($0)) pt" } ?? "? pt"
        let screens = Describe.number(c.screensPerSourcePage)
        let o = c.orientation == .portrait ? "retrato" : "paisagem"
        return "\(strategy(c.strategy)) · \(o): \(body), \(screens) \(c.screensPerSourcePage == 1 ? "tela" : "telas")"
    }

    public static func invariantStatus(_ s: InvariantStatus) -> String {
        switch s {
        case .passed: "ok"
        case .failed: "falha"
        case .notApplicable: "n/a"
        }
    }
}

/// Estado de um documento na fila.
public enum DocumentStatus: Sendable, Equatable {
    /// Na fila de análise, esperando vaga de processo filho (pastas grandes).
    case waiting
    case analyzing
    case ready
    case warnings(Int)
    case failed(String)
    case converting

    public var title: String {
        switch self {
        case .waiting: "Na fila"
        case .analyzing: "Analisando…"
        case .ready: "Pronto"
        case .warnings(let n): n == 1 ? "1 aviso" : "\(n) avisos"
        case .failed: "Falha"
        case .converting: "Exportando…"
        }
    }

    public var isFailure: Bool { if case .failed = self { true } else { false } }

    /// Estado depois da análise no processo filho.
    public static func after(_ r: Result<FullPlanReport, HelperError>) -> DocumentStatus {
        switch r {
        case .success(let report): settled(warnings: warningCount(report.planResult))
        case .failure(let e): .failed(e.message)
        }
    }

    public static func settled(warnings n: Int) -> DocumentStatus { n == 0 ? .ready : .warnings(n) }

    /// Avisos de análise + de plano + riscos do candidato escolhido.
    public static func warningCount(_ r: PlanResult) -> Int {
        AnalysisSummary(r.analysis).warnings.count + r.plan.warnings.count + r.chosen.risks.count
    }
}

/// Textos do sumário no inspetor.
public enum OutlineDisplay {
    /// "Sumário: 9 itens", "sem sumário na origem"; `nil` enquanto não se sabe.
    public static func source(_ count: Int?) -> String? {
        guard let count else { return nil }
        switch count {
        case 0: return "sem sumário na origem"
        case 1: return "Sumário: 1 item"
        default: return "Sumário: \(count) itens"
        }
    }

    /// "9 de 9 preservados".
    public static func preserved(_ n: NavigationSummary) -> String {
        n.sourceOutlineItems == 0 ? "sem sumário na origem" : "\(n.preservedOutlineItems) de \(n.sourceOutlineItems) preservados"
    }

    /// Contagens da exportação: o campo `navigation` do relatório ou, em relatório
    /// antigo, as métricas do invariante 5 — só se aprovado, porque reprovado não diz
    /// quantos itens ficaram no lugar.
    public static func counts(_ r: ConversionReport) -> NavigationSummary? {
        if let n = r.navigation { return n }
        guard let inv = r.validation?.result("5"), inv.status == .passed,
              let out = inv.metrics.first(where: { $0.name == "itens de sumário" }),
              let src = inv.metrics.first(where: { $0.name == "itens de sumário na origem" }) else { return nil }
        let s = Int(src.value), o = Int(out.value)
        let links = inv.metrics.first { $0.name == "links internos verificados" }.map { Int($0.value) } ?? 0
        return NavigationSummary(sourceOutlineItems: s, outputOutlineItems: o,
                                 preservedOutlineItems: s,
                                 sourceInternalLinks: links, outputInternalLinks: links)
    }
}
