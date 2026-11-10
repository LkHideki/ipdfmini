import Foundation
import CoreGraphics
import PDFKit
import Testing
import MiniGeometry
import LayoutEngine
@testable import PDFWriting

private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

private struct Env {
    let dir = TestPDF.tempDir()
    var src: URL { dir.appendingPathComponent("src.pdf") }
    var out: URL { dir.appendingPathComponent("out.pdf") }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ plan: LayoutPlan, password: String? = nil, options: WriteOptions = WriteOptions()) async throws -> WriteReport {
        try await BoxWriter().write(plan, source: SourceDocument(url: src, password: password), to: out, options: options)
    }
}

/// As cinco caixas iguais entre si, lidas pelo PDFKit e pelo CGPDFDocument, com o tamanho esperado.
/// O PDFKit normaliza a origem da MediaBox para (0,0) ao gravar e desloca tudo junto
/// (conteúdo, anotações); a posição é provada à parte, por render e por anotações.
private func expectBoxes(_ url: URL, page: Int, size: CGSize, sourceLocation: SourceLocation = #_sourceLocation) {
    for (name, boxes) in [("pdfkit", TestPDF.pdfkitBoxes(url, page: page)), ("cg", TestPDF.cgBoxes(url, page: page))] {
        let media = boxes["media"]!
        for (box, r) in boxes {
            #expect(r == media, "\(name) \(box) difere da media", sourceLocation: sourceLocation)
        }
        #expect(near(media.width, size.width) && near(media.height, size.height),
                "\(name): \(media.size) != \(size)", sourceLocation: sourceLocation)
        #expect(near(media.minX, 0) && near(media.minY, 0), "\(name): origem \(media.origin)", sourceLocation: sourceLocation)
    }
}

private func expectViewportAspect(_ url: URL, pages: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    for i in 0..<pages {
        let s = TestPDF.cgDisplaySize(url, page: i)
        #expect(abs(s.height / s.width / TestPDF.viewport.aspect - 1) <= 0.001, "página \(i): \(s)", sourceLocation: sourceLocation)
    }
}

private func words(_ s: String?) -> [String] {
    (s ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init).sorted()
}

@Suite struct BoxWriterTests {

    // MARK: caixas

    @Test func unrotatedCropWritesAllFiveBoxes() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.crop = CGRect(x: 50, y: 40, width: 500, height: 700)
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)
        let w = TestPDF.window(x: 100, y: 100, width: 300)
        let report = try await env.write(TestPDF.plan([(0, w)]))
        #expect(report.outputPageCount == 1)
        expectBoxes(env.out, page: 0, size: w.size)
        expectViewportAspect(env.out, pages: 1)
    }

    @Test func pdfKitBoundsAreUnrotatedUserSpace() throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.crop = CGRect(x: 40, y: 60, width: 500, height: 700)
        p.rotation = 90
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)
        let page = PDFDocument(url: env.src)!.page(at: 0)!
        #expect(page.rotation == 90)
        #expect(page.bounds(for: .cropBox) == CGRect(x: 40, y: 60, width: 500, height: 700))
        #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 600, height: 800))
        let cg = TestPDF.cgBoxes(env.src, page: 0)
        #expect(cg["crop"] == page.bounds(for: .cropBox))
    }

    /// /Rotate 90, CropBox deslocada. Derivação à mão (u = x - x0, v = y - y0, w = 500):
    /// x' = x0 + v e y' = y0 + w - u, logo, em espaço do usuário, y = x' + 20 e x = 600 - y'.
    @Test func rotated90WritesUserSpaceBoxes() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.crop = CGRect(x: 40, y: 60, width: 500, height: 700)
        p.rotation = 90
        p.drawText = false
        p.marker = CGRect(x: 280, y: 170, width: 120, height: 100)   // espaço de página: (150,200,100,120)
        p.highlight = CGRect(x: 100, y: 200, width: 100, height: 14)
        p.internalLink = TestLink(rect: CGRect(x: 160, y: 120, width: 80, height: 14), destinationPage: 0)
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)

        let w = TestPDF.window(x: 100, y: 80, width: 300)               // página: x 100…400, y 80…536,86
        let report = try await env.write(TestPDF.plan([(0, w)]))
        // Arquivo de ~5 KB: o custo fixo do deslocamento de origem por página (ver
        // originShiftOverheadIsSmallAndConstantPerPage) já o deixava logo abaixo de 1,1×, e o
        // destino do link regravado em coordenadas deslocadas soma ~10 bytes, cruzando
        // 1,1×. O orçamento de tamanho é provado em inPlaceOutputStaysWithinSizeBudget;
        // aqui só nenhum outro aviso pode aparecer.
        #expect(report.warnings.filter { if case .sizeBudgetExceeded = $0 { false } else { true } }.isEmpty)

        let expectedUser = CGRect(x: 600 - w.maxY, y: 120, width: w.height, height: w.width)
        expectBoxes(env.out, page: 0, size: expectedUser.size)
        expectViewportAspect(env.out, pages: 1)

        // Posição provada por render: marcador em página = (150,200) - origem da janela.
        let ink = try #require(TestPDF.inkRect(env.out, page: 0))
        #expect(near(ink.minX, 50, 1.5) && near(ink.minY, 120, 1.5) && near(ink.width, 100, 1.5) && near(ink.height, 120, 1.5),
                "ink \(ink)")

        // Anotações acompanham o deslocamento da caixa (origem do usuário → (0,0)).
        let page = PDFDocument(url: env.out)!.page(at: 0)!
        #expect(page.rotation == 90)
        let annots = page.annotations
        let hl = try #require(annots.first { $0.type == "Highlight" })
        let link = try #require(annots.first { $0.type == "Link" })
        #expect(near(hl.bounds.minX, 100 - expectedUser.minX, 0.05) && near(hl.bounds.minY, 200 - expectedUser.minY, 0.05))
        #expect(near(link.bounds.minX, 160 - expectedUser.minX, 0.05) && near(link.bounds.minY, 120 - expectedUser.minY, 0.05))
    }

    /// /Rotate 90 com espaço de página definido por uma caixa efetiva menor que
    /// Crop∩Media (análise que partiu da TrimBox): o escritor usa a geometria do plano.
    @Test func rotatedPageUsesPlanGeometry() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.crop = CGRect(x: 40, y: 60, width: 500, height: 700)
        p.rotation = 90
        p.drawText = false
        p.marker = CGRect(x: 280, y: 170, width: 120, height: 100)
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)

        // assimétrica: com inset uniforme x0+y0+w coincide e a conversão a 90° não muda
        let trim = CGRect(x: 40, y: 60, width: 450, height: 700)
        let g = PageGeometry(effectiveBox: trim, rotation: 90)
        let w = TestPDF.window(x: 100, y: 80, width: 300)
        var plan = TestPDF.plan([(0, w)])
        plan.pages[0].placements[0].sourceGeometry = g
        _ = try await env.write(plan)

        let expectedUser = g.toUser(w)
        expectBoxes(env.out, page: 0, size: expectedUser.size)
        // Marcador em espaço de página (pela geometria do plano) menos a origem da janela.
        let m = g.toPage(p.marker!)
        let ink = try #require(TestPDF.inkRect(env.out, page: 0))
        #expect(near(ink.minX, m.minX - w.minX, 1.5) && near(ink.minY, m.minY - w.minY, 1.5)
                && near(ink.width, m.width, 1.5) && near(ink.height, m.height, 1.5), "ink \(ink) esperado \(m)")
    }

    /// MediaBox de origem não nula + /Rotate 90. Marcador em (300,300,50,50) do usuário →
    /// espaço de página (350,380,50,50), com x' = 140 + (y - 90) e y' = 730 - x.
    @Test func nonZeroMediaOriginAndRotation() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.rawPDF(media: CGRect(x: 100, y: 50, width: 600, height: 800),
                           crop: CGRect(x: 140, y: 90, width: 500, height: 700), rotate: 90,
                           content: "0 g 300 300 50 50 re f", to: env.src)
        let srcPage = PDFDocument(url: env.src)!.page(at: 0)!
        try #require(srcPage.bounds(for: .mediaBox) == CGRect(x: 100, y: 50, width: 600, height: 800))
        let before = try #require(TestPDF.inkRect(env.src, page: 0))
        // Sanidade do derivado: no original exibido (500 x 700 → 700 x 500) o marcador fica em (210,290).
        #expect(near(before.minX, 210, 1.5) && near(before.minY, 290, 1.5))

        let w = CGRect(x: 300, y: 350, width: 150, height: 150 * TestPDF.viewport.aspect)
        try await env.write(TestPDF.plan([(0, w)]))
        expectBoxes(env.out, page: 0, size: CGSize(width: w.height, height: w.width))
        let ink = try #require(TestPDF.inkRect(env.out, page: 0))
        #expect(near(ink.minX, 50, 1.5) && near(ink.minY, 30, 1.5) && near(ink.width, 50, 1.5) && near(ink.height, 50, 1.5), "ink \(ink)")
        expectViewportAspect(env.out, pages: 1)
    }

    /// MediaBox maior que a original: área em branco, conteúdo no lugar.
    @Test func windowBeyondPageAddsBlankArea() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.marker = CGRect(x: 300, y: 300, width: 50, height: 50)
        p.drawText = false
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)
        let w = TestPDF.window(x: -100, y: -100, width: 800)
        try await env.write(TestPDF.plan([(0, w)]))
        expectBoxes(env.out, page: 0, size: w.size)
        let ink = try #require(TestPDF.inkRect(env.out, page: 0))
        #expect(near(ink.minX, 400, 1.5) && near(ink.minY, 400, 1.5) && near(ink.width, 50, 1.5), "ink \(ink)")
        expectViewportAspect(env.out, pages: 1)
    }

    // MARK: páginas, ordem, navegação

    @Test func removesUnusedPagesAndFollowsPlanOrder() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: Array(repeating: TestPageSpec(), count: 5)), to: env.src)
        let w = TestPDF.window(x: 0, y: 0, width: 590)
        let report = try await env.write(TestPDF.plan([(2, w), (0, w), (4, w)]))
        #expect(report.outputPageCount == 3)
        let out = PDFDocument(url: env.out)!
        #expect(out.pageCount == 3)
        let texts = (0..<3).map { out.page(at: $0)!.string ?? "" }
        #expect(texts[0].contains("p2l0") && texts[1].contains("p0l0") && texts[2].contains("p4l0"))
        #expect(!(out.string ?? "").contains("p1l0") && !(out.string ?? "").contains("p3l0"))
        #expect(CGPDFDocument(env.out as CFURL)!.numberOfPages == 3)
    }

    private func navigationSpec() -> TestDocSpec {
        var pages = Array(repeating: TestPageSpec(), count: 4)
        pages[0].internalLink = TestLink(rect: CGRect(x: 50, y: 50, width: 80, height: 14), destinationPage: 3)
        pages[1].externalLink = (CGRect(x: 60, y: 60, width: 90, height: 14), URL(string: "https://example.org/x")!)
        pages[2].highlight = CGRect(x: 70, y: 70, width: 100, height: 14)
        pages[3].highlight = CGRect(x: 80, y: 80, width: 100, height: 14)
        return TestDocSpec(pages: pages, outline: [("Cap 1", 0, 0), ("Sec 1.1", 1, 1), ("Cap 2", 2, 0), ("Cap 3", 3, 0)])
    }

    private func outlineTargets(_ doc: PDFDocument) -> [String: Int] {
        var result: [String: Int] = [:]
        func walk(_ o: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                let c = o.child(at: i)!
                if let label = c.label, let page = c.destination?.page { result[label] = doc.index(for: page) }
                walk(c)
            }
        }
        walk(doc.outlineRoot!)
        return result
    }

    private func annotationCounts(_ doc: PDFDocument) -> [[String: Int]] {
        (0..<doc.pageCount).map { i in
            Dictionary(grouping: doc.page(at: i)!.annotations, by: { $0.type ?? "?" }).mapValues(\.count)
        }
    }

    @Test func outlineLinksAnnotationsAndTextPreserved() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(navigationSpec(), to: env.src)
        let src = PDFDocument(url: env.src)!
        let w = TestPDF.window(x: 0, y: 0, width: 590)
        try await env.write(TestPDF.plan((0..<4).map { ($0, w) }))
        let out = PDFDocument(url: env.out)!

        #expect(out.pageCount == 4)
        #expect(outlineTargets(out) == ["Cap 1": 0, "Sec 1.1": 1, "Cap 2": 2, "Cap 3": 3])
        #expect(outlineTargets(out) == outlineTargets(src))
        #expect(out.outlineRoot!.numberOfChildren == src.outlineRoot!.numberOfChildren)
        #expect(out.outlineRoot!.child(at: 0)!.numberOfChildren == 1)
        #expect(annotationCounts(out) == annotationCounts(src))
        let link = try #require(out.page(at: 0)!.annotations.first { $0.type == "Link" })
        #expect(out.index(for: try #require(link.destination?.page)) == 3)
        let ext = try #require(out.page(at: 1)!.annotations.first { $0.type == "Link" })
        #expect(ext.url == URL(string: "https://example.org/x"))
        #expect(words(out.string) == words(src.string))
        #expect(!(out.string ?? "").isEmpty)
    }

    @Test func reorderedPlanKeepsDestinationsOnTheRightPages() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(navigationSpec(), to: env.src)
        let w = TestPDF.window(x: 0, y: 0, width: 590)
        try await env.write(TestPDF.plan([(3, w), (2, w), (1, w), (0, w)]))
        let out = PDFDocument(url: env.out)!
        #expect(outlineTargets(out) == ["Cap 1": 3, "Sec 1.1": 2, "Cap 2": 1, "Cap 3": 0])
        // O link da página de origem 0 (agora índice 3) continua apontando para a origem 3 (agora índice 0).
        let link = try #require(out.page(at: 3)!.annotations.first { $0.type == "Link" })
        #expect(out.index(for: try #require(link.destination?.page)) == 0)
        #expect((out.page(at: 0)!.string ?? "").contains("p3l0"))
    }

    // MARK: fatias e tamanho

    @Test func repeatedSourcePageBecomesSlices() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.lines = 40
        p.noiseSide = 200   // ~40 kB de imagem: se a cópia duplicasse o conteúdo, a razão iria a ~3×
        p.highlight = CGRect(x: 40, y: 600, width: 100, height: 14)
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)
        let a = TestPDF.window(x: 0, y: 0, width: 300)
        let b = TestPDF.window(x: 300, y: 0, width: 300)
        let c = TestPDF.window(x: 0, y: 343.145, width: 300)
        let report = try await env.write(TestPDF.plan([(0, a), (0, b), (0, c)]))
        #expect(report.outputPageCount == 3)
        let out = PDFDocument(url: env.out)!
        #expect(out.pageCount == 3)
        for (i, r) in [a, b, c].enumerated() {
            expectBoxes(env.out, page: i, size: r.size)
            #expect(!(out.page(at: i)!.string ?? "").isEmpty)
        }
        expectViewportAspect(env.out, pages: 3)
        // O PDFKit extrai só o texto dentro da janela: cada fatia traz menos texto que a origem
        // inteira, e janelas distintas dão textos distintos.
        let full = (PDFDocument(url: env.src)!.string ?? "").count
        let t0 = out.page(at: 0)!.string ?? "", t1 = out.page(at: 1)!.string ?? ""
        #expect(t0.count < full && t1.count < full)
        #expect(t0 != t1)
        let ratio = Double(TestPDF.size(env.out)) / Double(TestPDF.size(env.src))
        #expect(ratio <= 1.1, "cópias de página não podem multiplicar o conteúdo")
        print("MEDIDA fatias: origem \(TestPDF.size(env.src)) B, saída \(TestPDF.size(env.out)) B, razão \(ratio)")
        print("MEDIDA fatias: anotações por página \(annotationCounts(out))")
    }

    @Test func sliceOfRotatedPageUsesOriginalGeometryForEachCopy() async throws {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.crop = CGRect(x: 40, y: 60, width: 500, height: 700)
        p.rotation = 90
        p.drawText = false
        p.marker = CGRect(x: 280, y: 170, width: 120, height: 100)
        try TestPDF.build(TestDocSpec(pages: [p]), to: env.src)
        let a = TestPDF.window(x: 100, y: 80, width: 300)
        let b = TestPDF.window(x: 100, y: 80, width: 300)
        try await env.write(TestPDF.plan([(0, a), (0, b)]))
        // As duas fatias, idênticas, têm de resultar idênticas: a cópia não herda a caixa já alterada.
        expectBoxes(env.out, page: 0, size: CGSize(width: a.height, height: a.width))
        expectBoxes(env.out, page: 1, size: CGSize(width: a.height, height: a.width))
        let i0 = try #require(TestPDF.inkRect(env.out, page: 0)), i1 = try #require(TestPDF.inkRect(env.out, page: 1))
        #expect(near(i0.minX, i1.minX, 0.5) && near(i0.minY, i1.minY, 0.5) && near(i0.minX, 50, 1.5) && near(i0.minY, 120, 1.5))
    }

    private func inPlaceRatio(noiseSide: Int, pages: Int) async throws -> (src: Int64, out: Int64, report: WriteReport) {
        let env = Env(); defer { env.cleanup() }
        var p = TestPageSpec()
        p.lines = 55
        p.noiseSide = noiseSide
        p.highlight = CGRect(x: 40, y: 600, width: 100, height: 14)
        try TestPDF.build(TestDocSpec(pages: Array(repeating: p, count: pages),
                                      outline: (0..<pages).map { ("Cap \($0)", $0, 0) }), to: env.src)
        // Janela deslocada: o PDFKit grava a origem em (0,0) e desloca o conteúdo.
        let w = TestPDF.window(x: 20, y: 20, width: 500)
        let report = try await env.write(TestPDF.plan((0..<pages).map { ($0, w) }))
        return (TestPDF.size(env.src), TestPDF.size(env.out), report)
    }

    /// Página com peso realista (texto + imagem, ~18 kB): a meta da §9.3 vale.
    @Test func inPlaceOutputStaysWithinSizeBudget() async throws {
        let r = try await inPlaceRatio(noiseSide: 120, pages: 30)
        let ratio = Double(r.out) / Double(r.src)
        print("MEDIDA em lugar (texto+imagem): origem \(r.src) B, saída \(r.out) B, razão \(ratio)")
        #expect(ratio <= 1.1)
        #expect(r.report.bytes == r.out)
        #expect(!r.report.warnings.contains { if case .sizeBudgetExceeded = $0 { true } else { false } })
    }

    /// Com a origem deslocada o PDFKit acrescenta um custo fixo por página (~0,8 kB: não
    /// duplica conteúdo). Em páginas minúsculas isso passa de 1,1×; o teste fixa o custo, não a razão.
    @Test func originShiftOverheadIsSmallAndConstantPerPage() async throws {
        let small = try await inPlaceRatio(noiseSide: 0, pages: 30)
        let big = try await inPlaceRatio(noiseSide: 120, pages: 30)
        let perPageSmall = Double(small.out - small.src) / 30, perPageBig = Double(big.out - big.src) / 30
        print("MEDIDA custo por página: texto \(perPageSmall) B, texto+imagem \(perPageBig) B (razão só texto \(Double(small.out) / Double(small.src)))")
        #expect(perPageSmall < 1024 && perPageBig < 1024)
        #expect(abs(perPageSmall - perPageBig) < 200)
    }

    // MARK: rejeições

    private func expectUnsupported(_ plan: LayoutPlan, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec(), TestPageSpec()]), to: env.src)
        do {
            try await env.write(plan)
            Issue.record("deveria rejeitar o plano", sourceLocation: sourceLocation)
        } catch let e as WriteError {
            guard case .unsupportedPlan = e else { Issue.record("erro inesperado \(e)", sourceLocation: sourceLocation); return }
            #expect(!FileManager.default.fileExists(atPath: env.out.path), "não deve gravar saída", sourceLocation: sourceLocation)
        }
    }

    @Test func rejectsTwoPlacementsOnOnePage() async throws {
        let w = TestPDF.window(x: 0, y: 0, width: 300)
        let page = OutputPage(sizePt: TestPDF.viewport.sizePt,
                              placements: [TestPDF.placement(source: 0, rect: w), TestPDF.placement(source: 1, rect: w)])
        try await expectUnsupported(LayoutPlan(profile: TestPDF.viewport, pages: [page], recipe: Recipe()))
    }

    @Test func rejectsRotationMirrorNonUniformScaleAndHidden() async throws {
        let w = TestPDF.window(x: 0, y: 0, width: 300)
        func plan(_ edit: (inout Placement) -> Void) -> LayoutPlan {
            var pl = TestPDF.placement(source: 0, rect: w)
            edit(&pl)
            return LayoutPlan(profile: TestPDF.viewport,
                              pages: [OutputPage(sizePt: TestPDF.viewport.sizePt, placements: [pl])], recipe: Recipe())
        }
        try await expectUnsupported(plan { $0.transform = $0.transform.rotated(by: .pi / 2) })
        try await expectUnsupported(plan { $0.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 500) })
        try await expectUnsupported(plan { $0.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: 1.2, tx: 0, ty: 0) })
        try await expectUnsupported(plan { $0.hidden = [CGRect(x: 0, y: 0, width: 10, height: 10)] })
        try await expectUnsupported(plan { $0.sourceRect = .zero })
        try await expectUnsupported(plan { $0.sourcePage = 7 })
        try await expectUnsupported(LayoutPlan(profile: TestPDF.viewport, pages: [], recipe: Recipe()))
    }

    // MARK: metadados

    private func producer(_ url: URL) -> String? {
        let cg = CGPDFDocument(url as CFURL)!
        guard let info = cg.info else { return nil }
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Producer", &s), let str = s else { return nil }
        return CGPDFStringCopyTextString(str) as String?
    }

    @Test func producerCarriesRecipeID() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec(), TestPageSpec()]), to: env.src)
        let w = TestPDF.window(x: 0, y: 0, width: 590)
        let report = try await env.write(TestPDF.plan([(0, w), (1, w)], recipeID: "abc-123"))
        #expect(!report.warnings.contains(.producerNotApplied))
        let expected = "iPDFmini \(PDFWriting.version) recipe:abc-123"
        #expect(producer(env.out) == expected)
        #expect(PDFDocument(url: env.out)!.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String == expected)
        // A atualização incremental não pode estragar o arquivo.
        #expect(PDFDocument(url: env.out)!.pageCount == 2)
        #expect(CGPDFDocument(env.out as CFURL)!.numberOfPages == 2)
        // Título e autor mantidos.
        let attrs = PDFDocument(url: env.out)!.documentAttributes!
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Título de teste")
        #expect(attrs[PDFDocumentAttribute.authorAttribute] as? String == "Autora de teste")
    }

    @Test func optionsOverrideAndClearMetadata() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: env.src)
        let plan = TestPDF.plan([(0, TestPDF.window(x: 0, y: 0, width: 590))], recipeID: "r1")

        try await env.write(plan, options: WriteOptions(producer: "Outro 9.9", recipeID: "r2", title: "Novo título", author: "Outro autor"))
        var attrs = PDFDocument(url: env.out)!.documentAttributes!
        #expect(producer(env.out) == "Outro 9.9 recipe:r2")
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Novo título")
        #expect(attrs[PDFDocumentAttribute.authorAttribute] as? String == "Outro autor")
        #expect(attrs[PDFDocumentAttribute.subjectAttribute] as? String == "Assunto de teste")

        try await env.write(plan, options: WriteOptions(clearMetadata: true))
        attrs = PDFDocument(url: env.out)!.documentAttributes!
        #expect(attrs[PDFDocumentAttribute.titleAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attrs[PDFDocumentAttribute.subjectAttribute] == nil)
        #expect(producer(env.out) == "iPDFmini \(PDFWriting.version) recipe:r1")

        try await env.write(plan, options: WriteOptions(title: "Só título", clearMetadata: true))
        attrs = PDFDocument(url: env.out)!.documentAttributes!
        #expect(attrs[PDFDocumentAttribute.titleAttribute] as? String == "Só título")
        #expect(attrs[PDFDocumentAttribute.authorAttribute] == nil)
    }

    @Test func producerWithNonASCIIRecipeRoundTrips() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: env.src)
        try await env.write(TestPDF.plan([(0, TestPDF.window(x: 0, y: 0, width: 590))], recipeID: "receita ção (1)"))
        #expect(producer(env.out) == "iPDFmini \(PDFWriting.version) recipe:receita ção (1)")
    }

    // MARK: warnings

    @Test func warnsAboutAspectMismatchAndOverlays() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: env.src)
        let bad = CGRect(x: 0, y: 0, width: 300, height: 300)
        var plan = TestPDF.plan([(0, bad)])
        plan.pages[0].overlays = [.continuityMark(y: 10)]
        let report = try await env.write(plan)
        #expect(report.warnings.contains { if case .aspectMismatch(0, _) = $0 { true } else { false } })
        #expect(report.warnings.contains(.overlaysIgnored(count: 1)))
    }

    // MARK: origem

    @Test func encryptedSourceNeedsPassword() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: env.src, ownerPassword: "dono", userPassword: "usuario")
        let plan = TestPDF.plan([(0, TestPDF.window(x: 0, y: 0, width: 590))])
        #expect(PDFDocument(url: env.src)!.isLocked)

        do { try await env.write(plan); Issue.record("deveria exigir senha") } catch let e as WriteError {
            #expect(e == .encryptedWithoutPassword(env.src))
        }
        do { try await env.write(plan, password: "errada"); Issue.record("deveria recusar senha") } catch let e as WriteError {
            #expect(e == .wrongPassword(env.src))
        }
        let report = try await env.write(plan, password: "usuario")
        // Sai sem senha (o PDFKit mantém um dicionário /Encrypt com senhas vazias), mas o
        // Producer não pode ser regravado: as strings do Info estão cifradas.
        let out = PDFDocument(url: env.out)!
        #expect(!out.isLocked)
        #expect(report.warnings.contains(.producerNotApplied))
        #expect((out.string ?? "").contains("p0l0"))
        expectBoxes(env.out, page: 0, size: TestPDF.window(x: 0, y: 0, width: 590).size)
    }

    @Test func missingSourceFailsToOpen() async throws {
        let env = Env(); defer { env.cleanup() }
        let plan = TestPDF.plan([(0, TestPDF.window(x: 0, y: 0, width: 300))])
        do { try await env.write(plan); Issue.record("deveria falhar") } catch let e as WriteError {
            #expect(e == .cannotOpen(env.src))
        }
    }

    @Test func unwritableDestinationThrowsWriteFailed() async throws {
        let env = Env(); defer { env.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: env.src)
        let bad = env.dir.appendingPathComponent("nao/existe/out.pdf")
        do {
            _ = try await BoxWriter().write(TestPDF.plan([(0, TestPDF.window(x: 0, y: 0, width: 300))]),
                                            source: SourceDocument(url: env.src), to: bad, options: WriteOptions())
            Issue.record("deveria falhar")
        } catch let e as WriteError {
            #expect(e == .writeFailed(bad))
        }
    }
}
