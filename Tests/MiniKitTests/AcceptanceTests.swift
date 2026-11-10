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
    @Test(arguments: Scenario.allCases)
    func invariantsHoldOnEveryScenario(_ s: Scenario) async throws {
        let c = try await ConversionCache.shared.converted(s)
        let v = try #require(c.report.validation)
        for id in ["1a", "1b", "2", "3", "5", "6", "8"] {
            let r = try #require(v.result(id), "\(s): invariante \(id) ausente")
            #expect(r.status == .passed, "\(s) inv. \(id): \(r.detail)")
        }
        for id in ["4", "7"] { #expect(v.result(id)?.status == .notApplicable, "\(s) inv. \(id)") }
        #expect(v.result("1a")?.metric("tinta descoberta (total)") == 0, "\(s): tinta cortada no plano")
        #expect(c.report.passed)
        #expect(c.report.write.outputPageCount == c.truth.pages.count)
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
    @Test(arguments: Scenario.allCases)
    func scaleLockedWithinClass(_ s: Scenario) async throws {
        let c = try await ConversionCache.shared.converted(s)
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
    }
}
