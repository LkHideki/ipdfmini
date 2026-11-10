import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Gerador próprio de PDFs com geometria conhecida (não depende do
// SyntheticCorpus). Verdade de tinta = contorno real dos glifos.

struct PageSpec {
    var media: CGRect
    var crop: CGRect?
    var trim: CGRect?
    var rotation: Int = 0
    var draw: (CGContext) -> Void = { _ in }
}

enum TestPDF {
    static func make(_ pages: [PageSpec], edit: ((PDFDocument) -> Void)? = nil) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var first = pages.first?.media ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: consumer, mediaBox: &first, nil)!
        for p in pages {
            var info: [CFString: Any] = [kCGPDFContextMediaBox: boxData(p.media)]
            if let c = p.crop { info[kCGPDFContextCropBox] = boxData(c) }
            if let t = p.trim { info[kCGPDFContextTrimBox] = boxData(t) }
            ctx.beginPDFPage(info as CFDictionary)
            p.draw(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        var out = data as Data
        // Anotações pelo PDFKit. Atenção: dataRepresentation() regrava a
        // MediaBox com origem (0,0) — por isso o /Rotate não passa por ele.
        if let edit {
            let doc = PDFDocument(data: out)!
            edit(doc)
            out = doc.dataRepresentation()!
        }
        let rotations = pages.enumerated().filter { $0.element.rotation != 0 }.map { ($0.offset, $0.element.rotation) }
        if !rotations.isEmpty { out = appendRotation(out, Dictionary(uniqueKeysWithValues: rotations)) }
        return out
    }

    /// Acrescenta /Rotate por atualização incremental (objetos de página
    /// regravados + nova xref), sem tocar no resto do arquivo.
    static func appendRotation(_ data: Data, _ rotations: [Int: Int]) -> Data {
        let text = String(data: data, encoding: .isoLatin1)! as NSString   // 1 byte = 1 unidade
        func firstMatch(_ pattern: String, in s: NSString, from: Int = 0) -> [String]? {
            let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            guard let m = re.firstMatch(in: s as String, range: NSRange(location: from, length: s.length - from)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : s.substring(with: m.range(at: $0)) }
        }
        // o CoreGraphics grava as páginas em ordem (a árvore /Pages pode ter vários níveis)
        let pageObjs = try! NSRegularExpression(pattern: #"(\d+) 0 obj\s*<<\s*/Type /Page[^s]"#)
            .matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map { Int(text.substring(with: $0.range(at: 1)))! }
        let trailer = firstMatch(#"trailer\s*<<(.*?)>>\s*startxref\s*(\d+)"#, in: text)!
        let size = Int(firstMatch(#"/Size (\d+)"#, in: trailer[1] as NSString)![1])!
        let root = firstMatch(#"/Root (\d+ 0 R)"#, in: trailer[1] as NSString)![1]
        var out = data
        var entries: [(Int, Int)] = []
        for (i, rot) in rotations.sorted(by: { $0.key < $1.key }) {
            let obj = pageObjs[i]
            let body = firstMatch(#"(?:^|\s)\#(obj) 0 obj\s*(<<.*?>>)\s*endobj"#, in: text)![1]
            let patched = body.replacingOccurrences(of: "/Type /Page", with: "/Type /Page /Rotate \(rot)")
            entries.append((obj, out.count + 1))
            out.append("\n\(obj) 0 obj\n\(patched)\nendobj\n".data(using: .isoLatin1)!)
        }
        let xref = out.count
        var s = "xref\n"
        for (obj, off) in entries { s += "\(obj) 1\n" + String(format: "%010d 00000 n \n", off) }
        s += "trailer\n<< /Size \(size) /Root \(root) /Prev \(trailer[2]) >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(s.data(using: .isoLatin1)!)
        return out
    }

    private static func boxData(_ r: CGRect) -> Data {
        var r = r
        return Data(bytes: &r, count: MemoryLayout<CGRect>.size)
    }
}

enum Ink {
    static let pool = [
        "the quick brown fox jumps over the lazy dog and runs away",
        "reading on a small screen needs letters of a decent size",
        "margins are cropped so that the text block fills the glass",
        "a book page without its margins is about the size of the mini",
        "we measure the x-height in points on the original page here",
        "Every analysis runs once per file and is cached on disk",
        "columns, figures and notes are segmented in a later stage",
        "small notes at the bottom of the page use a smaller size",
    ]

    static func font(_ size: CGFloat, name: String = "Times New Roman") -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    static func xHeight(_ size: CGFloat, name: String = "Times New Roman") -> CGFloat {
        CTFontGetXHeight(font(size, name: name))
    }

    /// Desenha uma linha com a linha de base em `origin` (girada de `angle`
    /// em torno dela) e devolve a caixa de tinta no espaço corrente.
    @discardableResult
    static func text(_ s: String, size: CGFloat, at origin: CGPoint, angle: CGFloat = 0, gray: CGFloat = 0,
                     font name: String = "Times New Roman", in ctx: CGContext) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, name: name),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.rotate(by: angle)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        let t = CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        return glyphBounds(line).applying(t)
    }

    /// `n` linhas de texto a partir da linha de base `top`; devolve a união da tinta.
    @discardableResult
    static func paragraph(lines n: Int, size: CGFloat, leading: CGFloat, x: CGFloat, top: CGFloat, seed: Int = 0,
                          in ctx: CGContext) -> CGRect {
        var u = CGRect.null
        for i in 0..<n {
            u = u.union(text(pool[(i + seed) % pool.count], size: size, at: CGPoint(x: x, y: top - CGFloat(i) * leading), in: ctx))
        }
        return u
    }

    static func glyphBounds(_ line: CTLine) -> CGRect {
        var u = CGRect.null
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let f = attrs[kCTFontAttributeName as String] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                guard let path = CTFontCreatePathForGlyph(f, glyphs[i], nil) else { continue }
                let b = path.boundingBoxOfPath
                if b.isNull || b.isEmpty { continue }
                u = u.union(b.offsetBy(dx: pos[i].x, dy: pos[i].y))
            }
        }
        return u
    }

    /// Imagem cinza de uma página escaneada: papel não branco com ruído,
    /// conteúdo desenhado em pontos pelo `draw`.
    static func scanImage(size: CGSize, dpi: CGFloat, paper: UInt8 = 228, draw: (CGContext) -> Void) -> CGImage {
        let scale = dpi / 72
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: CGFloat(paper) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        // ruído determinístico ±8 níveis
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for i in 0..<(w * h) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 24) % 17 - 8
            p[i] = UInt8(clamping: Int(p[i]) + noise)
        }
        return ctx.makeImage()!
    }
}
