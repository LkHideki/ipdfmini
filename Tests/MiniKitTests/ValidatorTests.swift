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
        let base = try Converter().plan(analysis: analysis, options: ConversionOptions()).plan
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
        let claimed = try Converter().plan(analysis: analysis, options: ConversionOptions()).plan
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
        let claimed = try Converter().plan(analysis: analysis, options: ConversionOptions()).plan
        let v = try await validate(.navigation, name: "reversed", claimed: claimed) { base in
            var p = base
            p.pages.reverse()
            return p
        }
        let r = try #require(v.result("5"))
        #expect(r.status == .failed)
        #expect(!r.outputPages.isEmpty)
    }

    @Test func notApplicableInvariantsCarryReason() async throws {
        let c = try await ConversionCache.shared.converted(.book6x9)
        for id in ["4", "7"] {
            let r = try #require(c.report.validation?.result(id))
            #expect(r.status == .notApplicable && !r.detail.isEmpty)
        }
    }
}
