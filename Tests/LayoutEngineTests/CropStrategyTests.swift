import CoreGraphics
import Foundation
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

@Suite struct CropStrategyTests {
    let profile = ViewportProfile.booksPortrait
    let recipe = Recipe()
    var v: CGSize { profile.sizePt }

    /// Invariantes de toda saída: tinta dentro, proporção, tamanho, cantos.
    func checkInvariants(_ doc: DocumentAnalysis, _ plan: LayoutPlan) {
        #expect(plan.pages.count == doc.pages.count)
        for (out, page) in zip(plan.pages, doc.pages) {
            #expect(out.sizePt == profile.sizePt)
            #expect(out.placements.count == 1)
            let p = out.placements[0]
            #expect(p.sourcePage == page.index)
            let w = p.sourceRect
            // Proporção = viewport ±0,1%.
            #expect(abs((w.height / w.width) / profile.aspect - 1) < 0.001)
            // Janela × escala = página de saída.
            #expect(abs(w.width * p.scale - v.width) < 1e-6)
            #expect(abs(w.height * p.scale - v.height) < 1e-6)
            if let ink = page.inkBox {
                #expect(w.containsApprox(ink), "tinta cortada na página \(page.index)")
                #expect(!LayoutChecks.inkTouchesCorners(ink: ink, window: w, scale: p.scale,
                                                        cornerRadius: profile.cornerRadiusPt),
                        "tinta no canto na página \(page.index)")
            }
        }
    }

    @Test func bookOddEvenScaleLockedPerClass() {
        let doc = Fx.bookDoc()
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(plan.exceptionPages.isEmpty)
        let odd = plan.placements.filter { $0.sourcePage % 2 == 0 }.map(\.scale)
        let even = plan.placements.filter { $0.sourcePage % 2 == 1 }.map(\.scale)
        // Variação de escala dentro da classe = 0 (igualdade exata).
        #expect(Set(odd).count == 1)
        #expect(Set(even).count == 1)
        // Mancha deslocada pela lombada: janela acompanha a margem mediana de cada classe.
        let w0 = plan.placement(0).sourceRect, w1 = plan.placement(1).sourceRect
        #expect(abs((w0.minX - w1.minX) - 18) < 1e-6)
        #expect(plan.recipe.strategy == .crop)
    }

    /// Tabela §2.3: mancha 324×518, 10 pt. Sem respiro a escala é 0,9662 (9,7 pt);
    /// com respiro de 2 mm (5,67 pt) cai para 0,9455 → corpo 9,45 pt, 1,568 mm de altura-x.
    /// Os cantos (9,5 pt) ficam livres pela folga lateral sem custo extra.
    @Test func matchesTable23() {
        let raw = CropMath.fit(ink: Fx.mancha, viewport: v, margin: 0, corner: 0, maxScale: 10).scale
        #expect(abs(raw - 0.9662) < 0.0005)

        let doc = Fx.doc((0..<4).map { Fx.page($0, ink: Fx.bookInk($0)) })
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        let r = Units.mmToPt(2)
        let expected = min(v.width / (324 + 2 * r), v.height / (518 + 2 * r))
        #expect(abs(expected - 0.94547) < 0.00005)
        #expect(plan.placements.allSatisfy { abs($0.scale - expected) < 1e-9 })

        let est = CropStrategy().estimate(doc, profile, recipe)
        let body = try! #require(est.bodyXHeightMM)
        #expect(abs(body - Double(Units.ptToMM(4.7 * expected))) < 1e-9)
        #expect(abs(body - 1.568) < 0.001)
        #expect(est.screensPerSourcePage == 1)
        #expect(est.fidelityCost == 1)
        #expect(est.orientation == .portrait)
        #expect(est.risks.isEmpty)
    }

    @Test func widePageDoesNotShrinkOthersAndBecomesException() {
        let base = Fx.bookDoc()
        var pages = base.pages
        pages[7] = Fx.page(7, ink: CGRect(x: 10, y: 65, width: 415, height: 518))   // nota marginal
        let doc = Fx.doc(pages)
        let plan = CropStrategy().plan(doc, profile, recipe)
        let basePlan = CropStrategy().plan(base, profile, recipe)
        checkInvariants(doc, plan)
        for i in doc.pages.indices where i != 7 {
            #expect(plan.placement(i).scale == basePlan.placement(i).scale)
        }
        #expect(plan.exceptionPages == [7])
        let warning = plan.warnings.first { if case .scaleException = $0 { true } else { false } }
        guard case .scaleException(_, let classScale, let pageScale) = warning else {
            Issue.record("sem aviso de exceção"); return
        }
        #expect(classScale == basePlan.placement(7).scale)
        #expect(pageScale < classScale)
        #expect(abs(plan.placement(7).scale - pageScale) < 1e-12)
    }

    @Test func shortChapterEndAlignedByTop() {
        var pages = Fx.bookDoc().pages
        pages[6] = Fx.page(6, ink: Fx.bookInk(6, height: 180))
        let doc = Fx.doc(pages)
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        let short = plan.placement(6).sourceRect, full = plan.placement(4).sourceRect
        #expect(short == full)
        #expect(plan.placement(6).scale == plan.placement(4).scale)
        // Topo da tinta à mesma distância do topo da janela que nas páginas cheias.
        #expect(abs((short.maxY - pages[6].inkBox!.maxY) - (full.maxY - pages[4].inkBox!.maxY)) < 1e-9)
    }

    @Test func landscapePlateGetsOwnClass() {
        let base = Fx.bookDoc()
        var pages = base.pages
        let land = CGSize(width: 648, height: 432)
        pages[5] = Fx.page(5, size: land, ink: CGRect(x: 40, y: 40, width: 560, height: 350))
        let doc = Fx.doc(pages)
        let basePlan = CropStrategy().plan(base, profile, recipe)
        for mode in [PageClassMode.oddEven, .bySize] {
            let r = Recipe(classMode: mode)
            let plan = CropStrategy().plan(doc, profile, r)
            checkInvariants(doc, plan)
            #expect(plan.exceptionPages.isEmpty, "modo \(mode)")
            for i in doc.pages.indices where i != 5 {
                #expect(plan.placement(i).scale == basePlan.placement(i).scale)
            }
            #expect(plan.placement(5).scale < plan.placement(4).scale)
        }
        // Em .bySize as duas paridades do miolo dividem uma classe: escala única.
        let bySize = CropStrategy().plan(doc, profile, Recipe(classMode: .bySize))
        #expect(Set(doc.pages.indices.filter { $0 != 5 }.map { bySize.placement($0).scale }).count == 1)
        #expect(PageClassifier.classes(doc, mode: .oddEven).count == 3)
        #expect(PageClassifier.classes(doc, mode: .bySize).count == 2)
        // Numa classe só, a prancha não puxa a escala do livro: vira exceção.
        let all = CropStrategy().plan(doc, profile, Recipe(classMode: .all))
        checkInvariants(doc, all)
        #expect(all.exceptionPages == [5])
    }

    @Test func rotatedPagesWithOffsetOrigin() {
        let origin = CGPoint(x: 100, y: 200)
        let n = 6
        let doc = Fx.doc((0..<n).map { i in
            Fx.page(i, origin: origin, rotation: i % 2 == 0 ? 90 : 270, ink: Fx.bookInk(i, origin: origin))
        })
        #expect(doc.pages[0].pageBox == CGRect(origin: origin, size: Fx.book))
        let base = Fx.doc((0..<n).map { Fx.page($0, ink: Fx.bookInk($0)) })
        let plan = CropStrategy().plan(doc, profile, recipe)
        let basePlan = CropStrategy().plan(base, profile, recipe)
        checkInvariants(doc, plan)
        for i in 0..<n {
            let w = plan.placement(i).sourceRect, b = basePlan.placement(i).sourceRect
            #expect(abs(w.minX - (b.minX + origin.x)) < 1e-9)
            #expect(abs(w.minY - (b.minY + origin.y)) < 1e-9)
            #expect(plan.placement(i).scale == basePlan.placement(i).scale)
            #expect(doc.pages[i].pageBox.containsApprox(w))
        }
    }

    /// Mancha com a proporção exata do viewport: o respiro de 2 mm deixa tinta
    /// nos cantos (R/s ≈ 9 pt > 5,67 pt), então o respiro de uma dimensão cresce.
    @Test func cornersForceLargerMargin() {
        let inkSize = CGSize(width: 300, height: 300 * MiniPage.aspect)
        let r = Units.mmToPt(2), R = profile.cornerRadiusPt
        let base = min(v.width / (inkSize.width + 2 * r), v.height / (inkSize.height + 2 * r))
        // Com a escala base, as folgas não chegam a R/s em nenhuma dimensão.
        #expect(r * base < R)
        let sx = min(base, (v.width - 2 * R) / inkSize.width)
        let sy = min(base, (v.height - 2 * R) / inkSize.height)
        let expected = max(sx, sy)
        #expect(expected < base)

        let doc = Fx.doc((0..<4).map { i in
            Fx.page(i, ink: CGRect(x: 60, y: 80, width: inkSize.width, height: inkSize.height))
        })
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(plan.placements.allSatisfy { abs($0.scale - expected) < 1e-9 })
    }

    @Test func maxScaleRespected() {
        let doc = Fx.doc((0..<3).map { Fx.page($0, ink: CGRect(x: 150, y: 250, width: 100, height: 150)) })
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(plan.placements.allSatisfy { $0.scale == recipe.maxScale })
        let tight = CropStrategy().plan(doc, profile, Recipe(maxScale: 1.2))
        checkInvariants(doc, tight)
        #expect(tight.placements.allSatisfy { $0.scale == 1.2 })
    }

    @Test func pointRoundTrip() {
        let doc = Fx.doc((0..<4).map { i in
            Fx.page(i, origin: CGPoint(x: 37.5, y: -12), rotation: 90 * i, ink: Fx.bookInk(i, origin: CGPoint(x: 37.5, y: -12)))
        })
        let plan = CropStrategy().plan(doc, profile, recipe)
        for p in plan.placements {
            let w = p.sourceRect
            for pt in [CGPoint(x: w.minX, y: w.minY), CGPoint(x: w.midX + 3.3, y: w.maxY - 17.1), CGPoint(x: w.maxX, y: w.maxY)] {
                let out = pt.applying(p.transform)
                let back = out.applying(p.transform.inverted())
                #expect(hypot(back.x - pt.x, back.y - pt.y) < 0.01)
                #expect(out.x >= -1e-6 && out.x <= v.width + 1e-6 && out.y >= -1e-6 && out.y <= v.height + 1e-6)
            }
            let corner = CGPoint(x: w.maxX, y: w.maxY).applying(p.transform)
            #expect(abs(corner.x - v.width) < 1e-6 && abs(corner.y - v.height) < 1e-6)
        }
    }

    @Test func emptyPagesUseClassWindowAndWarn() {
        var pages = Fx.bookDoc().pages
        pages[2] = Fx.page(2, ink: nil)
        pages[3] = Fx.page(3, ink: nil)
        let doc = Fx.doc(pages)
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(plan.warnings.contains(.emptyPage(page: 2)))
        #expect(plan.warnings.contains(.emptyPage(page: 3)))
        #expect(plan.placement(2).sourceRect == plan.placement(0).sourceRect)
        #expect(plan.placement(3).sourceRect == plan.placement(1).sourceRect)
        #expect(plan.placement(2).scale == plan.placement(0).scale)
    }

    @Test func windowMayExceedSmallPage() {
        // Página menor que a janela: área em branco, tinta inteira.
        let small = CGSize(width: 200, height: 260)
        let doc = Fx.doc((0..<2).map { Fx.page($0, size: small, ink: CGRect(x: 5, y: 5, width: 190, height: 250)) })
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(!doc.pages[0].pageBox.contains(plan.placement(0).sourceRect))
    }

    @Test func skewedScanPageRealigned() {
        // Página com a mancha deslocada 20 pt (scan torto) segue a própria tinta.
        var pages = Fx.bookDoc().pages
        pages[8] = Fx.page(8, ink: Fx.bookInk(8).offsetBy(dx: 20, dy: 0))
        let doc = Fx.doc(pages)
        let plan = CropStrategy().plan(doc, profile, recipe)
        checkInvariants(doc, plan)
        #expect(plan.exceptionPages.isEmpty)
        #expect(abs(plan.placement(8).sourceRect.minX - plan.placement(6).sourceRect.minX - 20) < 1e-9)
    }

    @Test func estimateWithoutXHeightRecordsRisk() {
        let pages = (0..<4).map { Fx.page($0, ink: Fx.bookInk($0), body: nil) }
        let est = CropStrategy().estimate(Fx.doc(pages, body: nil), profile, recipe)
        #expect(est.bodyXHeightMM == nil)
        #expect(!est.risks.isEmpty)
    }

    @Test func estimateFlagsManyExceptions() {
        let pages = (0..<10).map { i in
            Fx.page(i, ink: i < 3 ? CGRect(x: 5, y: 65, width: 422, height: 518) : Fx.bookInk(i))
        }
        // Com p95, 3 largas em 10 já são a referência; p50 as torna exceções (30% > 10%).
        let est = CropStrategy().estimate(Fx.doc(pages), profile, Recipe(classMode: .all, referencePercentile: 0.5))
        #expect(est.risks.contains { $0.contains("exceções") })
    }

    @Test func classifierBasics() {
        let doc = Fx.bookDoc(6)
        #expect(PageClassifier.classes(doc, mode: .all) == [[0, 1, 2, 3, 4, 5]])
        #expect(PageClassifier.classes(doc, mode: .oddEven) == [[0, 2, 4], [1, 3, 5]])
        #expect(PageClassifier.classes(doc, mode: .bySize) == [[0, 1, 2, 3, 4, 5]])
        // Variação de 1% no tamanho (scan) não separa classe.
        #expect(PageClassifier.similar(CGSize(width: 432, height: 648), CGSize(width: 436, height: 654)))
        #expect(!PageClassifier.similar(CGSize(width: 432, height: 648), Fx.a4))
        #expect(Stats.lowerPercentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 100], 0.95) == 9)
        // classe pequena demais para descartar outlier: vale o máximo
        #expect(Stats.lowerPercentile([300, 518], 0.95) == 518)
        #expect(Stats.lowerPercentile([1, 2, 3, 100], 0.95) == 100)
    }
}
