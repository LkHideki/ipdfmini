import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit
import SyntheticCorpus
import Testing
@testable import MiniKit

// Aceite do M1 (PLAN.md §17) ponta a ponta sobre o corpus sintético.

@Suite struct AcceptanceTests {
    /// Todos os invariantes, sem e com a remoção de cabeçalho/rodapé.
    @Test(arguments: Scenario.allCases, [false, true])
    func invariantsHoldOnEveryScenario(_ s: Scenario, removeHeaders: Bool) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: removeHeaders)
        let tag = "\(s)\(removeHeaders ? " (E2 permitido)" : "")"
        let v = try #require(c.report.validation)
        for id in ["1a", "1b", "2", "3", "5", "6", "8"] {
            let r = try #require(v.result(id), "\(tag): invariante \(id) ausente")
            #expect(r.status == .passed, "\(tag) inv. \(id): \(r.detail)")
        }
        for id in ["4", "7"] { #expect(v.result(id)?.status == .notApplicable, "\(tag) inv. \(id)") }
        #expect(v.result("1a")?.metric("tinta descoberta (total)") == 0, "\(tag): tinta cortada no plano")
        #expect(c.report.passed)
        #expect(c.report.write.outputPageCount == c.truth.pages.count)
    }

    /// §17: corpo ≥ 9 pt equivalente em ≥ 90% dos livros 6×9, com a remoção de
    /// cabeçalho/rodapé permitida (o E1 não chega lá: cabeçalho e fólio entram na mancha).
    @Test func bookCorpusBodyAtLeast9pt() async throws {
        var rows: [String] = []
        var ok = 0
        for s in bookScenarios {
            let c = try await ConversionCache.shared.converted(s, removeHeaders: true)
            let pt = c.report.chosen.bodyPointSizeEquivalent ?? 0
            // Tolerância = precisão da análise: o erro de altura-x medido contra a
            // verdade do corpus é ≤ 0,71% (±0,064 pt a 9 pt). O corpus fica no
            // limiar (Times 10 pt, mancha 324×518, respiro 2 mm → 9,00 pt), e
            // 8,999 pt não é distinguível de 9 pt por este instrumento.
            if pt >= 9 - 0.05 { ok += 1 }
            rows.append("\(s): \(c.report.chosen.strategy.rawValue) \(Describe.number(pt, decimals: 3)) pt")
        }
        let fraction = Double(ok) / Double(bookScenarios.count)
        #expect(fraction >= 0.9, "corpo ≥ 9 pt em \(ok) de \(bookScenarios.count) livros: \(rows.joined(separator: " · "))")
    }

    /// Opção desligada (padrão, §18 R5): auto fica no E1, E2 nem é candidato e
    /// todo bloco de cabeçalho/rodapé continua dentro da janela.
    @Test(arguments: Scenario.allCases)
    func headersKeptWhenRemovalIsOff(_ s: Scenario) async throws {
        let c = try await ConversionCache.shared.converted(s)
        let analysis = try await ConversionCache.shared.analysis(s)
        #expect(c.report.chosen.strategy == .crop)
        #expect(!c.report.candidates.contains { $0.strategy == .aggressiveCrop })
        for out in c.report.plan.pages {
            let p = try #require(out.placements.first)
            let page = analysis.pages[p.sourcePage]
            for b in page.blocks where b.type == .headerFooter {
                #expect(p.sourceRect.insetBy(dx: -1e-6, dy: -1e-6).contains(b.rect), "\(s) p. \(page.index + 1): \(b.rect) fora")
            }
        }
    }

    /// Com E2: o que sai é inteiro (nunca cortado ao meio) e o cabeçalho corrido dos livros sai mesmo.
    @Test(arguments: bookScenarios)
    func removedBlocksAreWholeOutside(_ s: Scenario) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: true)
        let analysis = try await ConversionCache.shared.analysis(s)
        #expect(c.report.chosen.strategy == .aggressiveCrop)
        var removed = 0
        for out in c.report.plan.pages {
            let p = try #require(out.placements.first)
            let w = p.sourceRect
            for b in analysis.pages[p.sourcePage].removedHeaderFooter {
                let i = w.intersection(b)
                let outside = i.isNull || i.width < 1e-6 || i.height < 1e-6
                #expect(outside || w.insetBy(dx: -1e-6, dy: -1e-6).contains(b), "\(s) p. \(p.sourcePage + 1): bloco cortado")
                if outside { removed += 1 }
            }
        }
        #expect(removed > 0, "\(s): nenhum cabeçalho/rodapé removido")
    }

    /// §17: sumário e links intactos.
    @Test func navigationIntact() async throws {
        let c = try await ConversionCache.shared.converted(.navigation)
        let nav = try #require(c.report.validation?.result("5"))
        #expect(nav.status == .passed, "\(nav.detail)")
        #expect(nav.metric("itens de sumário") == Double(c.truth.outlineCount))
        #expect(nav.metric("links") == Double(c.truth.linkCount))
        #expect(nav.metric("anotações") == Double(c.truth.annotationCount))
        #expect(nav.metric("links internos verificados") == 4)

        // Conferência independente: destinos do sumário nas páginas da verdade
        // (capítulos e seções nas páginas 2, 2, 3, 4, 5 e 6) e ponto dentro da página.
        let out = try #require(PDFDocument(url: c.output))
        var pages: [Int] = []
        func walk(_ o: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                let item = o.child(at: i)!
                if let d = item.destination, let p = d.page {
                    pages.append(out.index(for: p))
                    #expect(p.bounds(for: .cropBox).contains(d.point), "\(item.label ?? ""): \(d.point)")
                }
                walk(item)
            }
        }
        walk(try #require(out.outlineRoot))
        #expect(pages == [1, 1, 2, 3, 4, 5])
    }

    /// §17: variação de escala entre páginas da mesma classe = 0, fora as exceções declaradas.
    @Test(arguments: Scenario.allCases, [false, true])
    func scaleLockedWithinClass(_ s: Scenario, removeHeaders: Bool) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: removeHeaders)
        let analysis = try await ConversionCache.shared.analysis(s)
        let plan = c.report.plan
        #expect(plan.recipe.classMode == .oddEven)
        let exceptions = Set(plan.warnings.compactMap { if case let .scaleException(p, _, _) = $0 { p } else { nil } })
        let groups = sizeGroups(analysis.pages.map(\.pageBox.size))
        var scales: [Int: Set<CGFloat>] = [:]
        for out in plan.pages {
            let p = try #require(out.placements.first)
            guard !exceptions.contains(p.sourcePage) else { continue }
            scales[groups[p.sourcePage] * 2 + (p.sourcePage & 1), default: []].insert(p.scale)
        }
        for (k, v) in scales { #expect(v.count == 1, "\(s) classe \(k): escalas \(v.sorted())") }
    }

    /// Análise contra a verdade do corpus: caixa de tinta ±1 pt, altura-x ±5%.
    @Test(arguments: Scenario.allCases)
    func analysisMatchesTruth(_ s: Scenario) async throws {
        let a = try await ConversionCache.shared.analysis(s)
        let t = CorpusCache.doc(s).truth
        #expect(a.pages.count == t.pages.count)
        for (p, tp) in zip(a.pages, t.pages) {
            let tag = "\(s) p. \(p.index + 1)"
            #expect(p.geometry.effectiveBox.maxEdgeDistance(to: tp.geometry.effectiveBox) <= 0.01, "\(tag) caixa efetiva")
            #expect(p.geometry.rotation == tp.geometry.rotation, "\(tag) rotação")
            switch (p.inkBox, tp.inkBox) {
            case (nil, nil): break
            case let (got?, want?):
                #expect(got.maxEdgeDistance(to: want) <= 1, "\(tag): tinta \(got) × verdade \(want)")
            default:
                Issue.record("\(tag): tinta \(String(describing: p.inkBox)) × verdade \(String(describing: tp.inkBox))")
            }
        }
        let xh = try #require(a.bodyXHeightPt, "\(s): sem altura-x")
        #expect(abs(xh / t.bodyXHeightPt - 1) <= 0.05, "\(s): altura-x \(xh) × verdade \(t.bodyXHeightPt)")
        // Meta do INC-8: topos planos (x, v, w) tiram a sobra óptica das redondas.
        #expect(abs(xh / t.bodyXHeightPt - 1) <= 0.02, "\(s): altura-x \(xh) × verdade \(t.bodyXHeightPt) (meta ±2%)")
    }
}
