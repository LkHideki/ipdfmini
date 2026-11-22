import CoreGraphics
import CoreText
import Foundation

/// Papel da tinta na verdade da página.
enum InkRole { case body, headerFooter, ignorable }
enum TextAlign { case left, center, right }

/// Fontes reais do sistema, por nome PostScript (CTFontCreateWithName cai
/// silenciosamente numa fonte padrão se o nome não existir; os testes conferem).
enum Face {
    static let timesName = "TimesNewRomanPSMT"
    static let timesBoldName = "TimesNewRomanPS-BoldMT"
    static let timesItalicName = "TimesNewRomanPS-ItalicMT"
    static let helveticaName = "Helvetica"
    static let helveticaBoldName = "Helvetica-Bold"

    /// Fonte criada uma vez por (nome, corpo), sob lock. CTFontCreateWithName
    /// concorrente travou o processo (threads presas no XPC do registro de
    /// fontes) quando vários cenários eram gerados em
    /// paralelo. CTFont é imutável: depois de criada, compartilhar é seguro.
    static func make(_ name: String, _ size: CGFloat) -> CTFont {
        let key = "\(name)@\(size)"
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        cache[key] = f
        return f
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]
    static func times(_ s: CGFloat) -> CTFont { make(timesName, s) }
    static func timesBold(_ s: CGFloat) -> CTFont { make(timesBoldName, s) }
    static func timesItalic(_ s: CGFloat) -> CTFont { make(timesItalicName, s) }
    static func helvetica(_ s: CGFloat) -> CTFont { make(helveticaName, s) }
    static func helveticaBold(_ s: CGFloat) -> CTFont { make(helveticaBoldName, s) }
}

struct LinkSpec {
    enum Target { case page(Int, CGPoint), url(URL) }
    var rect: CGRect
    var target: Target
}

/// Superfície de desenho de uma página, em espaço do usuário. Cada operação
/// registra a tinta que produz, para que a verdade nasça do mesmo código que desenha.
final class Canvas {
    let ctx: CGContext
    var ink: [CGRect] = []
    var ignorable: [CGRect] = []
    var headerFooter: [CGRect] = []
    var lines: [CGRect] = []
    var columns: [CGRect] = []
    var words: [String] = []
    var links: [LinkSpec] = []
    var highlights: [CGRect] = []
    var isScan = false
    /// Blocos da verdade (M3), em espaço do usuário e em ordem de leitura = ordem de criação.
    var blocks: [OpenBlock] = []
    private var current: (type: String, column: Int?, ink: Int, lines: Int)?

    struct OpenBlock {
        var rect: CGRect
        var type: String
        var column: Int?
        var lines: [CGRect]
    }

    init(ctx: CGContext) { self.ctx = ctx }

    /// União dos blocos criados a partir do índice `start` (tinta de uma coluna ou da página).
    func blocksUnion(from start: Int) -> CGRect? {
        blocks[start...].map(\.rect).reduce(nil) { (acc: CGRect?, r: CGRect) in acc.map { $0.union(r) } ?? r }
    }

    /// Tudo o que `body` desenha vira um bloco: o retângulo é a união da tinta registrada
    /// e as linhas são as de texto registradas, então a verdade nasce do mesmo código que
    /// desenha e não há como o bloco divergir da tinta. Blocos não se aninham.
    /// Chame na ordem de leitura.
    func block(_ type: String, column: Int?, _ body: () -> Void) {
        precondition(current == nil, "SyntheticCorpus: bloco aninhado")
        current = (type, column, ink.count, lines.count)
        body()
        let o = current!
        current = nil
        precondition(ink.count > o.ink, "SyntheticCorpus: bloco '\(type)' sem tinta")
        let rect = ink[o.ink...].dropFirst().reduce(ink[o.ink]) { $0.union($1) }
        blocks.append(OpenBlock(rect: rect, type: type, column: column, lines: Array(lines[o.lines...])))
    }

    func record(_ r: CGRect, role: InkRole, isText: Bool) {
        switch role {
        case .body:
            ink.append(r)
            if isText { lines.append(r) }
        case .headerFooter:
            ink.append(r)
            headerFooter.append(r)
            if isText { lines.append(r) }
        case .ignorable:
            ignorable.append(r)
        }
    }

    // MARK: texto

    /// Linha do CoreText sem ligaduras: com "fi"/"fl" fundidos a extração de texto
    /// devolveria um glifo de ligadura e a verdade de palavras divergiria.
    static func makeLine(_ s: String, font: CTFont) -> CTLine {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTLigatureAttributeName: 0 as NSNumber]
        let astr = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
        return CTLineCreateWithAttributedString(astr)
    }

    static func width(_ s: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(makeLine(s, font: font), nil, nil, nil))
    }

    /// Tinta real da linha, no espaço local (origem = ponto-base à esquerda):
    /// união dos bounds de contorno de cada glifo deslocados pela posição do glifo.
    /// Espaços têm contorno vazio e não entram; a caixa de avanço não é usada.
    static func inkBounds(of line: CTLine) -> CGRect? {
        var result: CGRect?
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName as String] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            var rects = [CGRect](repeating: .zero, count: n)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &rects, n)
            for i in 0..<n where rects[i].width > 0 && rects[i].height > 0 {
                let r = rects[i].offsetBy(dx: positions[i].x, dy: positions[i].y)
                result = result.map { $0.union(r) } ?? r
            }
        }
        return result
    }

    /// Desenha `s` com ponto-base em `p`, girado em `angle` (radianos, anti-horário).
    /// `justifyWidth` estica os espaços até essa largura (linha justificada).
    /// Devolve a tinta em espaço do usuário (nulo se só espaços).
    @discardableResult
    func text(_ s: String, font: CTFont, at p: CGPoint, align: TextAlign = .left, angle: CGFloat = 0,
              gray: CGFloat = 0, role: InkRole = .body, justifyWidth: CGFloat? = nil,
              recordWords: Bool = true, recordLine: Bool = true) -> CGRect? {
        var line = Canvas.makeLine(s, font: font)
        if let w = justifyWidth, let j = CTLineCreateJustifiedLine(line, 1.0, Double(w)) { line = j }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let dx: CGFloat = switch align { case .left: 0; case .center: -width / 2; case .right: -width }
        let local = CGAffineTransform(translationX: dx, y: 0)
        let toUser = local.concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y))

        ctx.saveGState()
        ctx.concatenate(toUser)
        ctx.textPosition = .zero
        ctx.setFillColor(gray: gray, alpha: 1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        if recordWords { words += s.split(separator: " ").map(String.init) }
        guard let inkLocal = Canvas.inkBounds(of: line) else { return nil }
        let r = inkLocal.applying(toUser)
        record(r, role: role, isText: recordLine)
        return r
    }

    // MARK: traços e figuras

    func strokeSegment(from a: CGPoint, to b: CGPoint, width: CGFloat, role: InkRole) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        // Só segmentos horizontais ou verticais; cap butt engorda `width/2` só no eixo transversal.
        let horizontal = a.y == b.y
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        record(horizontal ? r.insetBy(dx: 0, dy: -width / 2) : r.insetBy(dx: -width / 2, dy: 0),
               role: role, isText: false)
    }

    func strokeCircle(center c: CGPoint, radius: CGFloat, width: CGFloat, role: InkRole) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        let e = radius + width / 2
        record(CGRect(x: c.x - e, y: c.y - e, width: 2 * e, height: 2 * e), role: role, isText: false)
    }

    /// Contorno exato do traço (geometria do próprio CoreGraphics, sem aproximar por caixa de controle).
    func strokePath(_ path: CGPath, width: CGFloat, gray: CGFloat = 0, role: InkRole = .body) {
        ctx.setStrokeColor(gray: gray, alpha: 1)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        record(outline.boundingBoxOfPath, role: role, isText: false)
    }

    /// Contorno de retângulo, sem preenchimento; a tinta é a caixa externa da borda.
    func strokeRect(_ r: CGRect, width: CGFloat, role: InkRole = .body) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(width)
        ctx.stroke(r)
        record(r.insetBy(dx: -width / 2, dy: -width / 2), role: role, isText: false)
    }

    /// Retângulo preenchido sem borda.
    func fillRect(_ r: CGRect, gray: CGFloat, role: InkRole = .body) {
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(r)
        record(r, role: role, isText: false)
    }

    /// Retângulo preenchido com borda; a tinta é a caixa externa da borda.
    func figure(_ r: CGRect, fillGray: CGFloat, borderWidth: CGFloat, role: InkRole = .body) {
        ctx.setFillColor(gray: fillGray, alpha: 1)
        ctx.fill(r)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(borderWidth)
        ctx.stroke(r)
        record(r.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2), role: role, isText: false)
    }
}
