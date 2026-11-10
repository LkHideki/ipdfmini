import CoreGraphics
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

// INC-22: fólio corrido ("10 | Chapter 1: Introduction", no pé da página O'Reilly) saía
// sozinho numa tela depois do corpo quando o corpo enchia as fatias anteriores.

@Suite struct FurnitureSliceTests {
    let recipe = Recipe()

    /// Página 6×9 com `blocks` parágrafos de 3 linhas (+ um de `extra` linhas) e um bloco
    /// `.headerFooter` de uma linha no pé (`footer`) ou no topo (senão).
    static func page(_ i: Int, blocks: Int, extra: Int, footer: Bool) -> PageAnalysis {
        var out: [Block] = []
        let furniture = Gen.text(left: 72, top: footer ? 54 : 626, width: 96, lines: 1, type: .headerFooter)
        if !footer { out.append(furniture) }
        var y: CGFloat = 600
        for k in 0..<(blocks + (extra > 0 ? 1 : 0)) {
            let b = Gen.text(left: 72, top: y, width: 324, lines: k < blocks ? 3 : extra)
            out.append(b)
            y = b.rect.minY - 10
        }
        if footer { out.append(furniture) }
        return Gen.page(i, size: Fx.book, blocks: out)
    }

    /// Varredura da altura do corpo: alguma combinação deixa o corpo encher as fatias
    /// exatamente, que é o caso do defeito.
    static func doc(footer: Bool) -> DocumentAnalysis {
        var pages: [PageAnalysis] = []
        for blocks in 1...12 { for extra in 0...3 { pages.append(page(pages.count, blocks: blocks, extra: extra, footer: footer)) } }
        return Fx.doc(pages)
    }

    /// Cada tela mostra corpo; a tela com o rodapé é a última da página e a com o cabeçalho, a
    /// primeira; o cabeçalho abre a primeira colocação.
    static func expectFurnitureNeverAlone(_ doc: DocumentAnalysis, _ plan: LayoutPlan, footer: Bool,
                                          tag: String) {
        for page in doc.pages {
            let furniture = page.blocks.filter { $0.type == .headerFooter }.map(\.rect)
            let body = page.blocks.filter { $0.type != .headerFooter }.map(\.rect)
            let outs = plan.pages.indices.filter { plan.pages[$0].placements.contains { $0.sourcePage == page.index } }
            for j in outs {
                let shown = plan.pages[j].placements.map(\.sourceRect)
                let hasBody = shown.contains { r in body.contains { r.intersection($0).height > 1e-6 } }
                #expect(hasBody, "\(tag) p. \(page.index + 1): tela \(j + 1) só com cabeçalho/rodapé")
            }
            for f in furniture {
                let at = outs.filter { plan.pages[$0].placements.contains { $0.sourceRect.containsApprox(f) } }
                #expect(at.count == 1, "\(tag) p. \(page.index + 1): cabeçalho/rodapé em \(at.count) telas")
                guard let j = at.first else { continue }
                #expect(j == (footer ? outs.last : outs.first), "\(tag) p. \(page.index + 1): fora da ponta da página")
                if !footer {
                    #expect(plan.pages[j].placements.first?.sourceRect.containsApprox(f) == true,
                            "\(tag) p. \(page.index + 1): cabeçalho não abre a tela")
                }
            }
        }
    }

    @Test(arguments: [true, false])
    func runningFurnitureNeverAloneOnAScreen(footer: Bool) {
        let doc = Self.doc(footer: footer)
        let runs: [(any AdaptationStrategy, ViewportProfile)] = [
            (PortraitSlicesStrategy(), .booksPortrait), (LandscapeSlicesStrategy(), .booksLandscape),
            (ColumnsStrategy(), .booksPortrait), (ColumnsStrategy(), .booksLandscape),
        ]
        var multi = 0
        for (s, p) in runs {
            let plan = s.plan(doc, p, recipe)
            checkSlicePlan(doc, plan)
            Self.expectFurnitureNeverAlone(doc, plan, footer: footer, tag: "\(s.id.rawValue) \(p.orientation)")
            multi += plan.pages.count - doc.pages.count
        }
        // Não vacuidade: as páginas se dividem (o caso só existe com várias telas).
        #expect(multi > 50, "\(multi)")
    }

    @Test func glueJoinsOnlyLeadingAndTrailingFurniture() {
        func u(_ y: CGFloat, _ f: Bool) -> SliceUnit {
            SliceUnit(rect: CGRect(x: 0, y: y, width: 10, height: 5), kind: .atomic, furniture: f)
        }
        let units = [u(100, true), u(80, false), u(60, false), u(40, true)]
        let groups = SliceUnits.groups(units)
        #expect(groups == [0..<1, 1..<2, 2..<3, 3..<4])
        #expect(SliceUnits.glueFurniture(groups, units) == [0..<2, 2..<4])
        // Só cabeçalho/rodapé na página: nada a colar.
        let only = [u(100, true), u(40, true)]
        #expect(SliceUnits.glueFurniture(SliceUnits.groups(only), only) == [0..<1, 1..<2])
    }
}
