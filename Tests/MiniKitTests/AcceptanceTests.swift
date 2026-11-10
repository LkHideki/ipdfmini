import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit
import SyntheticCorpus
import Testing
@testable import MiniKit

// Aceite do M1 (PLAN.md §17) ponta a ponta sobre o corpus sintético: padrão 1 página → 1
// página (E0–E2) e, com a divisão permitida, o auto do M3 (E0–E5).

@Suite struct AcceptanceTests {
    /// Padrão (divisão desligada, INC-22): todos os invariantes, sem e com a remoção de
    /// cabeçalho/rodapé, e exatamente uma página de saída por página de origem, cada uma com
    /// a própria página (inv. 9), em todo cenário.
    @Test(arguments: Scenario.allCases, [false, true])
    func invariantsHoldOnEveryScenario(_ s: Scenario, removeHeaders: Bool) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: removeHeaders)
        let tag = "\(s)\(removeHeaders ? " (E2 permitido)" : "")"
        try Self.expectAllInvariants(c, tag: tag)
        #expect(!StrategyID.splitsPages(c.report.chosen.strategy), "\(tag): \(c.report.chosen.strategy.rawValue)")
        #expect(!c.report.candidates.contains { StrategyID.splitsPages($0.strategy) }, "\(tag): E3–E5 na tabela")
        #expect(!c.report.allowSplitting)
        #expect(c.report.write.outputPageCount == c.truth.pages.count, "\(tag)")
        #expect(c.report.validation?.result("9")?.status == .passed, "\(tag): \(c.report.validation?.result("9")?.detail ?? "")")
        for (j, out) in c.report.plan.pages.enumerated() {
            #expect(out.placements.map(\.sourcePage) == [j], "\(tag): saída \(j + 1)")
        }
    }

    /// Divisão permitida: os mesmos invariantes com a estratégia que o auto escolher (E0–E5).
    /// 4 e 7 só se aplicam ao PlacementWriter (E3+); 9 não se aplica.
    @Test(arguments: Scenario.allCases, [false, true])
    func invariantsHoldWithSplittingAllowed(_ s: Scenario, removeHeaders: Bool) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: removeHeaders, split: true)
        #expect(c.report.allowSplitting)
        try Self.expectAllInvariants(c, tag: "\(s) com divisão\(removeHeaders ? " (E2 permitido)" : "")")
    }

    /// E0–E2 forçados (BoxWriter) continuam verdes em todos os cenários: o auto do M3
    /// raramente os escolhe, e sem isto o caminho do BoxWriter no validador ficaria sem prova.
    @Test(arguments: Scenario.allCases, [ConversionMode.crop, .aggressiveCrop, .passthrough])
    func invariantsHoldWithBoxWriter(_ s: Scenario, mode: ConversionMode) async throws {
        let c = try await ConversionCache.shared.converted(s, mode: mode)
        #expect(WriterKind(strategy: c.report.plan.recipe.strategy) == .box)
        try Self.expectAllInvariants(c, tag: "\(s) \(mode.rawValue)")
    }

    static func expectAllInvariants(_ c: Converted, tag: String) throws {
        let v = try #require(c.report.validation)
        let box = WriterKind(strategy: c.report.plan.recipe.strategy) == .box
        for id in ["1a", "1b", "2", "3", "4", "5", "6", "7", "8", "9"] {
            let r = try #require(v.result(id), "\(tag): invariante \(id) ausente")
            if box, id == "4" || id == "7" {
                #expect(r.status == .notApplicable && !r.detail.isEmpty, "\(tag) inv. \(id)")
            } else if id == "9", c.report.allowSplitting {
                // Divisão permitida: a regra 1 → 1 não vale.
                #expect(r.status == .notApplicable && !r.detail.isEmpty, "\(tag) inv. 9")
            } else {
                #expect(r.status == .passed, "\(tag) [\(c.report.chosen.strategy.rawValue)] inv. \(id): \(r.detail)")
            }
        }
        #expect(v.result("1a")?.metric("tinta descoberta (total)") == 0, "\(tag): tinta cortada no plano")
        #expect(c.report.passed)
        // BoxWriter: uma página de saída por página de origem; fatias multiplicam.
        if box { #expect(c.report.write.outputPageCount == c.truth.pages.count) }
        #expect(c.report.write.outputPageCount == c.report.plan.pages.count)
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

    /// Opção desligada (padrão, §18 R5): E2 nem é candidato, o auto não o escolhe e
    /// todo bloco de cabeçalho/rodapé continua inteiro dentro de alguma colocação
    /// (no M1 o auto era sempre E1; com E3–E5 candidatos, a garantia vale para todos).
    @Test(arguments: Scenario.allCases, [false, true])
    func headersKeptWhenRemovalIsOff(_ s: Scenario, split: Bool) async throws {
        let c = try await ConversionCache.shared.converted(s, split: split)
        let analysis = try await ConversionCache.shared.analysis(s)
        #expect(c.report.chosen.strategy != .aggressiveCrop)
        #expect(!c.report.candidates.contains { $0.strategy == .aggressiveCrop })
        for page in analysis.pages {
            let windows = c.report.plan.pages.flatMap { $0.placements.filter { $0.sourcePage == page.index }.map(\.sourceRect) }
            for b in page.blocks where b.type == .headerFooter {
                #expect(windows.contains { $0.insetBy(dx: -1e-6, dy: -1e-6).contains(b.rect) },
                        "\(s) p. \(page.index + 1): \(b.rect) fora de toda colocação")
            }
        }
    }

    /// Com E2: o que sai é inteiro (nunca cortado ao meio) e o cabeçalho corrido dos livros
    /// sai mesmo. E2 forçado: com a divisão permitida, o auto prefere fatias nos livros (E1/E2
    /// não chegam ao alvo), e o que se prova aqui é a remoção do E2.
    @Test(arguments: bookScenarios)
    func removedBlocksAreWholeOutside(_ s: Scenario) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: true, mode: .aggressiveCrop)
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

    /// §17: sumário e links intactos, no padrão 1 → 1 (BoxWriter) e com a divisão (PlacementWriter).
    @Test(arguments: [false, true])
    func navigationIntact(split: Bool) async throws {
        let c = try await ConversionCache.shared.converted(.navigation, split: split)
        let box = WriterKind(strategy: c.report.plan.recipe.strategy) == .box
        #expect(box != split, "\(c.report.chosen.strategy.rawValue)")
        let nav = try #require(c.report.validation?.result("5"))
        #expect(nav.status == .passed, "\(nav.detail)")
        #expect(nav.metric("itens de sumário") == Double(c.truth.outlineCount))
        #expect(nav.metric("links") == Double(c.truth.linkCount))
        #expect(nav.metric("anotações") == Double(c.truth.annotationCount))
        #expect(nav.metric("links internos verificados") == 4)

        // Conferência independente: destinos do sumário vêm das páginas de origem da
        // verdade (capítulos e seções nas páginas 2, 2, 3, 4, 5 e 6), com o ponto dentro
        // da página e de uma colocação dessa origem.
        let out = try #require(PDFDocument(url: c.output))
        let plan = c.report.plan
        var pages: [Int] = []
        func walk(_ o: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                let item = o.child(at: i)!
                if let d = item.destination, let p = d.page {
                    let j = out.index(for: p)
                    #expect(p.bounds(for: .cropBox).contains(d.point), "\(item.label ?? ""): \(d.point)")
                    // BoxWriter: a página de saída é a janela de origem levada a (0,0) (S2;
                    // cenário sem /Rotate, espaço de página = espaço do usuário).
                    let hit = plan.pages[j].placements.first {
                        (box ? CGRect(origin: .zero, size: $0.sourceRect.size) : $0.sourceRect.applying($0.transform))
                            .standardized.insetBy(dx: -0.5, dy: -0.5).contains(d.point)
                    }
                    #expect(hit != nil, "\(item.label ?? ""): ponto fora das colocações")
                    pages.append(hit?.sourcePage ?? -1)
                }
                walk(item)
            }
        }
        walk(try #require(out.outlineRoot))
        #expect(pages == [1, 1, 2, 3, 4, 5])
    }

    /// §17: variação de escala entre páginas da mesma classe = 0, fora as exceções declaradas.
    /// Vale para E0–E4 (escala travada por classe); E5 tem, por desenho (§7), escala da
    /// coluna no documento todo e escala própria para cada bloco de largura total.
    /// `options`: (remoção de cabeçalho/rodapé, divisão permitida).
    @Test(arguments: Scenario.allCases, [(false, false), (true, false), (false, true), (true, true)])
    func scaleLockedWithinClass(_ s: Scenario, options: (removeHeaders: Bool, split: Bool)) async throws {
        let c = try await ConversionCache.shared.converted(s, removeHeaders: options.removeHeaders, split: options.split)
        let analysis = try await ConversionCache.shared.analysis(s)
        let plan = c.report.plan
        #expect(plan.recipe.classMode == .oddEven)
        guard plan.recipe.strategy != .columns else { return }
        let exceptions = Set(plan.warnings.compactMap { if case let .scaleException(p, _, _) = $0 { p } else { nil } })
        // Página vazia nas fatias sai inteira (como no E0), com a escala dela e aviso próprio.
        let empty: Set<Int> = WriterKind(strategy: plan.recipe.strategy) == .box ? []
            : Set(plan.warnings.compactMap { if case let .emptyPage(p) = $0 { p } else { nil } })
        let groups = sizeGroups(analysis.pages.map(\.pageBox.size))
        var scales: [Int: Set<CGFloat>] = [:]
        for out in plan.pages {
            for p in out.placements where !exceptions.contains(p.sourcePage) && !empty.contains(p.sourcePage) {
                scales[groups[p.sourcePage] * 2 + (p.sourcePage & 1), default: []].insert(p.scale)
            }
        }
        for (k, v) in scales { #expect(v.count == 1, "\(s) [\(plan.recipe.strategy.rawValue)] classe \(k): escalas \(v.sorted())") }
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
