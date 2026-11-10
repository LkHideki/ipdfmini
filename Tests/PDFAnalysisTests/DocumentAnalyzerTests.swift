import CoreGraphics
import CryptoKit
import Foundation
import MiniGeometry
import PDFKit
import Testing
@testable import PDFAnalysis

private func analyze(_ data: Data, concurrency: Int? = nil) async throws -> DocumentAnalysis {
    try await DocumentAnalyzer(options: .init(maxConcurrency: concurrency)).analyze(data: data)
}

private func expectRect(_ a: CGRect?, _ b: CGRect, tol: CGFloat = 1, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let a else {
        Issue.record("caixa nil, esperado \(b)", sourceLocation: sourceLocation)
        return
    }
    let d = max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    #expect(d <= tol, "obtido \(a), esperado \(b), erro \(d) pt", sourceLocation: sourceLocation)
}

private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

private func ignoredReasons(_ p: PageAnalysis) -> [String] {
    p.warnings.compactMap { if case .ignoredRegion(_, let r) = $0 { r } else { nil } }
}

// MARK: caixa de tinta

@Test func inkBoxAtExactPosition() async throws {
    var truth = CGRect.null
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        truth = Ink.paragraph(lines: 20, size: 10, leading: 12, x: 90, top: 690, in: ctx)
        let r = CGRect(x: 300, y: 120, width: 120, height: 60)
        ctx.setFillColor(gray: 0.3, alpha: 1)
        ctx.fill(r)
        truth = truth.union(r)
    }])
    let doc = try await analyze(data)
    let p = doc.pages[0]
    #expect(p.kind == .digitalText)
    expectRect(p.inkBox, truth)
    #expect(p.lines.count == 20)
}

@Test func emptyPageHasNoInkBox() async throws {
    let doc = try await analyze(TestPDF.make([PageSpec(media: letter)]))
    #expect(doc.pages[0].inkBox == nil)
    #expect(doc.pages[0].kind == .empty)
    #expect(doc.kind == .unknown)
}

@Test func markupAnnotationsEnterTheRender() async throws {
    var truth = CGRect.null
    let annRect = CGRect(x: 420, y: 80, width: 100, height: 50)
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        truth = Ink.paragraph(lines: 5, size: 10, leading: 12, x: 90, top: 600, in: ctx)
    }]) { doc in
        let a = PDFAnnotation(bounds: annRect, forType: .square, withProperties: nil)
        a.color = .black
        let b = PDFBorder()
        b.lineWidth = 3
        a.border = b
        doc.page(at: 0)!.addAnnotation(a)
    }
    let p = try await analyze(data).pages[0]
    // a borda do quadrado é desenhada dentro dos bounds da anotação
    let ink = try #require(p.inkBox)
    #expect(ink.maxX >= annRect.maxX - 2 && ink.maxX <= annRect.maxX + 1)
    #expect(ink.minY >= annRect.minY - 1 && ink.minY <= annRect.minY + 2)
    #expect(abs(ink.minX - truth.minX) <= 1 && abs(ink.maxY - truth.maxY) <= 1)
}

// MARK: geometria (§5.1)

@Test(arguments: [0, 90, 180, 270])
func rotatedPagesWithOffsetBox(rotation: Int) async throws {
    let media = CGRect(x: 30, y: 40, width: 500, height: 700)
    let g = PageGeometry(effectiveBox: media, rotation: rotation)
    var truthPage = CGRect.null
    let data = TestPDF.make([PageSpec(media: media, rotation: rotation) { ctx in
        // conteúdo autorado em espaço de página: aparece de pé após o /Rotate
        ctx.concatenate(g.pageToUser)
        let b = g.pageBox
        truthPage = Ink.paragraph(lines: 12, size: 11, leading: 14, x: b.minX + 60, top: b.maxY - 80, in: ctx)
        let r = CGRect(x: b.minX + 80, y: b.minY + 50, width: 90, height: 40)
        ctx.fill(r)
        truthPage = truthPage.union(r)
    }])
    let p = try await analyze(data).pages[0]
    #expect(p.geometry.rotation == rotation)
    #expect(p.geometry.effectiveBox == media)
    #expect(p.pageBox.size == g.displaySize)
    expectRect(p.inkBox, truthPage)
    // texto de pé após a rotação → linhas horizontais no espaço de página
    #expect(p.lines.count == 12)
    let xh = try #require(p.bodyXHeightPt)
    #expect(abs(xh - Ink.xHeight(11)) <= 0.05 * Ink.xHeight(11))

    // independente do MiniGeometry: a orientação bate com a exibição do PDFKit
    let kit = PDFDocument(data: data)!.page(at: 0)!.transform(for: .mediaBox)
    let p1 = CGPoint(x: 100, y: 100), p2 = CGPoint(x: 300, y: 500)
    let dk = CGPoint(x: p2.applying(kit).x - p1.applying(kit).x, y: p2.applying(kit).y - p1.applying(kit).y)
    let dg = CGPoint(x: g.toPage(p2).x - g.toPage(p1).x, y: g.toPage(p2).y - g.toPage(p1).y)
    #expect(abs(dk.x - dg.x) < 0.01 && abs(dk.y - dg.y) < 0.01)
}

@Test func cropBoxSmallerThanMediaWithOffsetOrigin() async throws {
    let media = CGRect(x: 100, y: 200, width: 612, height: 792)
    let crop = CGRect(x: 150, y: 260, width: 500, height: 650)
    var truth = CGRect.null
    let data = TestPDF.make([PageSpec(media: media, crop: crop) { ctx in
        truth = Ink.paragraph(lines: 10, size: 10, leading: 12, x: 200, top: 820, in: ctx)
        let r = CGRect(x: 220, y: 300, width: 100, height: 50)
        ctx.fill(r)
        truth = truth.union(r)
        // fora da CropBox, dentro da MediaBox: não conta
        ctx.fill(CGRect(x: 110, y: 210, width: 20, height: 20))
    }])
    let p = try await analyze(data).pages[0]
    #expect(p.boxes.media == media)
    #expect(p.boxes.crop == crop)
    #expect(p.geometry.effectiveBox == crop)
    expectRect(p.inkBox, truth)
}

private func printerPage(marks: Bool, truth: inout CGRect) -> PageSpec {
    let media = CGRect(x: 0, y: 0, width: 500, height: 700)
    let trim = CGRect(x: 40, y: 40, width: 420, height: 620)
    var t = CGRect.null
    let spec = PageSpec(media: media, trim: trim) { ctx in
        t = Ink.paragraph(lines: 15, size: 10, leading: 12, x: 80, top: 600, in: ctx)
        guard marks else { return }
        ctx.setLineWidth(0.5)
        for (x, y) in [(trim.minX, trim.minY), (trim.maxX, trim.minY), (trim.minX, trim.maxY), (trim.maxX, trim.maxY)] {
            let sx: CGFloat = x == trim.minX ? -1 : 1, sy: CGFloat = y == trim.minY ? -1 : 1
            ctx.move(to: CGPoint(x: x + sx * 6, y: y)); ctx.addLine(to: CGPoint(x: x + sx * 30, y: y))
            ctx.move(to: CGPoint(x: x, y: y + sy * 6)); ctx.addLine(to: CGPoint(x: x, y: y + sy * 30))
        }
        ctx.strokePath()
    }
    _ = TestPDF.make([spec])   // força o desenho para capturar a verdade
    truth = t
    return spec
}

@Test func trimBoxWithCropMarksOutside() async throws {
    var truth = CGRect.null
    let spec = printerPage(marks: true, truth: &truth)
    let p = try await analyze(TestPDF.make([spec])).pages[0]
    #expect(p.boxes.trim == CGRect(x: 40, y: 40, width: 420, height: 620))
    #expect(p.geometry.effectiveBox == CGRect(x: 40, y: 40, width: 420, height: 620))
    #expect(ignoredReasons(p) == ["cropMarks"])
    expectRect(p.inkBox, truth)
}

@Test func trimBoxWithoutMarksKeepsCropBox() async throws {
    var truth = CGRect.null
    let spec = printerPage(marks: false, truth: &truth)
    let p = try await analyze(TestPDF.make([spec])).pages[0]
    #expect(p.geometry.effectiveBox == CGRect(x: 0, y: 0, width: 500, height: 700))
    #expect(ignoredReasons(p).isEmpty)
    expectRect(p.inkBox, truth)
}

// MARK: elementos que enganam (§5.4)

@Test func arXivStampExcludedOnlyOnFirstPage() async throws {
    var body = [CGRect](repeating: .null, count: 2)
    var stamp = [CGRect](repeating: .null, count: 2)
    let pages = (0..<2).map { i in
        PageSpec(media: letter) { ctx in
            body[i] = Ink.paragraph(lines: 30, size: 10, leading: 12, x: 108, top: 700, seed: i, in: ctx)
            stamp[i] = Ink.text("arXiv:2401.01234v1  [cs.CV]  1 Jan 2024", size: 20, at: CGPoint(x: 32, y: 230),
                                angle: .pi / 2, gray: 0.5, in: ctx)
        }
    }
    let doc = try await analyze(TestPDF.make(pages))
    expectRect(doc.pages[0].inkBox, body[0])
    #expect(ignoredReasons(doc.pages[0]) == ["arXivStamp"])
    // carimbo fora da página 1 não é do arXiv: fica na tinta
    expectRect(doc.pages[1].inkBox, body[1].union(stamp[1]))
    #expect(ignoredReasons(doc.pages[1]).isEmpty)
}

@Test func repeatedHeaderAndPageNumberDetectedButKept() async throws {
    let media = CGRect(x: 0, y: 0, width: 432, height: 648)
    var tops = [CGRect](repeating: .null, count: 6)
    var bottoms = [CGRect](repeating: .null, count: 6)
    let pages = (0..<6).map { i in
        PageSpec(media: media) { ctx in
            tops[i] = Ink.text("Chapter 3. The Long Road Home", size: 9, at: CGPoint(x: 140, y: 610), in: ctx)
            Ink.paragraph(lines: 30 - i, size: 10, leading: 13, x: 54, top: 580, seed: i, in: ctx)
            bottoms[i] = Ink.text("\(41 + i)", size: 9, at: CGPoint(x: 210, y: 30), in: ctx)
        }
    }
    let doc = try await analyze(TestPDF.make(pages))
    #expect(doc.kind == .book)
    for (i, p) in doc.pages.enumerated() {
        let hf = p.blocks.filter { $0.type == .headerFooter }
        #expect(hf.count == 2, "página \(i): \(hf.count) blocos")
        // mantidos na caixa de tinta
        let ink = try #require(p.inkBox)
        #expect(abs(ink.maxY - tops[i].maxY) <= 1 && abs(ink.minY - bottoms[i].minY) <= 1)
    }
}

@Test func footnotesAreNotHeaderFooter() async throws {
    // nota de rodapé nunca se repete entre páginas: nada vira cabeçalho/rodapé
    let pages = (0..<5).map { i in
        PageSpec(media: letter) { ctx in
            Ink.paragraph(lines: 40, size: 10, leading: 12, x: 72, top: 700, seed: i, in: ctx)
            Ink.text("\(i + 1) " + Ink.pool[(i + 4) % Ink.pool.count], size: 8, at: CGPoint(x: 72, y: 60), in: ctx)
        }
    }
    let doc = try await analyze(TestPDF.make(pages))
    for p in doc.pages { #expect(p.blocks.isEmpty) }
}

// MARK: métricas de texto (§5.5)

@Test(arguments: [8.0, 10.0, 12.0, 14.0] as [CGFloat])
func bodyXHeightWithinFivePercent(size: CGFloat) async throws {
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        Ink.paragraph(lines: 25, size: size, leading: size * 1.25, x: 72, top: 720, in: ctx)
    }])
    let doc = try await analyze(data)
    let truth = Ink.xHeight(size)
    let xh = try #require(doc.pages[0].bodyXHeightPt)
    #expect(abs(xh - truth) <= 0.05 * truth, "medido \(xh), verdade \(truth)")
    let docXh = try #require(doc.bodyXHeightPt)
    #expect(abs(docXh - truth) <= 0.05 * truth)
}

@Test func smallestXHeightFindsNotes() async throws {
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        Ink.paragraph(lines: 30, size: 11, leading: 14, x: 72, top: 720, in: ctx)
        Ink.paragraph(lines: 6, size: 8, leading: 10, x: 72, top: 200, seed: 3, in: ctx)
    }])
    let p = try await analyze(data).pages[0]
    let body = try #require(p.bodyXHeightPt), small = try #require(p.smallestXHeightPt)
    #expect(abs(body - Ink.xHeight(11)) <= 0.05 * Ink.xHeight(11), "corpo \(body)")
    #expect(abs(small - Ink.xHeight(8)) <= 0.05 * Ink.xHeight(8), "notas \(small)")
    let line = try #require(p.lines.first)
    // linha de base da primeira linha em y = 720
    #expect(abs(line.baseline - 720) <= 0.5)
}

// MARK: classificação (§5.2)

@Test func scannedPageIsScanWithReasonableInkBox() async throws {
    let media = CGRect(x: 0, y: 0, width: 420, height: 595)
    var truth = CGRect.null
    let image = Ink.scanImage(size: media.size, dpi: 150) { ctx in
        truth = Ink.paragraph(lines: 30, size: 10, leading: 13, x: 60, top: 540, in: ctx)
        // sombra de lombada colada na borda esquerda
        ctx.setFillColor(gray: 0.25, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 595))
        // salpicos isolados nas margens
        ctx.setFillColor(gray: 0.3, alpha: 1)
        for (x, y) in [(30.0, 570.0), (390.0, 40.0), (400.0, 300.0), (200.0, 20.0)] {
            ctx.fill(CGRect(x: x, y: y, width: 0.6, height: 0.6))
        }
    }
    let data = TestPDF.make([PageSpec(media: media) { ctx in ctx.draw(image, in: media) }])
    let doc = try await analyze(data)
    let p = doc.pages[0]
    #expect(p.kind == .scan)
    #expect(p.warnings.contains(.noTextFound))
    expectRect(p.inkBox, truth, tol: 3)
    #expect(doc.kind == .scannedBook)
    let xh = try #require(p.bodyXHeightPt)
    #expect(abs(xh - Ink.xHeight(10)) <= 0.10 * Ink.xHeight(10), "altura-x no scan \(xh)")
}

@Test func twoColumnLetterIsArticle() async throws {
    let pages = (0..<3).map { i in
        PageSpec(media: letter) { ctx in
            for (j, x) in [54.0, 320.0].enumerated() {
                Ink.paragraph(lines: 50, size: 9, leading: 11, x: x, top: 720, seed: i + j, in: ctx)
            }
        }
    }
    let doc = try await analyze(TestPDF.make(pages))
    #expect(doc.kind == .twoColumnArticle)
}

@Test func oneColumnLetterIsReport() async throws {
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        Ink.paragraph(lines: 40, size: 10, leading: 13, x: 72, top: 720, in: ctx)
    }])
    #expect(try await analyze(data).kind == .a4Report)
}

@Test func landscapeIsSlides() async throws {
    let media = CGRect(x: 0, y: 0, width: 720, height: 405)
    let data = TestPDF.make((0..<3).map { _ in PageSpec(media: media) { ctx in
        Ink.text("A slide title", size: 32, at: CGPoint(x: 60, y: 320), in: ctx)
        Ink.paragraph(lines: 4, size: 20, leading: 30, x: 60, top: 250, in: ctx)
    } })
    #expect(try await analyze(data).kind == .slides)
}

@Test func farAwayRuleRaisesDivergenceWarning() async throws {
    let data = TestPDF.make([PageSpec(media: letter) { ctx in
        Ink.paragraph(lines: 10, size: 10, leading: 12, x: 90, top: 600, in: ctx)
        ctx.fill(CGRect(x: 90, y: 100, width: 400, height: 0.5))
    }])
    let p = try await analyze(data).pages[0]
    let d = p.warnings.compactMap { if case .inkBoxDivergence(let v) = $0 { v } else { nil } }
    #expect(d.count == 1 && d[0] > 100)
}

// MARK: documento, concorrência, orçamento

@Test func multiPageParallelIsDeterministic() async throws {
    let pages = (0..<12).map { i in
        PageSpec(media: i % 3 == 2 ? CGRect(x: 0, y: 0, width: 792, height: 612) : letter,
                 rotation: i % 4 == 3 ? 90 : 0) { ctx in
            Ink.paragraph(lines: 10 + i, size: 9 + CGFloat(i % 3), leading: 13, x: 60 + CGFloat(i), top: 560, seed: i, in: ctx)
        }
    }
    let data = TestPDF.make(pages)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfanalysis-\(UUID().uuidString).pdf")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let parallel = try await DocumentAnalyzer().analyze(url: url)
    let again = try await analyze(data)
    let serial = try await analyze(data, concurrency: 1)
    #expect(parallel == again)
    #expect(parallel == serial)
    #expect(parallel.pageCount == 12)
    #expect(parallel.pages.map(\.index) == Array(0..<12))
    #expect(parallel.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    #expect(parallel.pages[3].geometry.rotation == 90)
}

@Test func unreadableDataThrows() async throws {
    await #expect(throws: AnalysisError.unreadable) {
        try await analyze(Data("not a pdf".utf8))
    }
}

@Test func digitalPageBudget() async throws {
    let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    let n = 10
    let data = TestPDF.make((0..<n).map { i in
        PageSpec(media: a4) { ctx in
            Ink.paragraph(lines: 55, size: 10, leading: 13, x: 72, top: 780, seed: i, in: ctx)
        }
    })
    _ = try await analyze(data, concurrency: 1)   // aquece fontes e caches do PDFKit
    let clock = ContinuousClock()
    let t = try await clock.measure { _ = try await analyze(data, concurrency: 1) }
    let ms = Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1000
    let perPage = ms / Double(n)
    print("PDFAnalysis: \(String(format: "%.1f", perPage)) ms por página digital A4 (serial, \(n) páginas)")
    // teto folgado para build de debug; o orçamento do §16 é 40 ms em release
    #expect(perPage < 150)
}
