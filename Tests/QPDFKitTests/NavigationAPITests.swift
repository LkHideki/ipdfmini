import CoreGraphics
import Foundation
import PDFKit
import Synchronization
import Testing
@testable import QPDFKit

// Anotações, sumário, catálogo e Info pela C API (base do remapeamento do PlacementWriter).

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qpdfkit-nav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 2 páginas 600×800 com um quadrado, um sumário antigo (que deve sumir) e Info.
private func makeSource(_ url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Origem"] as CFDictionary))
    for _ in 0..<2 {
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 100, y: 100, width: 50, height: 50))
        ctx.endPDFPage()
    }
    ctx.closePDF()
    let doc = try #require(PDFDocument(url: url))
    let root = PDFOutline()
    let old = PDFOutline()
    old.label = "Antigo"
    old.destination = PDFDestination(page: doc.page(at: 1)!, at: CGPoint(x: 0, y: 800))
    root.insertChild(old, at: 0)
    doc.outlineRoot = root
    let tmp = url.deletingLastPathComponent().appendingPathComponent("tmp.pdf")
    try #require(doc.write(to: tmp))
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}

@Suite struct NavigationAPITests {
    @Test func annotationsOutlineInfoAndCatalogRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf"), out = dir.appendingPathComponent("out.pdf")
        try makeSource(src)

        let doc = try QPDFDocument(contentsOf: src)
        let full = QPDFRect(llx: 0, lly: 0, urx: 600, ury: 800)
        for s in 0..<2 {
            let p = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 300, ury: 400))
            try doc.place(sourcePage: s, onto: p, clip: full, matrix: QPDFMatrix(a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0))
        }
        let ref1 = try doc.outputPageReference(1)
        #expect(ref1.hasSuffix(" R"))
        try doc.addAnnotation("<< /Type /Annot /Subtype /Link /Rect [10 20 110 40] /Border [0 0 0] /Dest [\(ref1) /XYZ 5 350 null] >>", toPage: 0)
        try doc.addAnnotation("<< /Type /Annot /Subtype /Highlight /Rect [50 100 200 110] /QuadPoints [50 110 200 110 50 100 200 100] /C [1 1 0] /Contents <FEFF00E700E3006F> >>", toPage: 0)
        try doc.addAnnotation("<< /Type /Annot /Subtype /Link /Rect [0 0 50 50] /A << /S /URI /URI (https://example.org) >> >>", toPage: 1)
        try doc.setOutline([
            .init(title: "Capítulo 1", parent: nil, destination: "[\(try doc.outputPageReference(0)) /XYZ 0 400 null]", isOpen: true),
            .init(title: "1.1", parent: 0, destination: "[\(ref1) /XYZ 0 200 null]"),
            .init(title: "Sem destino", parent: nil, destination: nil),
        ])
        try doc.setCatalogEntry("/PageLabels", value: "<< /Nums [0 << /S /D /St 7 >>] >>")
        try doc.setCatalogEntry("/Names", subkey: "/Dests", value: nil)  // ausente: não é erro
        try doc.setInfo("/Producer", "iPDFmini teste recipe:x")
        try doc.setInfo("/Title", nil)
        try doc.removeSourcePages()
        try doc.write(to: out)

        let pdf = try #require(PDFDocument(url: out))
        #expect(pdf.pageCount == 2)
        let a0 = pdf.page(at: 0)!.annotations
        let link = try #require(a0.first { $0.type == "Link" })
        #expect(link.bounds == CGRect(x: 10, y: 20, width: 100, height: 20))
        #expect(link.destination.map { pdf.index(for: $0.page!) } == 1)
        #expect(link.destination?.point == CGPoint(x: 5, y: 350))
        let hl = try #require(a0.first { $0.type == "Highlight" })
        #expect(hl.contents == "ção")
        #expect(hl.quadrilateralPoints?.count == 4)
        #expect(pdf.page(at: 1)!.annotations.first?.url == URL(string: "https://example.org"))

        let root = try #require(pdf.outlineRoot)
        #expect(root.numberOfChildren == 2)
        let c1 = try #require(root.child(at: 0))
        #expect(c1.label == "Capítulo 1" && c1.isOpen && c1.numberOfChildren == 1)
        #expect(c1.destination.map { pdf.index(for: $0.page!) } == 0)
        #expect(c1.child(at: 0)?.label == "1.1")
        #expect(c1.child(at: 0)?.destination.map { pdf.index(for: $0.page!) } == 1)
        #expect(root.child(at: 1)?.label == "Sem destino" && root.child(at: 1)?.destination == nil)

        #expect(pdf.page(at: 0)?.label == "7" && pdf.page(at: 1)?.label == "8")
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String == "iPDFmini teste recipe:x")
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil)
    }

    @Test func emptyOutlineRemovesTheOldOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf"), out = dir.appendingPathComponent("out.pdf")
        try makeSource(src)
        let doc = try QPDFDocument(contentsOf: src)
        let p = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 600, ury: 800))
        try doc.place(sourcePage: 0, onto: p, clip: QPDFRect(llx: 0, lly: 0, urx: 600, ury: 800), matrix: .identity)
        #expect(PDFDocument(url: src)?.outlineRoot?.numberOfChildren == 1)
        try doc.setOutline([])
        try doc.removeSourcePages()
        try doc.write(to: out)
        #expect(PDFDocument(url: out)?.outlineRoot == nil)
    }

    /// Documentos distintos em threads distintas (conversões em paralelo). O qpdf deste build
    /// tem um map global (QTC) escrito na 1ª vez que vê cada escopo; a C API o preenche uma
    /// vez antes de tudo. A corrida só existia no 1º uso do processo (SIGSEGV raro, visto num
    /// relatório de crash), então este teste é fumaça: exercita o uso concorrente, não
    /// reproduz a corrida de forma determinística.
    @Test func concurrentDocumentsAreSafe() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf")
        try makeSource(src)
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            do {
                let doc = try QPDFDocument(contentsOf: src)
                let p = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 300, ury: 400))
                try doc.place(sourcePage: i % 2, onto: p, clip: QPDFRect(llx: 0, lly: 0, urx: 600, ury: 800),
                              matrix: QPDFMatrix(a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0))
                try doc.setInfo("/Producer", "t\(i)")
                try doc.removeSourcePages()
                try doc.write(to: dir.appendingPathComponent("out\(i).pdf"))
            } catch {
                failures.withLock { $0 += 1 }
            }
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(PDFDocument(url: dir.appendingPathComponent("out63.pdf"))?.pageCount == 1)
    }

    @Test func invalidInputIsAnArgumentError() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf")
        try makeSource(src)
        let doc = try QPDFDocument(contentsOf: src)
        let p = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 100, ury: 100))
        func kind(_ body: () throws -> Void) -> QPDFError.Kind? {
            do { try body(); return nil } catch let e as QPDFError { return e.kind } catch { return nil }
        }
        #expect(kind { try doc.addAnnotation("[1 2 3]", toPage: p) } == .invalidArgument)
        #expect(kind { try doc.addAnnotation("<< /Rect [0 0 1 1] >>", toPage: 5) } == .invalidArgument)
        #expect(kind { try doc.setCatalogEntry("PageLabels", value: "<< >>") } == .invalidArgument)
        #expect(kind { try doc.setInfo("Producer", "x") } == .invalidArgument)
        #expect(kind { try doc.setOutline([.init(title: "a", parent: 0, destination: nil)]) } == .invalidArgument)
        #expect(kind { _ = try doc.outputPageReference(3) } == .invalidArgument)
    }
}
