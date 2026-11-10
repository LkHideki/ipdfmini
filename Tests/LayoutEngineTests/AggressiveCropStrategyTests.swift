import CoreGraphics
import Foundation
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

/// Página de livro com cabeçalho corrido `gap` pt acima do corpo e fólio 30 pt abaixo.
private func headedPage(_ i: Int, bodyHeight: CGFloat = Fx.mancha.height, gap: CGFloat = 18) -> PageAnalysis {
    let body = Fx.bookInk(i, height: bodyHeight)
    let header = CGRect(x: body.midX - 40, y: body.maxY + gap, width: 80, height: 8)
    let folio = CGRect(x: body.midX - 5, y: body.minY - 30, width: 10, height: 7)
    var p = Fx.page(i, ink: body.union(header).union(folio))
    p.bodyInkBox = body
    p.blocks = [header, folio].map { Block(rect: $0, type: .headerFooter, lines: []) }
    return p
}

/// Bloco removido inteiro fora ou inteiro dentro da janela, nunca cortado.
private func expectNeverPartial(_ doc: DocumentAnalysis, _ plan: LayoutPlan, sourceLocation: SourceLocation = #_sourceLocation) {
    for page in doc.pages {
        let w = plan.placement(page.index).sourceRect
        for b in page.removedHeaderFooter {
            let i = w.intersection(b)
            let outside = i.isNull || i.width < 1e-6 || i.height < 1e-6
            #expect(outside || w.containsApprox(b), "p. \(page.index): bloco \(b) cortado pela janela \(w)",
                    sourceLocation: sourceLocation)
        }
        if let body = page.bodyInkBox {
            #expect(w.containsApprox(body), "p. \(page.index): corpo cortado", sourceLocation: sourceLocation)
        }
    }
}

@Suite struct AggressiveCropStrategyTests {
    let profile = ViewportProfile.booksPortrait
    let recipe = Recipe(strategy: .aggressiveCrop)

    @Test func headersOutScaleLockedPerClassAndLargerThanE1() {
        let doc = Fx.doc((0..<20).map { headedPage($0) })
        let plan = AggressiveCropStrategy().plan(doc, profile, recipe)
        expectNeverPartial(doc, plan)
        #expect(plan.exceptionPages.isEmpty)
        #expect(plan.recipe.strategy == .aggressiveCrop)
        // Uma escala por classe ímpar/par.
        for parity in 0...1 {
            let scales = Set(plan.placements.filter { $0.sourcePage % 2 == parity }.map(\.scale))
            #expect(scales.count == 1, "classe \(parity): \(scales)")
        }
        // Cabeçalho e fólio totalmente fora em todas as páginas.
        for page in doc.pages {
            let w = plan.placement(page.index).sourceRect
            #expect(page.removedHeaderFooter.allSatisfy { !w.intersects($0) }, "p. \(page.index)")
            #expect(!LayoutChecks.inkTouchesCorners(ink: page.bodyInkBox!, window: w, scale: plan.placement(page.index).scale,
                                                    cornerRadius: profile.cornerRadiusPt))
        }
        let e1 = CropStrategy().plan(doc, profile, Recipe())
        #expect(plan.placement(0).scale > e1.placement(0).scale)
    }

    @Test func headerTooCloseToShortBodyIsLeftOutByShiftingTheWindow() {
        // Corpo curto, cabeçalho 4 pt acima (3 pt com a folga de 1 pt do bloco): a janela
        // da classe (topo + 5,7 pt de respiro) o cortaria; descer a janela até deixá-lo
        // fora mantém o respiro mínimo de 1 mm (2,83 pt) no corpo.
        var pages = (0..<10).map { headedPage($0) }
        pages[4] = headedPage(4, bodyHeight: 200, gap: 4)
        let doc = Fx.doc(pages)
        let plan = AggressiveCropStrategy().plan(doc, profile, recipe)
        expectNeverPartial(doc, plan)
        let w = plan.placement(4).sourceRect
        // O fólio do corpo curto cai inteiro dentro da janela (permitido); o cabeçalho sai.
        let header = doc.pages[4].removedHeaderFooter.max { $0.maxY < $1.maxY }!
        #expect(!w.intersects(header))
        #expect(!plan.exceptionPages.contains(4))
    }

    @Test func headerThatCannotBeLeftOutIsIncludedWhole() {
        // Corpo cheio, cabeçalho 3 pt acima: deixá-lo fora corta o respiro mínimo do
        // corpo e incluí-lo não cabe na janela da classe; entra inteiro (exceção).
        var pages = (0..<10).map { headedPage($0) }
        pages[4] = headedPage(4, gap: 3)
        let doc = Fx.doc(pages)
        let plan = AggressiveCropStrategy().plan(doc, profile, recipe)
        expectNeverPartial(doc, plan)
        let w = plan.placement(4).sourceRect
        let header = doc.pages[4].removedHeaderFooter.max { $0.maxY < $1.maxY }!
        #expect(w.containsApprox(header))
        #expect(w.containsApprox(doc.pages[4].inkBox!))
    }

    @Test func withoutBodyInkMatchesCrop() {
        let doc = Fx.bookDoc(8)
        let e2 = AggressiveCropStrategy().plan(doc, profile, recipe)
        let e1 = CropStrategy().plan(doc, profile, Recipe())
        #expect(e2.placements == e1.placements)
        #expect(AggressiveCropStrategy().estimate(doc, profile, recipe).risks.contains { $0.contains("nenhum cabeçalho") })
    }

    @Test func costOverrideLetsE2TieWithE1() {
        let doc = Fx.bookDoc(4)
        let e1 = FakeStrategy(.crop, portrait: 1.40), e2 = FakeStrategy(.aggressiveCrop, portrait: 1.50)
        // Sem pedido do usuário, E2 custa mais e perde na mesma faixa (mínimo).
        let plain = DecisionEngine(strategies: [e1, e2]).decide(doc, recipe: Recipe())!
        #expect(plain.chosen.strategy == .crop)
        // Com a remoção pedida, empata no custo e vence pela legibilidade.
        let asked = DecisionEngine(strategies: [e1, e2], costOverrides: [.aggressiveCrop: StrategyID.crop.fidelityCost])
            .decide(doc, recipe: Recipe())!
        #expect(asked.chosen.strategy == .aggressiveCrop)
    }
}
