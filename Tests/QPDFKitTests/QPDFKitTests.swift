import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import QPDFKit

// MARK: - Fixtures

private let a4 = CGSize(width: 595.28, height: 841.89)
private let sliceCount = 3
private let sourcePages = 20

private enum Ink: Int, CaseIterable {
    case red, green, blue

    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .red: (255, 0, 0)
        case .green: (0, 255, 0)
        case .blue: (0, 0, 255)
        }
    }
}

/// Altura de cada fatia e centro vertical dela no espaço da origem (fatia 0 = topo).
private func sliceHeight() -> Double { a4.height / Double(sliceCount) }
private func sliceCenterY(_ k: Int) -> Double { a4.height - (Double(k) + 0.5) * sliceHeight() }

/// Retângulo de tinta conhecido: x ∈ [100, 200], centrado na fatia, 40 pt de altura.
private func inkRect(_ k: Int) -> CGRect {
    CGRect(x: 100, y: sliceCenterY(k) - 20, width: 100, height: 40)
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qpdfkit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 20 páginas A4 de texto corrido (CoreText) + um retângulo colorido por terço + uma marca
/// textual única por fatia ("MARKp-k"), em x = 300.
private func makeSourceDocument(at url: URL) throws {
    var box = CGRect(origin: .zero, size: a4)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    let words = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua leitura acessível páginas pequenas fatias reflow vetorial".split(separator: " ")
    var seed: UInt64 = 42
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(seed >> 33)
    }
    let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
    let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    for p in 0..<sourcePages {
        ctx.beginPDFPage(nil)
        var text = "DOC\(p)\n\n"
        for _ in 0..<14 {
            text += (0..<110).map { _ in String(words[next() % words.count]) }.joined(separator: " ") + "\n\n"
        }
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [fontKey: font]))
        let path = CGPath(rect: CGRect(x: 56, y: 56, width: 483, height: 730), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        for k in 0..<sliceCount {
            let c = Ink(rawValue: k)!.rgb
            ctx.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
            ctx.fill(inkRect(k))
            ctx.setFillColor(gray: 0, alpha: 1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MARK\(p)-\(k)", attributes: [fontKey: font]))
            ctx.textPosition = CGPoint(x: 300, y: sliceCenterY(k))
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Página PDFKit desenhada em bitmap RGBA com 1 px/pt sobre fundo branco.
private struct Raster {
    let width: Int, height: Int
    let data: [UInt8]

    init(page: PDFPage) {
        let size = page.bounds(for: .mediaBox).size
        let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            page.draw(with: .mediaBox, to: ctx)
        }
        width = w
        height = h
        data = bytes
    }

    /// Pixel no espaço PDF (origem embaixo à esquerda).
    func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let row = height - 1 - y
        let i = (row * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    func matches(_ ink: Ink, x: Int, y: Int, tolerance: Int = 50) -> Bool {
        let p = pixel(x: x, y: y), c = ink.rgb
        return abs(p.r - Int(c.r)) <= tolerance && abs(p.g - Int(c.g)) <= tolerance && abs(p.b - Int(c.b)) <= tolerance
    }

    func isWhite(x: Int, y: Int, tolerance: Int = 12) -> Bool {
        let p = pixel(x: x, y: y)
        return p.r >= 255 - tolerance && p.g >= 255 - tolerance && p.b >= 255 - tolerance
    }

    /// Quantos pixels têm a cor dada (com tolerância).
    func count(_ ink: Ink, tolerance: Int = 50) -> Int {
        var n = 0
        for y in 0..<height { for x in 0..<width where matches(ink, x: x, y: y, tolerance: tolerance) { n += 1 } }
        return n
    }
}

private func fileSize(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
}

// MARK: - Testes

@Suite struct QPDFKitTests {
    /// Critério de aceite do PlacementWriter: 20 páginas A4 × 3 fatias = 60 páginas.
    @Test func slicesEveryPageIntoThreeAndKeepsSizeAndContent() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf"), out = dir.appendingPathComponent("out.pdf")
        try makeSourceDocument(at: src)

        let doc = try QPDFDocument(contentsOf: src)
        #expect(try doc.sourcePageCount == sourcePages)
        let bh = sliceHeight()
        for p in 0..<sourcePages {
            let info = try doc.sourcePageInfo(at: p)
            #expect(abs(info.mediaBox.width - a4.width) < 0.01 && abs(info.mediaBox.height - a4.height) < 0.01)
            for k in 0..<sliceCount {
                let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: a4.width, ury: bh))
                #expect(page == p * sliceCount + k)
                let bottom = a4.height - Double(k + 1) * bh
                try doc.place(
                    sourcePage: p, onto: page,
                    clip: QPDFRect(llx: 0, lly: bottom, urx: a4.width, ury: bottom + bh),
                    matrix: .translation(x: 0, y: -bottom))
            }
        }
        try doc.removeSourcePages()
        try doc.write(to: out)

        // O Form de cada origem é compartilhado pelas 3 fatias: o arquivo não cresce.
        let ratio = Double(try fileSize(out)) / Double(try fileSize(src))
        print("QPDFKit ratio saída/origem = \(ratio)")
        #expect(ratio <= 1.3, "razão \(ratio)")

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == sourcePages * sliceCount)
        for p in 0..<sourcePages {
            for k in 0..<sliceCount {
                let page = try #require(result.page(at: p * sliceCount + k))
                let size = page.bounds(for: .mediaBox).size
                #expect(abs(size.width - a4.width) < 0.01 && abs(size.height - bh) < 0.01)
                // O PDFKit respeita o clip na extração: cada fatia só devolve o texto da própria faixa.
                // "DOCp" está no topo da página (fatia 0); "MARKp-k" no centro da fatia k.
                let text = page.string ?? ""
                #expect(text.contains("DOC\(p)") == (k == 0), "página \(p)/\(k): DOC")
                for j in 0..<sliceCount {
                    #expect(text.contains("MARK\(p)-\(j)") == (j == k), "página \(p)/\(k): MARK\(p)-\(j)")
                }
                #expect(text.count > 200, "página \(p)/\(k) quase sem texto")
            }
        }
        // Render: a fatia k mostra a própria cor, no lugar certo, e nenhuma outra.
        for p in [0, 7, sourcePages - 1] {
            for k in 0..<sliceCount {
                let raster = Raster(page: try #require(result.page(at: p * sliceCount + k)))
                let rect = inkRect(k)
                let cx = Int(rect.midX)
                let cy = Int((bh / 2).rounded())  // centro do retângulo na fatia
                #expect(raster.matches(Ink(rawValue: k)!, x: cx, y: cy), "fatia \(p)/\(k) sem a cor esperada")
                // Bordas do retângulo: 20 pt acima/abaixo do centro, 100 pt de largura.
                #expect(raster.matches(Ink(rawValue: k)!, x: Int(rect.minX) + 3, y: cy + 17))
                #expect(raster.matches(Ink(rawValue: k)!, x: Int(rect.maxX) - 3, y: cy - 17))
                for other in Ink.allCases where other.rawValue != k {
                    #expect(raster.count(other) == 0, "fatia \(p)/\(k) tem tinta de \(other)")
                }
                let area = raster.count(Ink(rawValue: k)!)
                #expect(abs(Double(area) - 100 * 40) < 100 * 40 * 0.1, "área da tinta \(area)")
            }
        }
    }

    /// O clip recorta no espaço da origem: o conteúdo fora dele não aparece mesmo cabendo na página.
    @Test func clipCutsInSourceSpace() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf"), out = dir.appendingPathComponent("out.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ctx = try #require(CGContext(src as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 50, y: 50, width: 300, height: 300))
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try QPDFDocument(contentsOf: src)
        let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 400, ury: 400))
        // Clip [100,100]-[300,300]; matriz desloca (+20, +10) para provar a ordem clip/matriz.
        try doc.place(
            sourcePage: 0, onto: page, clip: QPDFRect(llx: 100, lly: 100, urx: 300, ury: 300),
            matrix: .translation(x: 20, y: 10))
        try doc.removeSourcePages()
        try doc.write(to: out)

        let raster = Raster(page: try #require(PDFDocument(url: out)?.page(at: 0)))
        #expect(raster.matches(.red, x: 130, y: 120))  // dentro do clip deslocado
        #expect(raster.matches(.red, x: 318, y: 308))
        #expect(raster.isWhite(x: 110, y: 120))  // origem x < 100: fora do clip
        #expect(raster.isWhite(x: 130, y: 105))  // origem y < 100: fora do clip
        #expect(raster.isWhite(x: 325, y: 200))  // origem x > 300: fora do clip, embora a tinta vá até 350
        #expect(raster.isWhite(x: 200, y: 315))
        let area = raster.count(.red)
        #expect(abs(Double(area) - 200 * 200) < 200 * 200 * 0.02, "área \(area)")
    }

    @Test func appendedContentUsesRegisteredHelvetica() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf"), out = dir.appendingPathComponent("out.pdf")
        try makeSourceDocument(at: src)

        let doc = try QPDFDocument(contentsOf: src)
        let bh = sliceHeight()
        let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: a4.width, ury: bh))
        try doc.place(sourcePage: 3, onto: page, clip: QPDFRect(llx: 0, lly: 0, urx: a4.width, ury: bh), matrix: .identity)
        try doc.appendContent("BT /IPMHelv 12 Tf 10 10 Td (OVERLAYZZ 3/20) Tj ET", toPage: page)
        let empty = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 200, ury: 100))
        try doc.appendContent("BT /IPMHelv 10 Tf 5 5 Td (SOLOZZ) Tj ET", toPage: empty)
        #expect(try doc.outputPageCount == 2)
        try doc.removeSourcePages()
        try doc.removeSourcePages()  // idempotente
        try doc.write(to: out)

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 2)
        #expect(result.page(at: 0)?.string?.contains("OVERLAYZZ 3/20") == true)
        // Clip = faixa de baixo (altura bh da origem): o título do topo (DOC3) fica de fora e o corpo continua extraível.
        #expect(result.page(at: 0)?.string?.contains("DOC3") == false)
        #expect((result.page(at: 0)?.string?.count ?? 0) > 200)
        #expect(result.page(at: 1)?.string?.contains("SOLOZZ") == true)
    }

    @Test func reportsBoxesAndRotation() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.pdf"), src = dir.appendingPathComponent("src.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(plain as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let pdf = try #require(PDFDocument(url: plain))
        let second = try #require(pdf.page(at: 1))
        second.setBounds(CGRect(x: 36, y: 72, width: 400, height: 600), for: .cropBox)
        second.rotation = 90
        #expect(pdf.write(to: src))

        let doc = try QPDFDocument(contentsOf: src)
        let first = try doc.sourcePageInfo(at: 0)
        #expect(first.mediaBox == QPDFRect(llx: 0, lly: 0, urx: 612, ury: 792))
        #expect(first.cropBox == first.mediaBox)
        #expect(first.rotation == 0)
        let info = try doc.sourcePageInfo(at: 1)
        #expect(info.rotation == 90)
        #expect(abs(info.cropBox.width - 400) < 0.01 && abs(info.cropBox.height - 600) < 0.01)
        #expect(abs(info.mediaBox.width - 612) < 0.01)
    }

    @Test func missingFileThrowsIOError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nao-existe-\(UUID().uuidString).pdf")
        let error = #expect(throws: QPDFError.self) { try QPDFDocument(contentsOf: url) }
        #expect(error?.kind == .io)
        #expect(error?.message.isEmpty == false)
    }

    @Test func corruptedFilesThrowDamagedError() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("garbage.pdf")
        try Data("isto nao e um PDF".utf8).write(to: garbage)
        let empty = dir.appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        let truncated = dir.appendingPathComponent("truncated.pdf")
        let src = dir.appendingPathComponent("src.pdf")
        try makeSourceDocument(at: src)
        try Data(contentsOf: src).prefix(2_000).write(to: truncated)  // cabeçalho válido, corpo cortado

        for url in [garbage, empty, truncated] {
            let error = #expect(throws: QPDFError.self, "\(url.lastPathComponent)") { try QPDFDocument(contentsOf: url) }
            #expect(error?.kind == .damaged, "\(url.lastPathComponent): \(String(describing: error))")
        }
    }

    @Test func encryptedDocumentNeedsPassword() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("enc.pdf"), out = dir.appendingPathComponent("out.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let info: [CFString: Any] = [kCGPDFContextUserPassword: "segredo", kCGPDFContextOwnerPassword: "dono"]
        let ctx = try #require(CGContext(src as CFURL, mediaBox: &box, info as CFDictionary))
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        ctx.endPDFPage()
        ctx.closePDF()

        let missing = #expect(throws: QPDFError.self) { try QPDFDocument(contentsOf: src) }
        #expect(missing?.kind == .password)
        let wrong = #expect(throws: QPDFError.self) { try QPDFDocument(contentsOf: src, password: "errada") }
        #expect(wrong?.kind == .password)

        let doc = try QPDFDocument(contentsOf: src, password: "segredo")
        let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 300, ury: 300))
        try doc.place(sourcePage: 0, onto: page, clip: QPDFRect(llx: 0, lly: 0, urx: 300, ury: 300), matrix: .identity)
        try doc.removeSourcePages()
        try doc.write(to: out)
        let result = try #require(PDFDocument(url: out))
        #expect(!result.isEncrypted)  // saída sem senha
        #expect(result.pageCount == 1)
    }

    @Test func invalidArgumentsThrowWithoutCrashing() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.pdf")
        try makeSourceDocument(at: src)
        let doc = try QPDFDocument(contentsOf: src)
        let r = QPDFRect(llx: 0, lly: 0, urx: 10, ury: 10)

        #expect(throws: QPDFError.self) { try doc.sourcePageInfo(at: sourcePages) }
        #expect(throws: QPDFError.self) { try doc.sourcePageInfo(at: -1) }
        #expect(throws: QPDFError.self) { try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: 0, ury: 10)) }
        #expect(throws: QPDFError.self) { try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: .nan, ury: 10)) }
        #expect(throws: QPDFError.self) { try doc.place(sourcePage: 0, onto: 0, clip: r, matrix: .identity) }  // sem página de saída
        let page = try doc.addPage(mediaBox: r)
        #expect(throws: QPDFError.self) { try doc.place(sourcePage: 99, onto: page, clip: r, matrix: .identity) }
        let nan = QPDFMatrix(a: .nan, b: 0, c: 0, d: 1, e: 0, f: 0)
        #expect(throws: QPDFError.self) { try doc.place(sourcePage: 0, onto: page, clip: r, matrix: nan) }
        #expect(throws: QPDFError.self) { try doc.appendContent("q Q", toPage: 5) }

        let unwritable = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.pdf")
        let error = #expect(throws: QPDFError.self) { try doc.write(to: unwritable) }
        #expect(error?.kind == .io)
    }
}
