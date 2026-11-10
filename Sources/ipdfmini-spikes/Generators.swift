import Foundation
import CoreGraphics
import CoreText

/// Geradores de PDFs de entrada (CoreGraphics + CoreText, texto real e extraível).
enum Gen {
    static let a4 = CGSize(width: 595.28, height: 841.89)
    static let textLineCount = 44

    enum Kind: Sendable { case text, image }

    static let words = ["leitura", "pagina", "margem", "texto", "tela", "letra", "corpo", "linha",
                        "coluna", "fonte", "escala", "recorte", "imagem", "titulo", "nota", "figura",
                        "tabela", "mancha", "janela", "visor"]

    /// Marcador único de linha, ex. "P07L12" (página 7, linha 12).
    static func token(_ page: Int, _ line: Int) -> String {
        String(format: "P%02dL%02d", page + 1, line + 1)
    }

    static func sentence(page: Int, line: Int) -> String {
        let ws = (0..<11).map { words[(page * 7 + line * 3 + $0 * 5) % words.count] }
        return token(page, line) + " " + ws.joined(separator: " ")
    }

    /// Linhas de base de cada tipo de documento (espaço PDF, y para cima).
    static func baselines(_ kind: Kind, pageHeight h: CGFloat) -> [CGFloat] {
        switch kind {
        case .text: return (0..<textLineCount).map { h - 60 - 16 * CGFloat($0) }
        case .image: return (0..<3).map { h - 50 - 16 * CGFloat($0) }
        }
    }

    // MARK: Primitivas

    static func drawLine(_ ctx: CGContext, _ s: String, font: CTFont, x: CGFloat, y: CGFloat) {
        let attrs = [kCTFontAttributeName as String: font] as CFDictionary
        guard let astr = CFAttributedStringCreate(nil, s as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(astr)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    static func writePDF(at url: URL, pages: Int, size: CGSize, draw: (CGContext, Int) -> Void) throws {
        var box = CGRect(origin: .zero, size: size)
        let aux = [kCGPDFContextCreator as String: "ipdfmini-spikes"] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux) else {
            throw SpikeError("CGContext PDF não criado em \(url.path)")
        }
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            draw(ctx, p)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: Documentos

    /// N páginas A4 de texto: 44 linhas de Times New Roman 11 pt com marcador por linha.
    static func makeTextDocument(at url: URL, pages: Int) throws {
        let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
        let ys = baselines(.text, pageHeight: a4.height)
        try writePDF(at: url, pages: pages, size: a4) { ctx, p in
            for (l, y) in ys.enumerated() { drawLine(ctx, sentence(page: p, line: l), font: font, x: 56, y: y) }
        }
    }

    /// N páginas A4, cada uma com 3 linhas de texto e uma imagem RGB 2000×2800 com ruído.
    static func makeImageDocument(at url: URL, pages: Int) throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let ys = baselines(.image, pageHeight: a4.height)
        try writePDF(at: url, pages: pages, size: a4) { ctx, p in
            for (l, y) in ys.enumerated() { drawLine(ctx, sentence(page: p, line: l), font: font, x: 56, y: y) }
            if let img = noiseImage(width: 2000, height: 2800, seed: UInt64(p + 1)) {
                ctx.draw(img, in: CGRect(x: 47.64, y: 50, width: 500, height: 700))
            }
        }
    }

    /// Gradiente + ruído de 5 bits por canal: não comprime de forma trivial.
    static func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt8.self)
            var s: UInt64 = (seed &* 0x9E37_79B9_7F4A_7C15) | 1
            for y in 0..<height {
                for x in 0..<width {
                    s ^= s << 13; s ^= s >> 7; s ^= s << 17
                    let base = (x * 255 / width + y * 255 / height) / 2
                    let o = (y * width + x) * 4
                    px[o] = UInt8(clamping: base + Int(s & 0x1F))
                    px[o + 1] = UInt8(clamping: 255 - base / 2 + Int((s >> 8) & 0x1F))
                    px[o + 2] = UInt8(clamping: base / 3 + Int((s >> 16) & 0x1F))
                    px[o + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
