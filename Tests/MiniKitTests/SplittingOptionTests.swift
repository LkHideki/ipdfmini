import Foundation
import LayoutEngine
import PDFAnalysis
import SyntheticCorpus
import Testing
@testable import MiniKit

// INC-22: 1 página de origem → 1 página de saída é o padrão; E3–E5 só com a divisão permitida.

@Suite struct SplittingOptionTests {
    @Test func defaultCandidatesKeepWholePages() async throws {
        let analysis = try await ConversionCache.shared.analysis(.arxivTwoColumn)
        let off = try Converter().plan(analysis: analysis, options: ConversionOptions())
        #expect(!ConversionOptions().allowSplitting)
        #expect(Set(off.candidates.map(\.strategy)).isSubset(of: [.passthrough, .crop]))
        #expect(off.plan.pages.count == analysis.pages.count)
        #expect(!off.allowSplitting)
        // Com a remoção pedida, E2 entra; fatias continuam fora.
        let e2 = try Converter().plan(analysis: analysis, options: ConversionOptions(removeHeaderFooter: true))
        #expect(Set(e2.candidates.map(\.strategy)).isSubset(of: [.passthrough, .crop, .aggressiveCrop]))

        let on = try Converter().plan(analysis: analysis, options: ConversionOptions(allowSplitting: true))
        #expect(on.allowSplitting)
        #expect(on.candidates.contains { StrategyID.splitsPages($0.strategy) })
        #expect(on.chosen.strategy == .columns)

        // Forçar fatias é pedir a divisão: a tabela volta inteira.
        let forced = try Converter().plan(analysis: analysis, options: ConversionOptions(mode: .portraitSlices))
        #expect(forced.allowSplitting && forced.chosen.strategy == .portraitSlices)
        #expect(ConversionMode.allCases.filter(\.splitsPages) == [.landscapeSlices, .portraitSlices, .columns])
    }

    /// JSON sem a chave (versões anteriores) decodifica com a divisão desligada.
    private func withoutKey<T: Codable>(_ value: T, _ key: String) throws -> T {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(obj[key] != nil, "a chave \(key) deveria estar no JSON novo")
        obj[key] = nil
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    @Test func oldReportsWithoutAllowSplittingStillDecode() async throws {
        let c = try await ConversionCache.shared.converted(.arxivTwoColumn, split: true)
        #expect(c.report.allowSplitting)
        let report = try JSONDecoder().decode(ConversionReport.self, from: JSONEncoder().encode(c.report))
        #expect(report == c.report)
        let old = try withoutKey(c.report, "allowSplitting")
        #expect(!old.allowSplitting)
        #expect(old.validation == c.report.validation && old.plan == c.report.plan)

        let analysis = try await ConversionCache.shared.analysis(.arxivTwoColumn)
        let planned = try Converter().plan(analysis: analysis, options: ConversionOptions(allowSplitting: true))
        let full = FullPlanReport(planned)
        #expect(full.allowSplitting && full.planResult == planned)
        let oldFull = try withoutKey(full, "allowSplitting")
        #expect(!oldFull.allowSplitting && !oldFull.planResult.allowSplitting)
        #expect(oldFull.plan == full.plan)
        #expect(try !withoutKey(PlanReport(planned), "allowSplitting").allowSplitting)
    }
}
