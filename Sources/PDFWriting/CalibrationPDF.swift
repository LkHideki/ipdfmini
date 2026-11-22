import Foundation
import CoreGraphics
import CoreText
import MiniGeometry

/// PDF de calibração de viewport.
///
/// Uma página em tela cheia com réguas nas quatro bordas. O número impresso
/// ao lado de cada traço é a distância até a borda; o usuário abre o arquivo
/// no leitor real, anota o primeiro número visível em cada borda e o app
/// trata tudo antes dele como escondido (`ViewportProfile.calibrated`).
public enum CalibrationPDF {
    public static func make(orientation: Orientation) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: MiniPage.full(orientation))
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "iPDFmini — calibração (\(orientation == .portrait ? "retrato" : "paisagem"))",
            kCGPDFContextCreator: "iPDFmini \(PDFWriting.version)",
        ]
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        ctx.beginPDFPage(nil)
        draw(in: ctx, page: box, orientation: orientation)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    public static func write(to url: URL, orientation: Orientation) throws {
        try make(orientation: orientation).write(to: url, options: .atomic)
    }

    // MARK: - Escada tipográfica

    struct LadderEntry: Equatable {
        var pointSize: Double
        var label: String
    }

    /// 5 a 14 pt, mais os três marcos do modelo de legibilidade (mínimo, alvo,
    /// máximo), que caem entre os tamanhos redondos.
    static func ladder(_ legibility: Legibility = .standard) -> [LadderEntry] {
        func size(_ mm: Double) -> Double { (Legibility.pointSizeEquivalent(xHeightMM: mm) * 10).rounded() / 10 }
        let marks: [(Double, String, Double)] = [
            (size(legibility.minimumMM), "mínimo", legibility.minimumMM),
            (size(legibility.targetMM), "alvo", legibility.targetMM),
            (size(legibility.maximumMM), "máximo", legibility.maximumMM),
        ]
        var sizes = [5.0, 6, 7, 8, 9, 10, 12, 14] + marks.map(\.0)
        sizes = Array(Set(sizes)).sorted()
        return sizes.map { pt in
            let tag = marks.first { $0.0 == pt }.map { " — \($0.1)" } ?? ""
            let xMM = Legibility.xHeightMM(forPointSize: pt)
            // Nos marcos, o valor do modelo (1,25 / 1,60 / 1,90 mm), não o do corpo arredondado.
            let mm = marks.first { $0.0 == pt }.map { $0.2 } ?? xMM
            return LadderEntry(pointSize: pt, label: "\(decimal(pt, 1)) pt\(tag) · altura-x \(decimal(mm, 2)) mm")
        }
    }

    /// Vírgula decimal; sem zeros finais quando os decimais são nulos.
    static func decimal(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains("."), digits == 1, s.hasSuffix(".0") { s.removeLast(2) }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Desenho

    private static let mmColor = CGColor(red: 0.0, green: 0.30, blue: 0.75, alpha: 1)
    private static let ptColor = CGColor(red: 0.80, green: 0.18, blue: 0.0, alpha: 1)
    /// Times New Roman: altura-x ≈ 0,45 em, perto da razão 0,47 do modelo. Georgia
    /// foi descartada: embutida, embaralha a extração de texto do PDFKit.
    private static let ladderFont = "Times New Roman"
    private static let inkColor = CGColor(gray: 0.05, alpha: 1)
    /// Alcance das réguas, em pt; maior que qualquer inset plausível.
    private static let rulerLength: CGFloat = 57

    private static func draw(in ctx: CGContext, page: CGRect, orientation: Orientation) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(page)
        drawGrid(ctx, page)
        drawCorners(ctx, page)

        let edges: [Edge] = [
            Edge(origin: { CGPoint(x: $0 * page.width, y: page.height) }, inward: CGVector(dx: 0, dy: -1),
                 angle: 0, spineIsVertical: true),
            Edge(origin: { CGPoint(x: $0 * page.width, y: 0) }, inward: CGVector(dx: 0, dy: 1),
                 angle: 0, spineIsVertical: true),
            Edge(origin: { CGPoint(x: 0, y: $0 * page.height) }, inward: CGVector(dx: 1, dy: 0),
                 angle: .pi / 2, spineIsVertical: false),
            Edge(origin: { CGPoint(x: page.width, y: $0 * page.height) }, inward: CGVector(dx: -1, dy: 0),
                 angle: -.pi / 2, spineIsVertical: false),
        ]
        for edge in edges {
            // mm e pt em posições diferentes da mesma borda, para os números não se sobreporem.
            drawRuler(ctx, edge, at: 0.3, unit: .mm)
            drawRuler(ctx, edge, at: 0.7, unit: .pt)
        }
        drawCenter(ctx, page, orientation)
    }

    private static func drawGrid(_ ctx: CGContext, _ page: CGRect) {
        ctx.saveGState()
        ctx.setLineWidth(0.25)
        var k = 0
        var x: CGFloat = 0
        while x <= page.width {
            ctx.setStrokeColor(CGColor(gray: k % 5 == 0 ? 0.82 : 0.91, alpha: 1))
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: page.height)); ctx.strokePath()
            x += 10; k += 1
        }
        k = 0
        var y: CGFloat = 0
        while y <= page.height {
            ctx.setStrokeColor(CGColor(gray: k % 5 == 0 ? 0.82 : 0.91, alpha: 1))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: page.width, y: y)); ctx.strokePath()
            y += 10; k += 1
        }
        ctx.restoreGState()
    }

    /// Arcos concêntricos centrados em cada canto da página, de R/4 a 2R, e o
    /// contorno do raio suposto do painel. O que o leitor corta mostra quanto do canto se perde.
    private static func drawCorners(_ ctx: CGContext, _ page: CGRect) {
        let r = MiniDevice.cornerRadiusPt
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: page.minX, y: page.minY), 0),
            (CGPoint(x: page.maxX, y: page.minY), .pi / 2),
            (CGPoint(x: page.maxX, y: page.maxY), .pi),
            (CGPoint(x: page.minX, y: page.maxY), 3 * .pi / 2),
        ]
        ctx.saveGState()
        for (c, start) in corners {
            for k in 1...8 {
                let radius = r * CGFloat(k) / 4
                ctx.setLineWidth(k % 4 == 0 ? 0.6 : 0.3)
                ctx.setStrokeColor(k % 4 == 0 ? CGColor(gray: 0.15, alpha: 1) : CGColor(gray: 0.45, alpha: 1))
                ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: start + .pi / 2, clockwise: false)
                ctx.strokePath()
            }
        }
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.8))
        ctx.addPath(CGPath(roundedRect: page.insetBy(dx: 0.25, dy: 0.25), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private struct Edge {
        var origin: (CGFloat) -> CGPoint
        var inward: CGVector
        /// Rotação do texto dos rótulos (laterais giram para caber no passo de 2 mm).
        var angle: CGFloat
        var spineIsVertical: Bool
    }

    private enum Unit { case mm, pt }

    private static func drawRuler(_ ctx: CGContext, _ edge: Edge, at fraction: CGFloat, unit: Unit) {
        let o = edge.origin(fraction)
        let n = edge.inward
        let a = edge.angle
        // Direção de leitura do texto (t) e para onde fica o "alto" das letras.
        let t = CGVector(dx: cos(a), dy: sin(a))
        let up = CGVector(dx: -sin(a), dy: cos(a))
        let color = unit == .mm ? mmColor : ptColor
        let step: CGFloat = unit == .mm ? Units.mmToPt(1) : 1
        let labelEvery = unit == .mm ? 2 : 5
        let fontSize: CGFloat = 4.5
        let capHeight = fontSize * 0.72
        let count = Int((rulerLength / step).rounded(.down))

        func point(_ d: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: o.x + n.dx * d + t.dx * side, y: o.y + n.dy * d + t.dy * side)
        }

        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.3)
        ctx.move(to: point(0, 0)); ctx.addLine(to: point(CGFloat(count) * step, 0)); ctx.strokePath()
        for i in 1...count {
            let d = CGFloat(i) * step
            let labelled = i % labelEvery == 0
            let len: CGFloat = labelled ? 4 : 2
            ctx.setLineWidth(labelled ? 0.45 : 0.25)
            ctx.move(to: point(d, 0)); ctx.addLine(to: point(d, len)); ctx.strokePath()
            if labelled {
                // Centraliza o corpo da letra sobre o traço.
                let centerShift = (up.dx * n.dx + up.dy * n.dy) * capHeight / 2
                let base = point(d - centerShift, len + 1.2)
                drawText("\(i)", at: base, size: fontSize, color: color, angle: a, font: "Helvetica", ctx: ctx)
            }
        }
        // Unidade no fim da régua.
        let end = point(CGFloat(count) * step + 7, 1)
        drawText(unit == .mm ? "mm" : "pt", at: end, size: 4.5, color: color, angle: a, font: "Helvetica-Bold", ctx: ctx)
        ctx.restoreGState()
    }

    private static func drawCenter(_ ctx: CGContext, _ page: CGRect, _ orientation: Orientation) {
        let cx = page.midX
        var y = page.maxY - rulerLength - 17
        let size = page.size
        let name = orientation == .portrait ? "retrato" : "paisagem"
        let header: [(String, CGFloat, CGColor)] = [
            ("iPDFmini · calibração", 9, inkColor),
            ("Tela cheia \(decimal(Double(size.width), 2)) × \(decimal(Double(size.height), 2)) pt · \(name)", 7.5, inkColor),
            ("Em cada borda, leia o primeiro número visível:", 7.5, inkColor),
            ("mm (azul) ou pt (vermelho). O que vem antes dele está escondido.", 7.5, inkColor),
        ]
        for (text, fs, color) in header {
            drawText(text, at: CGPoint(x: cx, y: y), size: fs, color: color, angle: 0, font: ladderFont, anchor: 0.5, ctx: ctx)
            y -= fs * 1.35
        }
        y -= 6
        // Alinhada à esquerda, com folga entre linhas (o extrator de texto do PDFKit
        // funde linhas centralizadas e coladas). Em paisagem não cabe numa coluna
        // só (sobram ~140 pt de altura): duas colunas.
        let entries = ladder()
        let columns: [(x: CGFloat, items: ArraySlice<LadderEntry>)] = orientation == .portrait
            ? [(cx - 95, entries[...])]
            : [(cx - 184, entries[..<6]), (cx - 34, entries[6...])]
        for column in columns {
            var yy = y
            for entry in column.items {
                let fs = CGFloat(entry.pointSize)
                yy -= fs
                drawText(entry.label, at: CGPoint(x: column.x, y: yy), size: fs, color: inkColor, angle: 0, font: ladderFont, ctx: ctx)
                yy -= fs * 0.7
            }
        }
    }

    /// Uma criação por (nome, corpo), sob lock: CTFontCreateWithName concorrente
    /// pode travar no XPC do registro de fontes, e o app/testes
    /// podem gerar o PDF de calibração em paralelo.
    private static func cachedFont(_ name: String, _ size: CGFloat) -> CTFont {
        let key = "\(name)@\(size)"
        fontLock.lock()
        defer { fontLock.unlock() }
        if let f = fontCache[key] { return f }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        fontCache[key] = f
        return f
    }
    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var fontCache: [String: CTFont] = [:]

    /// `anchor`: 0 = ponto é o início do texto, 0,5 = centro.
    private static func drawText(_ s: String, at p: CGPoint, size: CGFloat, color: CGColor, angle: CGFloat,
                                 font fontName: String, anchor: CGFloat = 0, ctx: CGContext) {
        let font = cachedFont(fontName, size)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        ctx.textPosition = CGPoint(x: -CGFloat(width) * anchor, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
