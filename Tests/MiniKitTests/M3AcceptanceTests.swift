import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import SyntheticCorpus
import Testing
@testable import MiniKit

// Aceite do M3 (PLAN.md §17) com a análise REAL (não a verdade do corpus): ordem de
// leitura correta em ≥ 95% das páginas, nenhuma linha partida, corpo ≥ 9,5 pt
// equivalente, arquivo ≤ 1,3× a origem, todos os invariantes.

/// Medidas de um cenário convertido contra a verdade.
struct M3Measure: CustomStringConvertible {
    var scenario: Scenario
    var strategy: StrategyID
    var orientation: Orientation
    /// Corpo da estimativa do candidato escolhido (pt equivalente).
    var bodyPt: Double
    /// Pior escala das colocações com texto de coluna (E5) ou de corpo, com a altura-x da verdade.
    var measuredBodyPt: Double
    /// Pior texto do tamanho do corpo em qualquer colocação (resumo largo no E5), se houver aviso.
    var warnedPt: Double?
    var screens: Double
    var sizeRatio: Double
    /// Páginas com a ordem dos blocos analisados igual à da verdade.
    var blockOrderOK: Int
    /// Páginas com as linhas da verdade na ordem certa na sequência de saída.
    var outputOrderOK: Int
    var pages: Int
    var lines: Int
    var brokenLines: Int
    var failedInvariants: [String]

    var description: String {
        func n(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }
        return "M3ROW \(scenario.rawValue) estratégia=\(strategy.rawValue) orientação=\(orientation.rawValue) "
            + "corpo=\(n(bodyPt))pt corpoMedido=\(n(measuredBodyPt))pt avisoMenor=\(warnedPt.map { n($0) } ?? "-")pt "
            + "telas/página=\(n(screens)) tamanho=\(n(sizeRatio, 3))× ordemBlocos=\(blockOrderOK)/\(pages) "
            + "ordemSaída=\(outputOrderOK)/\(pages) linhasPartidas=\(brokenLines)/\(lines) "
            + "invariantesReprovados=\(failedInvariants.isEmpty ? "nenhum" : failedInvariants.joined(separator: ","))"
    }
}

enum M3Check {
    /// Folga de contenção da linha na colocação: a análise e a verdade medem a tinta em
    /// rasters diferentes (2 px/pt na análise), então a borda pode diferir ~1 px.
    static let lineTolerance: CGFloat = 0.5

    static func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x = a.intersection(b)
        return x.isNull ? 0 : x.width * x.height
    }

    /// Ordem dos blocos: cada bloco da verdade vai para o bloco analisado com maior
    /// sobreposição; em ordem de leitura da verdade, os índices analisados não podem
    /// voltar (fusão de blocos vizinhos dá índices iguais, o que não troca a ordem).
    /// Bloco da verdade sem sobreposição com nenhum analisado reprova a página.
    static func blockOrderCorrect(_ page: PageAnalysis, _ truth: PageTruth) -> Bool {
        guard !truth.blocks.isEmpty else { return true }
        var seq: [Int] = []
        for t in truth.blocks.sorted(by: { $0.readingOrder < $1.readingOrder }) {
            guard let i = page.blocks.indices.max(by: { area(page.blocks[$0].rect, t.rect) < area(page.blocks[$1].rect, t.rect) }),
                  area(page.blocks[i].rect, t.rect) > 0 else { return false }
            seq.append(i)
        }
        return zip(seq, seq.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Posição de leitura na saída: (página de saída, colocação, de cima para baixo).
    typealias Position = (out: Int, k: Int, y: CGFloat)

    static func position(of line: CGRect, sourcePage s: Int, plan: LayoutPlan) -> Position? {
        for (o, page) in plan.pages.enumerated() {
            for (k, p) in page.placements.enumerated() where p.sourcePage == s
                && p.sourceRect.insetBy(dx: -lineTolerance, dy: -lineTolerance).contains(line) {
                return (o, k, -line.maxY)
            }
        }
        return nil
    }

    static func before(_ a: Position, _ b: Position) -> Bool {
        if a.out != b.out { return a.out < b.out }
        if a.k != b.k { return a.k < b.k }
        return a.y <= b.y
    }

    /// Linhas da verdade em ordem de leitura (bloco, linha) caem em posições de saída que
    /// não voltam. Linha sem colocação que a contenha inteira = partida (conta à parte).
    static func outputOrder(page s: Int, truth: PageTruth, plan: LayoutPlan) -> (ok: Bool, lines: Int, broken: Int) {
        var broken = 0
        for l in truth.lines where position(of: l, sourcePage: s, plan: plan) == nil { broken += 1 }
        var seq: [Position] = []
        for b in truth.blocks.sorted(by: { $0.readingOrder < $1.readingOrder }) {
            for l in b.lines { if let p = position(of: l, sourcePage: s, plan: plan) { seq.append(p) } }
        }
        let ok = broken == 0 && zip(seq, seq.dropFirst()).allSatisfy { before($0, $1) }
        return (ok, truth.lines.count, broken)
    }

    static func measure(_ s: Scenario, mode: ConversionMode = .auto) async throws -> (M3Measure, Converted) {
        let c = try await ConversionCache.shared.converted(s, mode: mode)
        let analysis = try await ConversionCache.shared.analysis(s)
        let truth = c.truth
        let plan = c.report.plan
        var blockOK = 0, outOK = 0, lines = 0, broken = 0
        for (i, t) in truth.pages.enumerated() {
            if blockOrderCorrect(analysis.pages[i], t) { blockOK += 1 }
            let r = outputOrder(page: i, truth: t, plan: plan)
            if r.ok { outOK += 1 }
            lines += r.lines
            broken += r.broken
        }
        // Corpo medido: colocações que contêm linhas de blocos de corpo da verdade (coluna,
        // se houver colunas; senão parágrafos), altura-x da verdade × escala.
        let x = Double(truth.bodyXHeightPt)
        var worst = Double.infinity
        for (i, t) in truth.pages.enumerated() {
            let hasColumns = t.blocks.contains { $0.column != nil }
            let body = t.blocks.filter { hasColumns ? $0.column != nil && $0.type == "paragraph" : $0.type == "paragraph" }
            for b in body {
                for l in b.lines {
                    for page in plan.pages {
                        for p in page.placements where p.sourcePage == i
                            && p.sourceRect.insetBy(dx: -lineTolerance, dy: -lineTolerance).contains(l) {
                            worst = min(worst, Legibility.pointSizeEquivalent(
                                xHeightMM: Legibility.finalXHeightMM(sourceXHeightPt: x, scale: Double(p.scale))))
                        }
                    }
                }
            }
        }
        let warned = plan.warnings.compactMap { w -> Double? in
            if case .belowMinimumLegibility(let mm) = w { Legibility.pointSizeEquivalent(xHeightMM: mm) } else { nil }
        }.min()
        let src = Double(try Data(contentsOf: c.source).count)
        let m = M3Measure(scenario: s, strategy: c.report.chosen.strategy, orientation: plan.profile.orientation,
                          bodyPt: c.report.chosen.bodyPointSizeEquivalent ?? 0, measuredBodyPt: worst, warnedPt: warned,
                          screens: Double(plan.pages.count) / Double(truth.pages.count),
                          sizeRatio: Double(c.report.write.bytes) / src, blockOrderOK: blockOK, outputOrderOK: outOK,
                          pages: truth.pages.count, lines: lines, brokenLines: broken,
                          failedInvariants: c.report.validation?.failures.map(\.id) ?? ["sem validação"])
        return (m, c)
    }
}

@Suite struct M3AcceptanceTests {
    /// Critério do M3 no artigo arXiv em duas colunas.
    ///
    /// O auto escolhe E5 em retrato: E1, E4 e E3 ficam abaixo do mínimo (E3 só aceita a
    /// seção de duas colunas inteira, reduzida), e entre os E5 (retrato e paisagem, os
    /// dois no alvo) a regra desempata por menos telas. O resumo e os blocos de largura
    /// total ficam reduzidos em retrato (não cabem na largura): o plano avisa, e o
    /// critério "corpo ≥ 9,5 pt" é medido no corpo das colunas.
    @Test func arxivTwoColumnMeetsM3Criteria() async throws {
        let (m, c) = try await M3Check.measure(.arxivTwoColumn)
        print(m)
        #expect(m.strategy == .columns, "\(m)")
        #expect(Double(m.blockOrderOK) >= 0.95 * Double(m.pages), "ordem dos blocos: \(m)")
        #expect(Double(m.outputOrderOK) >= 0.95 * Double(m.pages), "ordem na saída: \(m)")
        #expect(m.brokenLines == 0, "\(m)")
        #expect(m.bodyPt >= 9.5, "\(m)")
        #expect(m.measuredBodyPt >= 9.5, "\(m)")
        #expect(m.sizeRatio <= 1.3, "\(m)")
        #expect(m.failedInvariants.isEmpty, "\(c.report.validation?.failures.map { "\($0.id): \($0.detail)" } ?? [])")
        #expect(c.report.validation?.result("6")?.metric("orçamento") == 1.3)
    }

    /// Relatório com figuras e figura alta: todos os invariantes com a estratégia do auto,
    /// nenhuma linha partida.
    @Test(arguments: [Scenario.reportWithFigures, .tallFigure])
    func figureScenariosPassAllInvariants(_ s: Scenario) async throws {
        let (m, c) = try await M3Check.measure(s)
        print(m)
        #expect(m.failedInvariants.isEmpty, "\(c.report.validation?.failures.map { "\($0.id): \($0.detail)" } ?? [])")
        #expect(m.brokenLines == 0, "\(m)")
        #expect(m.sizeRatio <= 1.3, "\(m)")
    }

    /// E3, E4 e E5 forçados nos três cenários do M3: invariantes e linhas inteiras valem
    /// para toda estratégia de fatias, não só para a escolhida.
    @Test(arguments: [Scenario.arxivTwoColumn, .reportWithFigures, .tallFigure],
          [ConversionMode.landscapeSlices, .portraitSlices, .columns])
    func forcedSliceStrategiesPassAllInvariants(_ s: Scenario, mode: ConversionMode) async throws {
        let (m, c) = try await M3Check.measure(s, mode: mode)
        print(m)
        #expect(c.report.mode == mode)
        #expect(m.failedInvariants.isEmpty, "\(c.report.validation?.failures.map { "\($0.id): \($0.detail)" } ?? [])")
        #expect(m.brokenLines == 0, "\(m)")
    }
}
