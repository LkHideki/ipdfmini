import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import MiniGeometry
@testable import SyntheticCorpus

@Suite struct CorpusInvariantTests {
    @Test(arguments: Scenario.allCases)
    func opensWithMatchingPageCountAndRotation(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        let pdf = try #require(PDFDocument(data: doc.data))
        #expect(pdf.pageCount == doc.truth.pages.count)
        let cg = try #require(cgDocument(doc.data))
        #expect(cg.numberOfPages == doc.truth.pages.count)
        for (i, t) in doc.truth.pages.enumerated() {
            #expect(pdf.page(at: i)?.rotation == t.geometry.rotation, "página \(i + 1)")
            #expect(Int(cg.page(at: i + 1)!.rotationAngle) == t.geometry.rotation, "página \(i + 1)")
        }
    }

    @Test(arguments: Scenario.allCases)
    func inkBoxInsidePageBox(_ s: Scenario) {
        for (i, t) in Fixtures.doc(s).truth.pages.enumerated() {
            guard let ink = t.inkBox else { continue }
            #expect(t.geometry.pageBox.insetBy(dx: -0.001, dy: -0.001).contains(ink), "página \(i + 1): \(ink) fora de \(t.geometry.pageBox)")
        }
    }

    @Test(arguments: Scenario.allCases)
    func extractedTextContainsTruthWords(_ s: Scenario) {
        let doc = Fixtures.doc(s)
        let got = wordCounts(extractedWords(doc.data))
        let want = wordCounts(doc.truth.words)
        if s == .scannedPage {
            #expect(want.isEmpty && got.isEmpty, "scan não tem camada de texto")
            return
        }
        #expect(!want.isEmpty)
        let missing = want.filter { got[$0.key, default: 0] < $0.value }
        #expect(missing.isEmpty, "faltam no texto extraído: \(missing.prefix(8))")
    }

    @Test(arguments: Scenario.allCases)
    func boxesReadBackMatchTruth(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        let cg = try #require(cgDocument(doc.data))
        for (i, t) in doc.truth.pages.enumerated() {
            let p = try #require(cg.page(at: i + 1))
            let tag = "\(s) página \(i + 1)"
            #expect(close(p.getBoxRect(.mediaBox), t.mediaBox, tol: 0.01), "\(tag) media")
            // CGPDFPage devolve CropBox ∩ MediaBox, e a própria MediaBox se não há CropBox.
            #expect(close(p.getBoxRect(.cropBox), (t.cropBox ?? t.mediaBox).intersection(t.mediaBox), tol: 0.01), "\(tag) crop")
            if let trim = t.trimBox {
                #expect(close(p.getBoxRect(.trimBox), trim, tol: 0.01), "\(tag) trim")
            }
            if let bleed = t.bleedBox {
                #expect(close(p.getBoxRect(.bleedBox), bleed, tol: 0.01), "\(tag) bleed")
            }
            // A caixa efetiva da verdade é a que o analisador deve recuperar.
            let expectedEffective = t.trimBox ?? (t.cropBox ?? t.mediaBox).intersection(t.mediaBox)
            #expect(close(t.geometry.effectiveBox, expectedEffective, tol: 0.01), "\(tag) efetiva")
        }
    }

    /// A verdade de tinta bate com a rasterização real (±1 pt: antialiasing e pixel de 0,5 pt).
    @Test(arguments: Scenario.allCases)
    func inkTruthMatchesRaster(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        let cg = try #require(cgDocument(doc.data))
        for (i, t) in doc.truth.pages.enumerated() {
            let p = try #require(cg.page(at: i + 1))
            // O render cobre a CropBox inteira: inclui a tinta ignorável (carimbo, marcas).
            let all = ([t.inkBox].compactMap { $0 } + t.ignorableInk).map(t.geometry.toUser)
            let expected = union(all)
            let got = rasterInkBox(of: p)
            switch (expected, got) {
            case (nil, nil): break
            case let (e?, g?): #expect(close(e, g, tol: 1.0), "\(s) página \(i + 1): verdade \(e) × raster \(g)")
            default: Issue.record("\(s) página \(i + 1): verdade \(String(describing: expected)) × raster \(String(describing: got))")
            }
        }
    }

    @Test func navigationCounts() throws {
        let doc = Fixtures.doc(.navigation)
        let pdf = try #require(PDFDocument(data: doc.data))
        let root = try #require(pdf.outlineRoot)
        #expect(outlineTotal(root) == doc.truth.outlineCount)
        #expect(doc.truth.outlineCount == 6)
        var links = 0, internalLinks = 0, externalLinks = 0, others = 0
        for i in 0..<pdf.pageCount {
            for a in pdf.page(at: i)!.annotations {
                if a.type == "Link" {
                    links += 1
                    if a.destination != nil { internalLinks += 1 }
                    if a.url != nil { externalLinks += 1 }
                } else {
                    others += 1
                }
            }
        }
        #expect(links == doc.truth.linkCount)
        #expect(doc.truth.linkCount == 5)
        #expect(internalLinks == 4 && externalLinks == 1)
        #expect(others == doc.truth.annotationCount)
        #expect(doc.truth.annotationCount == 1)
        // Destinos do sumário resolvem para páginas existentes.
        for i in 0..<root.numberOfChildren {
            let page = try #require(root.child(at: i)?.destination?.page)
            #expect(pdf.index(for: page) >= 1)
        }
    }

    @Test func otherScenariosHaveNoNavigation() {
        for s in Scenario.allCases where s != .navigation {
            let t = Fixtures.doc(s).truth
            #expect(t.outlineCount == 0 && t.linkCount == 0 && t.annotationCount == 0, "\(s)")
        }
    }

    @Test func writeAllWritesPDFAndTruth() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticCorpusTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try Corpus.writeAll(to: dir)
        #expect(urls.count == Scenario.allCases.count * 2)
        for s in Scenario.allCases {
            let pdf = dir.appendingPathComponent("\(s.rawValue).pdf")
            let json = dir.appendingPathComponent("\(s.rawValue).truth.json")
            #expect(urls.contains(pdf) && urls.contains(json))
            let data = try Data(contentsOf: pdf)
            #expect(PDFDocument(data: data) != nil, "\(s)")
            let truth = try JSONDecoder().decode(DocumentTruth.self, from: Data(contentsOf: json))
            #expect(truth.pages.count == Fixtures.doc(s).truth.pages.count)
            #expect(truth.words == Fixtures.doc(s).truth.words)
            #expect(truth.pages.first?.geometry == Fixtures.doc(s).truth.pages.first?.geometry)
        }
    }

    @Test(arguments: [Scenario.book6x9, .navigation, .scannedPage, .rotatedPages])
    func generationIsDeterministic(_ s: Scenario) throws {
        let a = Corpus.make(s), b = Fixtures.doc(s)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        #expect(try enc.encode(a.truth) == enc.encode(b.truth))
        #expect(extractedWords(a.data) == extractedWords(b.data))
    }

    @Test func systemFontsResolve() {
        func ps(_ f: CTFont) -> String { CTFontCopyPostScriptName(f) as String }
        #expect(ps(Face.times(10)) == Face.timesName)
        #expect(ps(Face.timesBold(10)) == Face.timesBoldName)
        #expect(ps(Face.timesItalic(10)) == Face.timesItalicName)
        #expect(ps(Face.helvetica(10)) == Face.helveticaName)
        #expect(ps(Face.helveticaBold(10)) == Face.helveticaBoldName)
    }

    @Test(arguments: Scenario.allCases)
    func bodySizeAndXHeight(_ s: Scenario) {
        let t = Fixtures.doc(s).truth
        #expect(t.bodyPointSize == 10)
        // Altura-x de Times (0,448 em) e Helvetica (0,523 em) a 10 pt.
        #expect(t.bodyXHeightPt > 4.2 && t.bodyXHeightPt < 5.4, "\(t.bodyXHeightPt)")
    }
}
