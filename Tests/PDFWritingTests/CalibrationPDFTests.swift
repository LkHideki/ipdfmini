import Foundation
import CoreGraphics
import PDFKit
import Testing
import MiniGeometry
@testable import PDFWriting

@Suite struct CalibrationPDFTests {
    @Test(arguments: Orientation.allCases)
    func pageIsFullScreen(_ o: Orientation) throws {
        let data = CalibrationPDF.make(orientation: o)
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        let full = MiniPage.full(o)
        let bounds = doc.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(bounds.width - full.width) < 0.01 && abs(bounds.height - full.height) < 0.01)
        let cg = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let box = cg.page(at: 1)!.getBoxRect(.mediaBox)
        #expect(abs(box.width - full.width) < 0.01 && abs(box.height - full.height) < 0.01)
        #expect(box.origin == .zero)
    }

    @Test(arguments: Orientation.allCases)
    func textContainsLadderLabels(_ o: Orientation) throws {
        let doc = try #require(PDFDocument(data: CalibrationPDF.make(orientation: o)))
        let text = doc.string ?? ""
        for label in ["7,5 pt — mínimo", "9,6 pt — alvo", "11,5 pt — máximo", "5 pt · altura-x", "14 pt · altura-x"] {
            #expect(text.contains(label), "faltou \"\(label)\" em: \(text)")
        }
        for entry in CalibrationPDF.ladder() {
            #expect(text.contains(entry.label), "faltou \"\(entry.label)\"")
        }
        #expect(text.contains("mm") && text.contains("pt"))
    }

    @Test func ladderSpansFiveToFourteenWithLegibilityMarks() {
        let ladder = CalibrationPDF.ladder()
        #expect(ladder.first?.pointSize == 5 && ladder.last?.pointSize == 14)
        #expect(ladder.map(\.pointSize) == ladder.map(\.pointSize).sorted())
        let marks = ladder.filter { e in ["mínimo", "alvo", "máximo"].contains { e.label.contains($0) } }
        #expect(marks.count == 3)
        // Mínimo = 1,25 mm de altura-x → 7,5 pt equivalentes.
        #expect(ladder.contains { $0.pointSize == 7.5 && $0.label.hasPrefix("7,5 pt — mínimo") })
        // Perfil "letra grande" move os marcos.
        let large = CalibrationPDF.ladder(.largePrint)
        #expect(large.contains { $0.label.contains("mínimo") && $0.pointSize > 10 })
    }

    @Test func decimalUsesCommaAndDropsEmptyFraction() {
        #expect(CalibrationPDF.decimal(7.5, 1) == "7,5")
        #expect(CalibrationPDF.decimal(6, 1) == "6")
        #expect(CalibrationPDF.decimal(1.2434, 2) == "1,24")
        #expect(CalibrationPDF.decimal(328.64, 2) == "328,64")
    }

    /// Texto da escada e do cabeçalho dentro da página e longe das réguas (57 pt de alcance).
    @Test(arguments: Orientation.allCases)
    func ladderStaysInsideTheCenterArea(_ o: Orientation) throws {
        let doc = try #require(PDFDocument(data: CalibrationPDF.make(orientation: o)))
        let page = doc.page(at: 0)!
        let full = MiniPage.full(o)
        for entry in CalibrationPDF.ladder() {
            let hit = try #require(doc.findString(entry.label, withOptions: []).first, "\(entry.label)")
            let r = hit.bounds(for: page)
            #expect(r.minX >= 64 && r.maxX <= full.width - 64, "\(entry.label): \(r)")
            #expect(r.minY >= 62 && r.maxY <= full.height - 62, "\(entry.label): \(r)")
        }
    }

    /// Há tinta nas quatro bordas (réguas) e nos quatro cantos (arcos): o arquivo não é só texto.
    @Test(arguments: Orientation.allCases)
    func rulersAndCornerArcsAreDrawn(_ o: Orientation) throws {
        let data = CalibrationPDF.make(orientation: o)
        let page = CGPDFDocument(CGDataProvider(data: data as CFData)!)!.page(at: 1)!
        let full = MiniPage.full(o)
        let w = Int(full.width.rounded(.up)), h = Int(full.height.rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.drawPDFPage(page)
        let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func ink(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var n = 0
            for row in y0..<y1 { for x in x0..<x1 where buf[row * w + x] < 140 { n += 1 } }
            return n
        }
        // Memória: linha 0 = topo. Faixas de 6 pt junto a cada borda, no meio das réguas (30% e 70%).
        let strip = 6
        #expect(ink(0, 0, w, strip) > 0, "topo")
        #expect(ink(0, h - strip, w, h) > 0, "base")
        #expect(ink(0, 0, strip, h) > 0, "esquerda")
        #expect(ink(w - strip, 0, w, h) > 0, "direita")
        let c = Int(MiniDevice.cornerRadiusPt * 2)
        #expect(ink(0, 0, c, c) > 0 && ink(w - c, 0, w, c) > 0 && ink(0, h - c, c, h) > 0 && ink(w - c, h - c, w, h) > 0, "cantos")
    }

    @Test func writeToURLProducesReadablePDF() throws {
        let dir = TestPDF.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("calibracao.pdf")
        try CalibrationPDF.write(to: url, orientation: .landscape)
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 1)
        let b = doc.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(b.width - MiniPage.fullLandscape.width) < 0.01)
    }

    /// As leituras do usuário alimentam o perfil: "primeiro número visível" = pontos escondidos.
    @Test func readingsFeedCalibratedProfile() {
        let p = ViewportProfile.calibrated(id: "cal", hiddenTop: 10, hiddenBottom: 5, hiddenLeft: 0, hiddenRight: 0)
        #expect(abs(p.sizePt.height - (MiniPage.fullPortrait.height - 15)) < 0.001)
        #expect(p.sizePt.width == MiniPage.fullPortrait.width)
    }
}
