import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFWriting
import SyntheticCorpus
import Testing
@testable import MiniKit

// O validador precisa reprovar o que está errado; senão o aceite não prova nada.

@Suite struct ValidatorTests {
    /// Escreve `written`, valida contra `claimed` (por padrão o mesmo plano).
    func validate(_ s: Scenario, name: String, claimed: LayoutPlan? = nil,
                  written: (LayoutPlan) -> LayoutPlan) async throws -> ValidationReport {
        let src = try TestFiles.source(s)
        let analysis = try await ConversionCache.shared.analysis(s)
        let base = try Converter().plan(analysis: analysis, options: ConversionOptions(mode: .crop)).plan
        let w = written(base)
        let out = TestFiles.url("\(s.rawValue).\(name).pdf")
        _ = try await BoxWriter().write(w, source: SourceDocument(url: src), to: out, options: WriteOptions())
        return try await Validator().validate(analysis: analysis, plan: claimed ?? w, source: SourceDocument(url: src), output: out)
    }

    static func moved(_ p: LayoutPlan, page: Int, dx: CGFloat = 0, dy: CGFloat) -> LayoutPlan {
        var p = p
        var pl = p.pages[page].placements[0]
        pl.sourceRect = pl.sourceRect.offsetBy(dx: dx, dy: dy)
        pl.transform = CGAffineTransform(translationX: -pl.sourceRect.minX, y: -pl.sourceRect.minY)
            .concatenating(CGAffineTransform(scaleX: pl.scale, y: pl.scale))
        p.pages[page].placements[0] = pl
        return p
    }

    @Test func cutInkInPlanFails1a() async throws {
        // Janela da p. 2 descida 60 pt: o cabeçalho corrido sai do recorte.
        let v = try await validate(.book6x9, name: "cut") { Self.moved($0, page: 1, dy: -60) }
        let r = try #require(v.result("1a"))
        #expect(r.status == .failed)
        #expect(r.sourcePages == [1])
        #expect((r.metric("tinta descoberta (pior página)") ?? 0) > 100)
        // A saída corresponde ao plano gravado: o escritor está certo.
        #expect(v.result("1b")?.status == .passed)
    }

    @Test func writerDivergingFromPlanFails1b() async throws {
        // Grava a p. 3 deslocada 2 pt (sem cortar tinta) e valida contra o plano original.
        let analysis = try await ConversionCache.shared.analysis(.book6x9)
        let claimed = try Converter().plan(analysis: analysis, options: ConversionOptions(mode: .crop)).plan
        let v = try await validate(.book6x9, name: "shifted", claimed: claimed) { Self.moved($0, page: 2, dx: 2, dy: 0) }
        #expect(v.result("1a")?.status == .passed)
        let r = try #require(v.result("1b"))
        #expect(r.status == .failed)
        #expect(r.outputPages == [2])
    }

    @Test func inkInCornerFails8() async throws {
        // Canto superior esquerdo da janela no início da linha mais alta da p. 1
        // (cabeçalho corrido): o quadrado de canto cai sobre os glifos.
        let analysis = try await ConversionCache.shared.analysis(.book6x9)
        let title = try #require(analysis.pages[0].lines.first)
        let v = try await validate(.book6x9, name: "corner") { base in
            var p = base
            let pl = p.pages[0].placements[0]
            let size = pl.sourceRect.size
            let w = CGRect(x: title.rect.minX, y: title.rect.maxY - size.height, width: size.width, height: size.height)
            p.pages[0].placements[0] = Placement(sourcePage: 0, sourceRect: w,
                                                 transform: CGAffineTransform(translationX: -w.minX, y: -w.minY)
                                                     .concatenating(CGAffineTransform(scaleX: pl.scale, y: pl.scale)))
            return p
        }
        let r = try #require(v.result("8"))
        #expect(r.status == .failed)
        #expect(r.outputPages == [0])
    }

    @Test func missingLegibilityWarningFails2() async throws {
        let v = try await validate(.a4Report, name: "nowarn") { base in
            var p = base
            p.warnings.removeAll { if case .belowMinimumLegibility = $0 { true } else { false } }
            return p
        }
        #expect(v.result("2")?.status == .failed)
    }

    @Test func destinationOnWrongPageFails5() async throws {
        // Saída gravada em ordem invertida, validada como se estivesse na ordem do plano.
        let analysis = try await ConversionCache.shared.analysis(.navigation)
        let claimed = try Converter().plan(analysis: analysis, options: ConversionOptions(mode: .crop)).plan
        let v = try await validate(.navigation, name: "reversed", claimed: claimed) { base in
            var p = base
            p.pages.reverse()
            return p
        }
        let r = try #require(v.result("5"))
        #expect(r.status == .failed)
        #expect(!r.outputPages.isEmpty)
    }

    // MARK: - Várias colocações (PlacementWriter)

    /// Plano do modo forçado sobre a análise real; grava `written(base)` com o
    /// PlacementWriter e valida contra `claimed(base)` (por padrão o mesmo gravado).
    func validatePlacements(_ s: Scenario, mode: ConversionMode, name: String,
                            claimed: ((LayoutPlan) -> LayoutPlan)? = nil,
                            written: (LayoutPlan) -> LayoutPlan) async throws -> (report: ValidationReport, base: LayoutPlan) {
        let src = try TestFiles.source(s)
        let analysis = try await ConversionCache.shared.analysis(s)
        let base = try Converter().plan(analysis: analysis, options: ConversionOptions(mode: mode)).plan
        #expect(WriterKind(strategy: base.recipe.strategy) == .placement)
        let w = written(base)
        let out = TestFiles.url("\(s.rawValue).\(name).pdf")
        _ = try await PlacementWriter().write(w, source: SourceDocument(url: src), to: out, options: WriteOptions())
        let v = try await Validator().validate(analysis: analysis, plan: claimed?(base) ?? w,
                                               source: SourceDocument(url: src), output: out)
        return (v, base)
    }

    /// 1ª página de saída com pelo menos `n` colocações.
    static func page(_ p: LayoutPlan, withAtLeast n: Int) throws -> Int {
        try #require(p.pages.firstIndex { $0.placements.count >= n })
    }

    @Test func lineCutBetweenPlacementsFails1a() async throws {
        // E5: a colocação de baixo de uma página empilhada perde a metade de baixo da
        // última linha (o clip passa no meio dela).
        let analysis = try await ConversionCache.shared.analysis(.arxivTwoColumn)
        var cutSource = -1
        let (v, _) = try await validatePlacements(.arxivTwoColumn, mode: .columns, name: "e5cut") { base in
            var p = base
            let o = (try? Self.page(p, withAtLeast: 2)) ?? 0
            let k = p.pages[o].placements.count - 1
            var pl = p.pages[o].placements[k]
            let lines = analysis.pages[pl.sourcePage].blocks.flatMap(\.lines).filter { pl.sourceRect.contains($0.rect) }
            guard let low = lines.min(by: { $0.rect.minY < $1.rect.minY }) else { return p }
            let r = pl.sourceRect
            pl.sourceRect = CGRect(x: r.minX, y: low.rect.midY, width: r.width, height: r.maxY - low.rect.midY)
            p.pages[o].placements[k] = pl
            cutSource = pl.sourcePage
            return p
        }
        let r = try #require(v.result("1a"))
        #expect(r.status == .failed)
        #expect(r.sourcePages == [cutSource])
        // O escritor gravou o plano que recebeu.
        #expect(v.result("1b")?.status == .passed)
    }

    @Test func misalignedPlacementFails1b() async throws {
        // Página com várias colocações; só uma delas gravada 2 pt à direita.
        var shifted = -1
        let (v, _) = try await validatePlacements(.arxivTwoColumn, mode: .columns, name: "e5shift",
                                                  claimed: { $0 }) { base in
            var p = base
            let o = (try? Self.page(p, withAtLeast: 2)) ?? 0
            p.pages[o].placements[1].transform = p.pages[o].placements[1].transform
                .concatenating(CGAffineTransform(translationX: 2, y: 0))
            shifted = o
            return p
        }
        #expect(v.result("1a")?.status == .passed)
        let r = try #require(v.result("1b"))
        #expect(r.status == .failed)
        #expect(r.outputPages == [shifted])
        #expect(r.detail.contains("colocação 2"))
    }

    @Test func destinationOnWrongPlacementPageFails5() async throws {
        // Saída de E5 gravada em ordem invertida, validada como se estivesse na ordem do plano:
        // destinos do sumário e dos links caem em páginas que não contêm o ponto de origem.
        let (v, base) = try await validatePlacements(.navigation, mode: .columns, name: "e5reversed",
                                                     claimed: { $0 }) { base in
            var p = base
            p.pages.reverse()
            return p
        }
        #expect(base.pages.contains { $0.placements.count > 1 })
        let r = try #require(v.result("5"))
        #expect(r.status == .failed)
        #expect(!r.outputPages.isEmpty)
    }

    @Test func missingTextFails4() async throws {
        // E3: uma página de saída gravada com a colocação fora da página (texto ausente da
        // área esperada); o plano declarado é o original.
        var emptied = -1
        let (v, base) = try await validatePlacements(.reportWithFigures, mode: .landscapeSlices, name: "e3notext",
                                                     claimed: { $0 }) { base in
            var p = base
            let o = p.pages.firstIndex { $0.placements.count == 1 } ?? 0
            p.pages[o].placements[0].transform = p.pages[o].placements[0].transform
                .concatenating(CGAffineTransform(translationX: 0, y: 2000))
            emptied = o
            return p
        }
        #expect(base.pages.count > Set(base.pages.flatMap { $0.placements.map(\.sourcePage) }).count)
        let r = try #require(v.result("4"))
        #expect(r.status == .failed)
        #expect(r.outputPages == [emptied])
        #expect(r.detail.contains("faltam"))
    }

    @Test func roundTripAndBudgetApplyToPlacementWriter() async throws {
        let (v, _) = try await validatePlacements(.tallFigure, mode: .landscapeSlices, name: "e3ok") { $0 }
        #expect(v.passed, "\(v.failures.map { "\($0.id): \($0.detail)" })")
        #expect(v.result("7")?.status == .passed)
        #expect((v.result("7")?.metric("pior erro") ?? 1) < 0.01)
        #expect(v.result("6")?.metric("orçamento") == 1.3)
    }

    @Test func notApplicableInvariantsCarryReason() async throws {
        let c = try await ConversionCache.shared.converted(.book6x9, mode: .crop)
        for id in ["4", "7"] {
            let r = try #require(c.report.validation?.result(id))
            #expect(r.status == .notApplicable && !r.detail.isEmpty)
        }
    }
}
