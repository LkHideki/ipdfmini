import CoreGraphics
import MiniGeometry
import PDFAnalysis

// E3, E4 e E5. PLAN.md §7.

/// E3 — fatias em paisagem: a largura da mancha ocupa o lado maior.
/// Só se aplica a perfil paisagem; com perfil retrato a estimativa se declara
/// inaplicável (o candidato seria o E4) e o plano usa o perfil girado.
public struct LandscapeSlicesStrategy: AdaptationStrategy {
    public var id: StrategyID { .landscapeSlices }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        SlicePlanner.estimate(id, doc, profile, recipe, orientation: .landscape)
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        SlicePlanner.plan(id, doc, profile, recipe, orientation: .landscape)
    }
}

/// E4 — fatias em retrato, para manchas estreitas e altas. Só perfil retrato.
public struct PortraitSlicesStrategy: AdaptationStrategy {
    public var id: StrategyID { .portraitSlices }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        SlicePlanner.estimate(id, doc, profile, recipe, orientation: .portrait)
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        SlicePlanner.plan(id, doc, profile, recipe, orientation: .portrait)
    }
}

/// E5 — colunas: cada coluna vira fatias na ordem de leitura; blocos de largura
/// total com escala própria. Qualquer orientação.
public struct ColumnsStrategy: AdaptationStrategy {
    public var id: StrategyID { .columns }
    public init() {}

    public func estimate(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Estimate {
        SlicePlanner.estimate(id, doc, profile, recipe, orientation: nil)
    }

    public func plan(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> LayoutPlan {
        SlicePlanner.plan(id, doc, profile, recipe, orientation: nil)
    }
}

enum SlicePlanner {
    struct Run {
        var result: SliceResult
        var risks: [String]
        /// E5 sem nenhum bloco na análise.
        var applicable: Bool
    }

    static func effective(_ profile: ViewportProfile, _ o: Orientation?) -> ViewportProfile {
        guard let o, profile.orientation != o else { return profile }
        return profile.rotated
    }

    /// Escala que põe o corpo exatamente no alvo; folga numérica para que o
    /// corpo no alvo não caia uma faixa abaixo na regra por arredondamento.
    static func targetScale(_ doc: DocumentAnalysis, _ recipe: Recipe) -> CGFloat {
        guard let x = EstimateMath.bodyXHeightPt(doc) else { return .infinity }
        return CGFloat(Legibility.xHeightPt(fromMM: recipe.legibility.targetMM)) / x * (1 + 1e-9)
    }

    /// Escala que põe o corpo no máximo da §2.2 (1,90 mm): acima disso a página
    /// vira mais telas sem ganho de leitura. Sem isso o E3 de um livro 6×9 saía a
    /// 14 pt em 2,6 telas e o auto o preferia ao recorte.
    static func maximumScale(_ doc: DocumentAnalysis, _ recipe: Recipe) -> CGFloat {
        guard let x = EstimateMath.bodyXHeightPt(doc) else { return .infinity }
        return CGFloat(Legibility.xHeightPt(fromMM: recipe.legibility.maximumMM)) / x
    }

    static func run(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe) -> Run {
        let g = SliceGeometry(profile, recipe)
        return id == .columns ? columns(doc, profile, recipe, g) : flow(doc, profile, recipe, g)
    }

    /// E3/E4: escala travada por classe pela largura da mancha (como no E1).
    static func flow(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe, _ g: SliceGeometry) -> Run {
        var segs = [[SliceSegment]](repeating: [], count: doc.pages.count)
        for members in PageClassifier.classes(doc, mode: recipe.classMode) {
            let inks = members.compactMap { doc.pages[$0].usableInk }
            guard !inks.isEmpty else { continue }
            let refW = Stats.lowerPercentile(inks.map(\.width), recipe.referencePercentile)
            let left = Stats.median(inks.map(\.minX))
            let cap = min(recipe.maxScale, maximumScale(doc, recipe))
            let nominal = refW > 0 ? min(cap, g.usableWidth / refW) : cap
            for pos in members {
                let units = SliceUnits.flow(doc.pages[pos])
                guard !units.isEmpty else { continue }
                segs[pos] = [SliceSegment(units: units, nominal: nominal, anchor: (left, refW), isBody: true, geometry: g)]
            }
        }
        let result = SliceLayoutEngine.layout(doc, profile, g) { segs[$0] }
        var risks: [String] = []
        let noBlocks = doc.pages.count { $0.usableInk != nil && $0.blocks.isEmpty }
        if noBlocks > 0 { risks.append("sem segmentação em \(noBlocks) páginas: colunas não verificadas") }
        if result.reducedSections > 0 {
            risks.append("\(result.reducedSections) seções em colunas reduzidas para caber inteiras: use E5")
        }
        return Run(result: result, risks: risks, applicable: true)
    }

    /// E5: coluna a `min(Vw/larguraColuna, alvo/alturaX)`; largura total a
    /// `min(Vw/largura, teto)`, teto = `min(maxScale, alvo/alturaX)`.
    static func columns(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe, _ g: SliceGeometry) -> Run {
        let teto = min(recipe.maxScale, targetScale(doc, recipe))
        // Largura da coluna no documento todo: não depende da paridade, e a letra fica igual em todas as páginas.
        var widths: [CGFloat] = []
        for page in doc.pages { for r in columnRuns(page.blocks) { widths.append(hullWidth(page.blocks[r])) } }
        let colRef = widths.isEmpty ? nil : Stats.lowerPercentile(widths, recipe.referencePercentile)
        let colScale = colRef.map { $0 > 0 ? min(teto, g.usableWidth / $0) : teto } ?? teto

        var noBlocks = 0, noColumns = 0, withBlocks = 0
        var segs = [[SliceSegment]](repeating: [], count: doc.pages.count)
        for (pos, page) in doc.pages.enumerated() where page.usableInk != nil || !page.blocks.isEmpty {
            guard !page.blocks.isEmpty else {
                noBlocks += 1
                let u = SliceUnits.fallback(page)
                if !u.isEmpty { segs[pos] = [SliceSegment(units: u, nominal: teto, anchor: nil, isBody: true, geometry: g)] }
                continue
            }
            withBlocks += 1
            if !page.blocks.contains(where: { $0.column != nil }) { noColumns += 1 }
            var out: [SliceSegment] = []
            var i = 0
            let blocks = page.blocks
            while i < blocks.count {
                guard let col = blocks[i].column else {
                    out.append(SliceSegment(units: SliceUnits.units(of: blocks[i], index: i), nominal: teto,
                                            anchor: nil, isBody: false, geometry: g))
                    i += 1
                    continue
                }
                var j = i
                while j < blocks.count, blocks[j].column == col { j += 1 }
                let units = (i..<j).flatMap { SliceUnits.units(of: blocks[$0], index: $0) }
                let left = units.map(\.rect.minX).min()!
                out.append(SliceSegment(units: units, nominal: colScale, anchor: (left, colRef ?? 0), isBody: true,
                                        geometry: g))
                i = j
            }
            segs[pos] = out
        }
        let result = SliceLayoutEngine.layout(doc, profile, g) { segs[$0] }
        var risks: [String] = []
        let applicable = withBlocks > 0
        if !applicable { risks.append("análise sem blocos: E5 inaplicável") }
        else {
            if noBlocks > 0 { risks.append("colunas incertas: \(noBlocks) páginas sem blocos") }
            if noColumns > 0 { risks.append("colunas incertas: \(noColumns) páginas sem coluna") }
        }
        if let x = EstimateMath.bodyXHeightPt(doc) {
            let minPt = CGFloat(Legibility.xHeightPt(fromMM: recipe.legibility.minimumMM))
            let wide = result.records.count { !$0.isBody && $0.textLines > 0 && x * $0.scale < minPt }
            if wide > 0 { risks.append("\(wide) trechos de largura total abaixo do mínimo") }
        }
        return Run(result: result, risks: risks, applicable: applicable)
    }

    /// Faixas de blocos consecutivos da mesma coluna (não nil).
    static func columnRuns(_ blocks: [Block]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < blocks.count {
            guard let c = blocks[i].column else { i += 1; continue }
            var j = i
            while j < blocks.count, blocks[j].column == c { j += 1 }
            out.append(i..<j)
            i = j
        }
        return out
    }

    static func hullWidth(_ blocks: ArraySlice<Block>) -> CGFloat {
        (blocks.map(\.rect.maxX).max() ?? 0) - (blocks.map(\.rect.minX).min() ?? 0)
    }

    /// Escala em que o corpo aparece: mediana das escalas ponderada pelas linhas
    /// de texto de cada colocação (na falta de linhas, de todas as colocações).
    static func bodyScale(_ records: [SliceRecord]) -> CGFloat? {
        let text = records.filter { $0.textLines > 0 }
        let pool = text.isEmpty ? records.map { ($0.scale, 1) } : text.map { ($0.scale, $0.textLines) }
        guard !pool.isEmpty else { return nil }
        let sorted = pool.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        var acc = 0
        for (s, w) in sorted {
            acc += w
            if 2 * acc >= total { return s }
        }
        return sorted.last!.0
    }

    static func estimate(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                         orientation: Orientation?) -> Estimate {
        if let o = orientation, profile.orientation != o {
            return Estimate(strategy: id, orientation: profile.orientation, bodyXHeightMM: nil, smallestXHeightMM: nil,
                            screensPerSourcePage: 1, fidelityCost: id.fidelityCost,
                            risks: ["\(id.rawValue) só se aplica a perfil \(o == .landscape ? "paisagem" : "retrato")"])
        }
        return estimate(id, doc, profile, recipe, run: run(id, doc, profile, recipe))
    }

    static func estimate(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                         run: Run) -> Estimate {
        let res = run.result
        var risks = run.risks
        let body = EstimateMath.bodyXHeightPt(doc)
        let small = EstimateMath.smallestXHeightPt(doc)
        if body == nil { risks.append("sem altura-x do corpo na análise") }
        let minPt = CGFloat(Legibility.xHeightPt(fromMM: recipe.legibility.minimumMM))
        if let body {
            let atomic = res.records.count { $0.hasAtomic && body * $0.scale < minPt }
            if atomic > 0 { risks.append("\(atomic) colocações com bloco atômico reduzido abaixo do mínimo") }
        }
        if res.overlapPages > 0 { risks.append("sobreposição com marca de continuidade em \(res.overlapPages) telas") }
        let exceptions = res.warnings.count { if case .scaleException = $0 { true } else { false } }
        let inkPages = doc.pages.count { $0.usableInk != nil }
        if exceptions > 0, Double(exceptions) > EstimateMath.manyExceptionsFraction * Double(inkPages) {
            risks.append("muitas exceções de escala: \(exceptions) em \(inkPages) páginas")
        }
        let scale = run.applicable ? bodyScale(res.records) : nil
        let minText = res.records.filter { $0.textLines > 0 }.map(\.scale).min() ?? scale
        func mm(_ x: CGFloat?, _ s: CGFloat?) -> Double? {
            guard let x, let s else { return nil }
            return Legibility.finalXHeightMM(sourceXHeightPt: Double(x), scale: Double(s))
        }
        return Estimate(strategy: id, orientation: profile.orientation, bodyXHeightMM: mm(body, scale),
                        smallestXHeightMM: run.applicable ? mm(small, minText) : nil,
                        screensPerSourcePage: Double(res.pages.count) / Double(max(1, doc.pages.count)),
                        fidelityCost: id.fidelityCost, risks: risks)
    }

    static func plan(_ id: StrategyID, _ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                     orientation: Orientation?) -> LayoutPlan {
        let p = effective(profile, orientation)
        let r = run(id, doc, p, recipe)
        let est = estimate(id, doc, p, recipe, run: r)
        var warnings = r.result.warnings
        // §15.2.2: pior trecho do corpo, não só a mediana (seção reduzida, exceção).
        var worst = est.bodyXHeightMM
        if let body = EstimateMath.bodyXHeightPt(doc) {
            // Texto do tamanho do corpo fora do fluxo principal (resumo largo no E5) também avisa.
            for rec in r.result.records where (rec.isBody && rec.textLines > 0) || rec.bodySized {
                let mm = Legibility.finalXHeightMM(sourceXHeightPt: Double(body), scale: Double(rec.scale))
                worst = min(worst ?? mm, mm)
            }
        }
        if let mm = worst, mm < recipe.legibility.minimumMM { warnings.append(.belowMinimumLegibility(xHeightMM: mm)) }
        var rec = recipe
        rec.strategy = id
        return LayoutPlan(profile: p, pages: r.result.pages, recipe: rec, warnings: warnings)
    }
}
