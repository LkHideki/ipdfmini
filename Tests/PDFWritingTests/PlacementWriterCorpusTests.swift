import Foundation
import CoreGraphics
import PDFKit
import Testing
import MiniGeometry
import LayoutEngine
import SyntheticCorpus
@testable import PDFWriting

/// Planos reais (E3/E4/E5) sobre o corpus sintético, análise vinda da verdade.
@Suite struct PlacementWriterCorpusTests {
    /// Inv. 1b por colocação: a região de cada colocação na saída é, pixel a pixel, a
    /// janela de origem renderizada pelo CoreGraphics (rotação dele, não a nossa).
    @Test(arguments: CaseSpec.all)
    func everyPlacementRendersLikeItsSourceWindow(_ spec: CaseSpec) throws {
        let c = try spec.write()
        defer { c.cleanup() }
        let marks = c.plan.continuityMarks
        let diffs = comparePlacements(plan: c.plan, source: c.src, output: c.out,
                                      geometries: { c.analysis.pages[$0].geometry }, excluded: { marks[$0] ?? [] })
        #expect(diffs.count == c.plan.allPlacements.count)
        let refInk = diffs.reduce(0) { $0 + $1.referenceInk }
        #expect(refInk > 1000, "nada comparado")
        for d in diffs where !d.ok {
            Issue.record("\(c.name) saída p\(d.outputPage) colocação \(d.placement): ref \(d.referenceInk) px, saída \(d.outputInk) px, \(d.mismatched) px com |Δ| > \(PlacementDiff.grayTolerance), máx Δ \(d.maxGrayDelta)")
        }
        let worst = diffs.map(\.mismatched).max() ?? 0
        let delta = diffs.map(\.maxGrayDelta).max() ?? 0
        let flips = diffs.map { Double($0.thresholdFlips) / Double(max(1, $0.referenceInk)) }.max() ?? 0
        metric("pixels \(c.name) colocações=\(diffs.count) tintaRef=\(refInk) pixelsDiferentes=\(worst) maxΔcinza=\(delta) trocasNoLimiar=\(String(format: "%.2f", flips * 100))%")
    }

    /// Inv. 4, colocação a colocação: as palavras na área de cada colocação na saída
    /// (`selection(for:)`, geométrico) são as da janela de origem; somadas, cobrem o
    /// texto da origem, e o único excesso aceito são as palavras das regiões em que duas
    /// colocações da mesma página se sobrepõem (fatia de bloco atômico com marca de
    /// continuidade), que aparecem uma vez por colocação.
    ///
    /// Por que não `page.string` da página inteira: cada colocação desenha o Form
    /// XObject da página toda, e o clip só esconde. O PDFKit extrai parte do texto
    /// escondido (linhas vizinhas do mesmo parágrafo, a outra coluna), desenhado fora da
    /// área da colocação, onde pode cair dentro da área de outra colocação da mesma
    /// página de saída (E5 empilha fatias). Por isso, em página com várias colocações, a
    /// conferência por colocação usa um arquivo "explodido", gravado pelo mesmo escritor
    /// com uma colocação por página (mesmas matrizes e clips; o que muda é só a
    /// vizinhança). O vazamento é medido e reportado.
    @Test(arguments: CaseSpec.all)
    func textIsTheSourceWordMultiset(_ spec: CaseSpec) throws {
        let c = try spec.write()
        defer { c.cleanup() }
        let exploded = LayoutPlan(profile: c.plan.profile, pages: c.plan.allPlacements.map {
            OutputPage(sizePt: c.plan.pages[$0.out].sizePt, placements: [$0.placement])
        }, recipe: c.plan.recipe)
        let explodedURL = c.dir.appendingPathComponent("exploded.pdf")
        _ = try PlacementWriter().writeDetailed(exploded, source: SourceDocument(url: c.src), to: explodedURL,
                                                options: WriteOptions())
        let src = PDFDocument(url: c.src)!, out = PDFDocument(url: c.out)!, iso = PDFDocument(url: explodedURL)!
        var expected = Multiset(), visible = Multiset()
        for (k, (o, p)) in c.plan.allPlacements.enumerated() {
            let g = p.sourceGeometry ?? c.analysis.pages[p.sourcePage].geometry
            let want = Multiset(wordList(src.page(at: p.sourcePage)!.selection(for: g.toUser(p.sourceRect))?.string))
            let outRect = p.sourceRect.applying(p.transform).standardized
            let alone = c.plan.pages[o].placements.count == 1
            let page = alone ? out.page(at: o)! : iso.page(at: k)!
            let got = Multiset(wordList(page.selection(for: outRect)?.string))
            #expect(got == want, "\(c.name) saída p\(o)\(alone ? "" : " (explodido)") origem p\(p.sourcePage): faltam \(want.minus(got)); sobram \(got.minus(want))")
            expected.add(want)
            visible.add(got)
        }

        // Cobertura: tudo da origem está em alguma colocação; excesso só nas sobreposições.
        let source = Multiset(documentWords(c.src))
        var allowed = Multiset()
        var overlapRegions = 0
        for (s, page) in c.analysis.pages.enumerated() {
            let rects = c.plan.allPlacements.filter { $0.placement.sourcePage == s }.map(\.placement.sourceRect)
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let x = rects[i].intersection(rects[j])
                    guard !x.isNull, x.width > 0, x.height > 0 else { continue }
                    overlapRegions += 1
                    allowed.add(wordList(src.page(at: s)!.selection(for: page.geometry.toUser(x))?.string))
                }
            }
        }
        let missing = source.minus(expected), extra = expected.minus(source)
        #expect(missing.total == 0, "\(c.name): \(missing.total) palavras da origem fora de toda colocação: \(missing)")
        #expect(extra.isSubset(of: allowed), "\(c.name): palavras repetidas fora das sobreposições: \(extra.minus(allowed))")

        // Indicadores de página: texto real (Helvetica). Busca no texto da página: o
        // PDFKit pode fundir o indicador com texto escondido vizinho na mesma linha, e aí
        // `selection(for:)` na área dele volta vazio. A posição é provada por pixels.
        for (o, page) in c.plan.pages.enumerated() {
            for case let .pageIndicator(text, _) in page.overlays {
                let got = wordList(out.page(at: o)!.string).joined(separator: " ")
                #expect(got.contains(wordList(text).joined(separator: " ")), "\(c.name) p\(o): indicador '\(text)' ausente")
            }
        }
        let all = Multiset(documentWords(c.out))
        let leaked = all.minus(visible).minus(Multiset(overlayWords(c.plan)))
        metric("texto \(c.name) palavrasOrigem=\(source.total) visíveis=\(visible.total) repetidasNaSobreposição=\(extra.total) regiõesDeSobreposição=\(overlapRegions) vazamentoPDFKit=\(leaked.total)")
    }

    /// Inv. 6 / critério do M3: saída ≤ 1,3× a origem.
    @Test(arguments: CaseSpec.all)
    func sizeWithinM3Budget(_ spec: CaseSpec) throws {
        let c = try spec.write()
        defer { c.cleanup() }
        let src = fileSize(c.src), out = fileSize(c.out)
        let ratio = Double(out) / Double(src)
        #expect(c.result.report.bytes == out)
        #expect(ratio <= 1.3, "\(c.name): \(ratio)×")
        #expect(!c.result.report.warnings.contains { if case .sizeBudgetExceeded = $0 { true } else { false } })
        metric("tamanho \(c.name) origem=\(src) final=\(out) razão=\(String(format: "%.3f", ratio)) páginas=\(c.plan.pages.count)/\(c.analysis.pages.count) colocações=\(c.plan.allPlacements.count)")
    }

    /// Por que anotações e sumário não vão por um 2º passo no PDFKit: abrir a saída e
    /// regravar (sem mudar nada) mede o que esse passo custaria. O Quartz reemite o Form
    /// XObject dentro de cada página (zero `/Subtype /Form` em planos com várias
    /// colocações por origem) e o arquivo cresce. Só registra os números; o que se
    /// garante é a saída do qpdf (`formXObjectsStayShared`, `sizeWithinM3Budget`).
    @Test(arguments: CaseSpec.all)
    func pdfKitRewriteCostIsMeasured(_ spec: CaseSpec) throws {
        let c = try spec.write()
        defer { c.cleanup() }
        let rewritten = c.dir.appendingPathComponent("pdfkit.pdf")
        let doc = try #require(PDFDocument(url: c.out))
        #expect(doc.write(to: rewritten))
        #expect(PDFDocument(url: rewritten)?.pageCount == c.plan.pages.count)
        let q = fileSize(c.out), k = fileSize(rewritten)
        metric("passoPDFKit \(c.name) qpdf=\(q) pdfkit=\(k) fator=\(String(format: "%.3f", Double(k) / Double(q)))× formsQpdf=\(formXObjectCount(c.out)) formsPDFKit=\(formXObjectCount(rewritten))")
    }

    /// O Form XObject de cada página de origem continua único depois do passo PDFKit.
    @Test(arguments: CaseSpec.all)
    func formXObjectsStayShared(_ spec: CaseSpec) throws {
        let c = try spec.write()
        defer { c.cleanup() }
        let used = Set(c.plan.allPlacements.map(\.placement.sourcePage)).count
        let forms = formXObjectCount(c.out)
        #expect(forms == used, "\(c.name): \(forms) Form XObjects para \(used) páginas de origem")
        metric("forms \(c.name) forms=\(forms) origensUsadas=\(used) colocações=\(c.plan.allPlacements.count)")
    }

    /// Inv. 7: origem → saída → origem com erro < 0,01 pt, nos dois sentidos.
    @Test(arguments: CaseSpec.all)
    func roundTripBelowOneHundredthOfAPoint(_ spec: CaseSpec) throws {
        let doc = CorpusCache.doc(spec.scenario)
        let a = analysis(from: doc)
        let plan = spec.strategyImpl().plan(a, .booksPortrait, Recipe(id: spec.testDescription))
        let m = PlanMapping(plan: plan)
        var worst: CGFloat = 0, samples = 0
        for (o, p) in plan.allPlacements {
            let r = p.sourceRect
            for i in 0...6 {
                for j in 0...6 {
                    let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / 6, y: r.minY + r.height * CGFloat(j) / 6)
                    let hits = m.map(point: pt, fromSourcePage: p.sourcePage)
                    #expect(hits.contains { $0.outputPage == o }, "ponto \(pt) não mapeado para a saída \(o)")
                    for h in hits {
                        let back = try #require(m.unmap(point: h.point, onOutputPage: h.outputPage))
                        #expect(back.sourcePage == p.sourcePage)
                        worst = max(worst, hypot(back.point.x - pt.x, back.point.y - pt.y))
                        samples += 1
                    }
                    // Saída → origem → saída.
                    let q = pt.applying(p.transform)
                    let back = try #require(m.unmap(point: q, onOutputPage: o))
                    let again = m.map(point: back.point, fromSourcePage: back.sourcePage)
                    let err = again.filter { $0.outputPage == o }.map { hypot($0.point.x - q.x, $0.point.y - q.y) }.min()
                    #expect(err != nil)
                    worst = max(worst, err ?? .infinity)
                }
            }
        }
        #expect(worst < 0.01)
        metric("idaEVolta \(spec.testDescription) amostras=\(samples) piorErro=\(worst)pt")
    }
}
