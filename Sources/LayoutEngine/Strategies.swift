import CoreGraphics
import MiniGeometry
import PDFAnalysis

// E0 e E1. PLAN.md §7.

/// E0 — passagem direta: página inteira, expandida até a proporção do viewport.
public struct PassthroughStrategy: AdaptationStrategy {
    public var id: StrategyID { .passthrough }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        let groups = PageClassifier.sizeGroups(doc.pages)
        // Grupo de tamanho dominante: mais páginas com tinta (ou mais páginas, se nenhuma tem).
        var tally: [Int: (ink: Int, all: Int, first: Int)] = [:]
        for (pos, g) in groups.enumerated() {
            let t = tally[g] ?? (0, 0, pos)
            tally[g] = (t.ink + (doc.pages[pos].usableInk == nil ? 0 : 1), t.all + 1, t.first)
        }
        let dominant = tally.max { a, b in
            (a.value.ink, a.value.all, -a.value.first) < (b.value.ink, b.value.all, -b.value.first)
        }
        let scale = dominant.map {
            CropMath.passthroughWindow(pageBox: doc.pages[$0.value.first].pageBox, viewport: profile.sizePt,
                                       maxScale: recipe.maxScale).scale
        }
        var risks: [String] = []
        // E0 não mexe no recorte: só registra tinta que o canto arredondado esconderia.
        let cornerHits = doc.pages.count { page in
            guard let ink = page.usableInk else { return false }
            let w = CropMath.passthroughWindow(pageBox: page.pageBox, viewport: profile.sizePt, maxScale: recipe.maxScale)
            return LayoutChecks.inkTouchesCorners(ink: ink, window: w.window, scale: w.scale, cornerRadius: profile.cornerRadiusPt)
        }
        if cornerHits > 0 { risks.append("tinta nos cantos arredondados em \(cornerHits) de \(doc.pages.count) páginas") }
        return EstimateMath.make(id, profile, doc, scale: scale, risks: risks)
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        var warnings: [PlanWarning] = []
        let pages = doc.pages.map { page -> OutputPage in
            if page.usableInk == nil { warnings.append(.emptyPage(page: page.index)) }
            let w = CropMath.passthroughWindow(pageBox: page.pageBox, viewport: profile.sizePt, maxScale: recipe.maxScale)
            return OutputPage(sizePt: profile.sizePt, placements: [
                Placement(sourcePage: page.index, sourceRect: w.window,
                          transform: CropMath.transform(window: w.window, scale: w.scale)),
            ])
        }
        return EstimateMath.finish(id, doc, profile, recipe, pages: pages, warnings: warnings,
                                   estimate: estimate(doc, profile, recipe))
    }
}

/// E1 — recorte em retrato com escala travada por classe. PLAN.md §6.
public struct CropStrategy: AdaptationStrategy {
    public var id: StrategyID { .crop }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        CropPlanner.estimate(id, doc, profile, recipe, layout: CropLayoutEngine.compute(doc, profile, recipe))
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        CropPlanner.plan(id, doc, profile, recipe, layout: CropLayoutEngine.compute(doc, profile, recipe))
    }
}

/// E2 — recorte agressivo: E1 sem cabeçalho, rodapé e número de página. PLAN.md §7.
///
/// Mesmo motor do E1 sobre `bodyInkBox ?? inkBox`; bloco removido nunca fica
/// parcialmente dentro da janela (ver `CropFrame.avoiding`). O §7 pede o número
/// da página original como overlay discreto, mas o BoxWriter não desenha
/// overlays (`WriteWarning.overlaysIgnored`): não é emitido até o PlacementWriter (M3).
public struct AggressiveCropStrategy: AdaptationStrategy {
    public var id: StrategyID { .aggressiveCrop }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        let layout = CropLayoutEngine.compute(doc, profile, recipe, removeHeaderFooter: true)
        return CropPlanner.estimate(id, doc, profile, recipe, layout: layout, removing: Self.removingPages(doc))
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        let layout = CropLayoutEngine.compute(doc, profile, recipe, removeHeaderFooter: true)
        return CropPlanner.plan(id, doc, profile, recipe, layout: layout, removing: Self.removingPages(doc))
    }

    static func removingPages(_ doc: DocumentAnalysis) -> Int {
        doc.pages.count { $0.usableBodyInk != nil && !$0.removedHeaderFooter.isEmpty }
    }
}

/// Estimativa e plano comuns a E1 e E2.
enum CropPlanner {
    static func estimate(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                         layout: CropLayout, removing: Int? = nil) -> Estimate {
        var risks: [String] = []
        let inkPages = layout.inkCounts.reduce(0, +)
        let exceptions = layout.exceptionCount
        if inkPages == 0 { risks.append("nenhuma página com tinta") }
        if exceptions > 0, Double(exceptions) > EstimateMath.manyExceptionsFraction * Double(inkPages) {
            risks.append("muitas exceções de escala: \(exceptions) de \(inkPages) páginas")
        }
        if let removing {
            risks.append(removing == 0 ? "nenhum cabeçalho/rodapé detectado: igual ao recorte"
                                       : "remove cabeçalho/rodapé em \(removing) de \(doc.pages.count) páginas")
        }
        return EstimateMath.make(id, profile, doc, scale: layout.dominantScale, risks: risks)
    }

    static func plan(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                     layout: CropLayout, removing: Int? = nil) -> LayoutPlan {
        var warnings: [PlanWarning] = []
        let pages = layout.windows.map { w -> OutputPage in
            let page = doc.pages[w.position]
            switch w.kind {
            case .regular: break
            case .exception:
                let classScale = layout.frames[w.classIndex]?.scale ?? w.scale
                warnings.append(.scaleException(page: page.index, classScale: classScale, pageScale: w.scale))
            case .empty:
                warnings.append(.emptyPage(page: page.index))
            }
            return OutputPage(sizePt: profile.sizePt, placements: [
                Placement(sourcePage: page.index, sourceRect: w.window,
                          transform: CropMath.transform(window: w.window, scale: w.scale)),
            ])
        }
        return EstimateMath.finish(id, doc, profile, recipe, pages: pages, warnings: warnings,
                                   estimate: estimate(id, doc, profile, recipe, layout: layout, removing: removing))
    }
}

enum EstimateMath {
    /// Acima desta fração de páginas com tinta, exceções viram risco do candidato.
    static let manyExceptionsFraction = 0.10

    /// Altura-x do corpo: a do documento; sem ela, a mediana das páginas.
    static func bodyXHeightPt(_ doc: DocumentAnalysis) -> CGFloat? {
        if let b = doc.bodyXHeightPt, b > 0 { return b }
        let pages = doc.pages.compactMap(\.bodyXHeightPt).filter { $0 > 0 }
        return pages.isEmpty ? nil : Stats.median(pages)
    }

    static func smallestXHeightPt(_ doc: DocumentAnalysis) -> CGFloat? {
        doc.pages.compactMap(\.smallestXHeightPt).filter { $0 > 0 }.min()
    }

    static func make(_ id: StrategyID, _ profile: ViewportProfile, _ doc: DocumentAnalysis,
                     scale: CGFloat?, risks: [String]) -> Estimate {
        var risks = risks
        let body = bodyXHeightPt(doc)
        let small = smallestXHeightPt(doc)
        if body == nil { risks.append("sem altura-x do corpo na análise") }
        func mm(_ x: CGFloat?) -> Double? {
            guard let x, let scale else { return nil }
            return Legibility.finalXHeightMM(sourceXHeightPt: Double(x), scale: Double(scale))
        }
        return Estimate(strategy: id, orientation: profile.orientation, bodyXHeightMM: mm(body),
                        smallestXHeightMM: mm(small), screensPerSourcePage: 1,
                        fidelityCost: id.fidelityCost, risks: risks)
    }

    /// Fecha o plano: receita com a estratégia usada e aviso de legibilidade (§15.2.2).
    static func finish(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                       pages: [OutputPage], warnings: [PlanWarning], estimate: Estimate) -> LayoutPlan {
        var warnings = warnings
        // Pior página com tinta, não só a classe dominante: outra classe de tamanho
        // (prancha em paisagem, página girada) ou uma exceção pode ficar abaixo do
        // mínimo com a dominante acima, e o §15.2.2 exige o aviso nesse caso.
        var worst = estimate.bodyXHeightMM
        if let body = bodyXHeightPt(doc) {
            for out in pages {
                guard let p = out.placements.first, doc.pages.indices.contains(p.sourcePage),
                      doc.pages[p.sourcePage].usableInk != nil else { continue }
                let mm = Legibility.finalXHeightMM(sourceXHeightPt: Double(body), scale: Double(p.scale))
                worst = min(worst ?? mm, mm)
            }
        }
        if let mm = worst, mm < recipe.legibility.minimumMM {
            warnings.append(.belowMinimumLegibility(xHeightMM: mm))
        }
        var r = recipe
        r.strategy = id
        return LayoutPlan(profile: profile, pages: pages, recipe: r, warnings: warnings)
    }
}

enum LayoutChecks {
    /// Algum quadrado de canto (lado `cornerRadius` na saída) da janela contém tinta?
    static func inkTouchesCorners(ink: CGRect, window: CGRect, scale: CGFloat, cornerRadius: CGFloat) -> Bool {
        guard cornerRadius > 0, scale > 0 else { return false }
        let eps = 1e-6
        return window.cornerSquares(radius: cornerRadius / scale).contains { sq in
            let i = sq.intersection(ink)
            return !i.isNull && i.width > eps && i.height > eps
        }
    }
}
