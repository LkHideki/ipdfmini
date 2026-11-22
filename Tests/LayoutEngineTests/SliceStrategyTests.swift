import CoreGraphics
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

func ptEquivalent(_ mm: Double?) -> Double { Legibility.pointSizeEquivalent(xHeightMM: mm ?? 0) }

@Suite struct SliceStrategyTests {
    let recipe = Recipe()
    let portrait = ViewportProfile.booksPortrait
    let landscape = ViewportProfile.booksLandscape

    /// Propriedade: em 144 páginas aleatórias (semente fixa), nenhuma
    /// unidade cortada nem repetida, tinta toda coberta, ordem de leitura, proporção,
    /// nada fora da página nem nos cantos — em E3, E4 e E5 nas duas orientações.
    @Test func randomPagesNeverCutUnits() {
        var rng = SplitMix64(seed: 0x1D_F00D)
        var units = 0, stacked = 0, reduced = 0, multiSlice = 0
        for d in 0..<24 {
            let doc = Fx.doc((0..<6).map { Gen.randomPage($0, &rng) })
            units += doc.pages.reduce(0) { $0 + inkUnits($1).count }
            let runs: [(any AdaptationStrategy, ViewportProfile)] = [
                (LandscapeSlicesStrategy(), landscape), (PortraitSlicesStrategy(), portrait),
                (ColumnsStrategy(), portrait), (ColumnsStrategy(), landscape),
            ]
            for (s, p) in runs {
                let plan = s.plan(doc, p, recipe)
                #expect(plan.profile == p, "doc \(d) \(s.id)")
                #expect(plan.recipe.strategy == s.id)
                checkSlicePlan(doc, plan)
                if s.id == .columns { stacked += plan.pages.count { Set($0.placements.map(\.sourceRect.minX)).count > 1 } }
                reduced += plan.warnings.count { if case .scaleException = $0 { true } else { false } }
                multiSlice += plan.pages.count - doc.pages.count
            }
        }
        // Não vacuidade: o gerador exercita empilhamento, unidade maior que a tela e fatias.
        #expect(units > 5000)
        #expect(stacked > 50)
        #expect(reduced > 20)
        #expect(multiSlice > 200)
    }

    /// A4 com mancha 451 × 698 em paisagem: a escala é 1,110 → 11,1 pt e
    /// 2,36 telas sem respiro. Com respiro de 2 mm: (500,47 − 11,34)/451 = 1,0845
    /// → 10,85 pt. Altura útil 328,64 − 2·9,5 (cantos: a mancha encosta nas laterais)
    /// = 309,6 pt → 698·1,0845/309,6 = 2,44 telas contínuas; como cada página de
    /// origem começa tela nova, o plano real usa 3 telas por página.
    @Test func a4LandscapeMatchesTable23() {
        let lead = (698 - Gen.lineInk) / 57
        let doc = Fx.doc((0..<4).map { i -> PageAnalysis in
            var blocks: [Block] = []
            var y: CGFloat = 770, k = 0
            for len in [8, 12, 9, 10, 7, 12] where k < 58 {
                let m = min(len, 58 - k)
                blocks.append(Gen.text(left: 72, top: y, width: 451, lines: m, leading: lead))
                y -= CGFloat(m) * lead
                k += m
            }
            return Gen.page(i, blocks: blocks)
        })
        #expect(abs(doc.pages[0].inkBox!.width - 451) < 1e-9 && abs(doc.pages[0].inkBox!.height - 698) < 1e-9)
        let est = LandscapeSlicesStrategy().estimate(doc, landscape, recipe)
        let scale = (500.47 - 2 * Units.mmToPt(2)) / 451
        #expect(abs(scale - 1.0845) < 0.0001)
        #expect(abs(est.bodyXHeightMM! - Double(Units.ptToMM(4.7 * scale))) < 1e-9)
        #expect(abs(ptEquivalent(est.bodyXHeightMM) - 10.85) < 0.01)
        #expect(est.screensPerSourcePage == 3)
        #expect(est.orientation == .landscape)
        #expect(est.fidelityCost == 3)
        let plan = LandscapeSlicesStrategy().plan(doc, landscape, recipe)
        checkSlicePlan(doc, plan)
        #expect(plan.pages.count == 12)
        // Indicador "p. 1 · 2/3": página original e fatia.
        let texts = plan.pages.compactMap { o in
            o.overlays.compactMap { if case .pageIndicator(let t, _) = $0 { t } else { nil } }.first
        }
        #expect(texts.prefix(4) == ["p. 1 · 1/3", "p. 1 · 2/3", "p. 1 · 3/3", "p. 2 · 1/3"])
        #expect(!plan.warnings.contains { if case .belowMinimumLegibility = $0 { true } else { false } })
    }

    /// Artigo em 2 colunas (Letter, colunas 252 × 665, corpo 10 pt) no E5 retrato.
    /// escala = min(Vw/larguraColuna, alvo/alturaX) = min(1,259; 1,60 mm/4,7 pt
    /// = 0,965) → 9,65 pt (o alvo). A estimativa antiga (1,10 "teto" → 11 pt, 1,46 tela/coluna)
    /// não sai da fórmula de fatiamento com alvo de 1,60 mm: 11 pt pediria alvo ≈ 1,82 mm.
    /// Telas: coluna de 665·0,965 = 641,7 pt em altura útil de 485,8 pt (1,32 contínua);
    /// com o fim da coluna 1 e o começo da 2 empilhados, 3 telas por página = 1,5 por coluna.
    @Test func twoColumnArticleColumnsMatchTable23() {
        let doc = Gen.twoColumnArticle()
        let est = ColumnsStrategy().estimate(doc, portrait, recipe)
        let pt = ptEquivalent(est.bodyXHeightMM)
        #expect(pt >= 9.5)
        #expect(abs(pt - 9.65) < 0.01)
        #expect(est.bodyXHeightMM! >= recipe.legibility.targetMM)
        #expect(est.screensPerSourcePage == 3)
        #expect(est.screensPerSourcePage / 2 == 1.5)
        #expect(est.risks.isEmpty, "\(est.risks)")
        let plan = ColumnsStrategy().plan(doc, portrait, recipe)
        checkSlicePlan(doc, plan)
        // Cada coluna em sua(s) colocação(ões), coluna 0 antes da 1, mesma escala.
        let first = plan.placements.filter { $0.sourcePage == 0 }
        #expect(first.count == 4)
        #expect(first.allSatisfy { abs($0.scale - first[0].scale) < 1e-12 })
        #expect(first.map { $0.sourceRect.minX < 300 } == [true, true, false, false])
        // Empilhamento: a 2ª tela tem o fim da coluna 0 e o começo da 1.
        #expect(plan.pages[1].placements.count == 2)
        // Colunas na mesma x de saída em todas as páginas.
        let xs = Set(plan.placements.map { ($0.sourceRect.applying($0.transform).minX * 1e6).rounded() })
        #expect(xs.count == 1)
    }

    /// com E1 abaixo do mínimo, a decisão fica com E5 em retrato (E3 reduz a
    /// seção de colunas inteira; E4 encolhe pela largura). E5 em paisagem empata em
    /// legibilidade e custo e perde por telas por página.
    @Test func decisionChoosesColumnsForTwoColumnArticle() {
        let doc = Gen.twoColumnArticle(title: true)
        let engine = DecisionEngine(strategies: [PassthroughStrategy(), CropStrategy(), LandscapeSlicesStrategy(),
                                                 PortraitSlicesStrategy(), ColumnsStrategy()],
                                    profiles: [portrait, landscape])
        let (d, plan) = engine.plan(doc, recipe: recipe)!
        #expect(d.chosen.strategy == .columns)
        #expect(d.chosen.estimate.orientation == .portrait)
        #expect(d.tier == .meetsTarget)
        #expect(d.candidates.count == 10)
        let e1 = d.candidates.first { $0.strategy == .crop && $0.profile == portrait }!.estimate
        #expect(e1.bodyXHeightMM! < recipe.legibility.minimumMM)
        let e3 = d.candidates.first { $0.strategy == .landscapeSlices && $0.profile == landscape }!.estimate
        #expect(e3.bodyXHeightMM! < recipe.legibility.minimumMM)
        #expect(e3.risks.contains { $0.contains("seções em colunas") })
        let e5l = d.candidates.first { $0.strategy == .columns && $0.profile == landscape }!.estimate
        #expect(e5l.screensPerSourcePage > d.chosen.estimate.screensPerSourcePage)
        #expect(plan.recipe.strategy == .columns)
        checkSlicePlan(doc, plan)
        // Título (largura total) primeiro, com escala própria limitada ao teto.
        let title = plan.placements[0]
        #expect(title.sourceRect.containsApprox(doc.pages[0].blocks[0].rect))
        #expect(title.scale <= plan.placements[1].scale + 1e-12)
    }

    /// Figura mais alta que a tela (350 pt contra ≈ 285 pt úteis no E3): página
    /// própria, reduzida para caber, entre o texto de antes e o de depois.
    @Test func tallFigureGetsOwnReducedPage() {
        let p1 = Gen.text(left: 72, top: 770, width: 451, lines: 10)
        let fig = Gen.atomic(CGRect(x: 72, y: p1.rect.minY - 8 - 350, width: 451, height: 350))
        let p2 = Gen.text(left: 72, top: fig.rect.minY - 8, width: 451, lines: 10)
        let doc = Fx.doc([Gen.page(0, blocks: [p1, fig, p2])])
        let plan = LandscapeSlicesStrategy().plan(doc, landscape, recipe)
        checkSlicePlan(doc, plan)
        let (out, p) = plan.indexedPlacements.first { $0.placement.sourceRect.containsApprox(fig.rect) }!
        #expect(plan.pages[out].placements.count == 1)
        let g = SliceGeometry(landscape, recipe)
        let room = landscape.sizePt.height - 2 * max(g.margin, g.corner)
        #expect(abs(p.scale - room / 350) < 1e-9)
        #expect(p.scale < (500.47 - 2 * g.margin) / 451)
        #expect(out > 0 && out < plan.pages.count - 1)
        #expect(plan.warnings.contains { if case .scaleException(0, _, let s) = $0 { abs(s - p.scale) < 1e-9 } else { false } })
        let est = LandscapeSlicesStrategy().estimate(doc, landscape, recipe)
        #expect(!est.risks.contains { $0.contains("sobreposição") })
    }

    /// Último recurso: figura que encolheria abaixo de metade da escala é fatiada
    /// com 10% de sobreposição e marca de continuidade.
    @Test func veryTallFigureOverlapsWithContinuityMark() {
        let fig = Gen.atomic(CGRect(x: 72, y: 70, width: 451, height: 700))
        let doc = Fx.doc([Gen.page(0, blocks: [fig])])
        let plan = LandscapeSlicesStrategy().plan(doc, landscape, recipe)
        checkSlicePlan(doc, plan, allowOverlap: true)
        let rects = plan.placements.map(\.sourceRect)
        #expect(rects.count == 3)
        let g = SliceGeometry(landscape, recipe)
        let h = g.capacity(false) / plan.placements[0].scale
        for k in 1..<rects.count {
            #expect(abs((rects[k - 1].minY - rects[k].maxY) + 0.1 * h) < 1e-6)
            #expect(plan.pages[k].overlays.contains { if case .continuityMark = $0 { true } else { false } })
        }
        #expect(!plan.pages[0].overlays.contains { if case .continuityMark = $0 { true } else { false } })
        #expect(abs(rects.first!.maxY - fig.rect.maxY) < 1e-9 && abs(rects.last!.minY - fig.rect.minY) < 1e-9)
        #expect(LandscapeSlicesStrategy().estimate(doc, landscape, recipe).risks.contains { $0.contains("sobreposição") })
    }

    /// Fatia não termina com a 1ª linha de um parágrafo sozinha nem com título,
    /// mesmo quando caberia mais uma linha.
    @Test func dpAvoidsOrphanAndHeadingAtEnd() {
        let g = SliceGeometry(portrait, recipe)
        let s = (portrait.sizePt.width - 2 * g.margin) / 451
        let capSrc = g.capacity(false) / s
        let fit = Int(((capSrc - Gen.lineInk) / Gen.leading).rounded(.down)) + 1
        func lines(_ blocks: [Block]) -> PageAnalysis { Gen.page(0, size: CGSize(width: 595, height: 1400), blocks: blocks) }
        // Parágrafo de fit−1 linhas + outro de 10: o guloso levaria a 1ª linha do segundo.
        let a = Gen.text(left: 72, top: 1300, width: 451, lines: fit - 1)
        let b = Gen.text(left: 72, top: 1300 - CGFloat(fit - 1) * Gen.leading, width: 451, lines: 10)
        let orphan = Fx.doc([lines([a, b])])
        let plan = PortraitSlicesStrategy().plan(orphan, portrait, recipe)
        checkSlicePlan(orphan, plan)
        #expect(plan.pages.count == 2)
        #expect(abs(plan.pages[0].placements[0].sourceRect.minY - a.rect.minY) < 1e-9)

        // fit−2 linhas, título de 1 linha, parágrafo: o título desce para a fatia seguinte.
        let c = Gen.text(left: 72, top: 1300, width: 451, lines: fit - 2)
        let h = Gen.text(left: 72, top: 1300 - CGFloat(fit - 2) * Gen.leading, width: 300, lines: 1, type: .heading)
        let d = Gen.text(left: 72, top: 1300 - CGFloat(fit - 1) * Gen.leading, width: 451, lines: 10)
        let heading = Fx.doc([lines([c, h, d])])
        let plan2 = PortraitSlicesStrategy().plan(heading, portrait, recipe)
        checkSlicePlan(heading, plan2)
        #expect(plan2.pages.count == 2)
        #expect(abs(plan2.pages[0].placements[0].sourceRect.minY - c.rect.minY) < 1e-9)
        #expect(plan2.pages[1].placements[0].sourceRect.containsApprox(h.rect))
    }

    /// Sem blocos: E3/E4 fatiam pelas linhas (resto da tinta atômico); E5 inaplicável.
    @Test func withoutBlocksFallsBackToLines() {
        let src = Gen.page(0, blocks: [Gen.text(left: 72, top: 770, width: 451, lines: 50)])
        var page = src
        page.blocks = []
        // Tinta além das linhas (figura sem linha) entra como faixa atômica.
        page.inkBox = src.inkBox!.union(CGRect(x: 72, y: 72, width: 451, height: 60))
        let doc = Fx.doc([page])
        for (s, p) in [(LandscapeSlicesStrategy() as any AdaptationStrategy, landscape), (PortraitSlicesStrategy(), portrait)] {
            let plan = s.plan(doc, p, recipe)
            checkSlicePlan(doc, plan)
            let ink = page.inkBox!
            #expect(plan.placements.contains { $0.sourceRect.minY <= ink.minY + 1e-9 })
            #expect(s.estimate(doc, p, recipe).risks.contains { $0.contains("sem segmentação") })
        }
        let e5 = ColumnsStrategy().estimate(doc, portrait, recipe)
        #expect(e5.bodyXHeightMM == nil && e5.smallestXHeightMM == nil)
        #expect(e5.risks.contains { $0.contains("inaplicável") })
    }

    /// E3 só em paisagem e E4 só em retrato: o candidato trocado se declara inaplicável
    /// e cai para o fim da regra, sem duplicar o da outra orientação.
    @Test func orientationMismatchIsInapplicable() {
        let doc = Gen.twoColumnArticle(pages: 1)
        let e3 = LandscapeSlicesStrategy().estimate(doc, portrait, recipe)
        #expect(e3.bodyXHeightMM == nil && e3.orientation == .portrait && !e3.risks.isEmpty)
        let e4 = PortraitSlicesStrategy().estimate(doc, landscape, recipe)
        #expect(e4.bodyXHeightMM == nil)
        // O plano direto usa o perfil girado.
        #expect(LandscapeSlicesStrategy().plan(doc, portrait, recipe).profile.orientation == .landscape)
    }

    /// Página vazia no meio: uma tela, inteira, com aviso; o resto segue normal.
    @Test func emptyPageKeepsItsScreen() {
        let a = Gen.page(0, blocks: [Gen.text(left: 72, top: 770, width: 451, lines: 20)])
        let empty = Fx.page(1, size: Fx.a4, ink: nil)
        let doc = Fx.doc([a, empty])
        let plan = PortraitSlicesStrategy().plan(doc, portrait, recipe)
        checkSlicePlan(doc, plan)
        #expect(plan.warnings.contains(.emptyPage(page: 1)))
        #expect(plan.placements.filter { $0.sourcePage == 1 }.count == 1)
    }
}
