import CoreGraphics
import CoreText
import Foundation

struct TextLine {
    var text: String
    var justify: Bool
    var indent: CGFloat
}

struct BodyStyle {
    var font: CTFont
    var leading: CGFloat
    /// Recuo da primeira linha de cada parágrafo.
    var indent: CGFloat = 14
}

/// Quebra de texto corrido em linhas de largura `width`: parágrafos de 4 a 9 linhas,
/// linhas cheias justificadas, última linha do parágrafo curta e solta.
func makeLines(source: TextSource, font: CTFont, width: CGFloat, count: Int, indent: CGFloat) -> [TextLine] {
    var out: [TextLine] = []
    var pending: String?

    func take(limit: CGFloat, maxWords: Int?) -> String {
        var words: [String] = []
        while true {
            let w = pending ?? source.token()
            pending = nil
            if !words.isEmpty, Canvas.width((words + [w]).joined(separator: " "), font: font) > limit {
                pending = w
                break
            }
            words.append(w)
            if let m = maxWords, words.count >= m { break }
        }
        return words.joined(separator: " ")
    }

    while out.count < count {
        let n = source.int(in: 4...9)
        for i in 0..<n where out.count < count {
            let ind = i == 0 ? indent : 0
            let avail = width - ind
            if i == n - 1 {
                out.append(TextLine(text: take(limit: avail * 0.85, maxWords: source.int(in: 2...6)), justify: false, indent: ind))
            } else {
                out.append(TextLine(text: take(limit: avail, maxWords: nil), justify: true, indent: ind))
            }
        }
    }
    // Truncou no meio do parágrafo: a última linha não é justificada.
    if !out.isEmpty { out[out.count - 1].justify = false }
    return out
}

/// Região vertical de texto, preenchida de cima para baixo.
/// `cursor` é o topo do próximo espaço de linha; a linha de base fica uma altura de
/// versal abaixo dele, de modo que a tinta do corpo encosta no topo da região.
final class Flow {
    let canvas: Canvas
    let region: CGRect
    private(set) var cursor: CGFloat
    /// Tinta de cada linha desenhada (títulos e corpo), em ordem.
    private(set) var lineRects: [CGRect] = []
    /// União da tinta da região: o retângulo da coluna na verdade.
    private(set) var union: CGRect?
    /// Coluna dos blocos criados por esta região (nulo = largura total).
    var columnIndex: Int?

    init(canvas: Canvas, region: CGRect) {
        self.canvas = canvas
        self.region = region
        cursor = region.maxY
    }

    func note(_ r: CGRect?) {
        guard let r else { return }
        lineRects.append(r)
        union = union.map { $0.union(r) } ?? r
    }

    /// Quantas linhas do estilo ainda cabem (a última com o descendente dentro da região).
    func capacity(_ style: BodyStyle) -> Int {
        let cap = CTFontGetCapHeight(style.font)
        let desc = CTFontGetDescent(style.font)
        let n = Int(floor((cursor - cap - desc - region.minY) / style.leading)) + 1
        return max(0, n)
    }

    func place(_ lines: [TextLine], style: BodyStyle) {
        let cap = CTFontGetCapHeight(style.font)
        for l in lines {
            let r = canvas.text(l.text, font: style.font, at: CGPoint(x: region.minX + l.indent, y: cursor - cap),
                                justifyWidth: l.justify ? region.width - l.indent : nil)
            note(r)
            cursor -= style.leading
        }
    }

    /// Gera e coloca texto corrido até esgotar a região (ou `maxLines`). Devolve quantas linhas.
    @discardableResult
    func fill(source: TextSource, style: BodyStyle, maxLines: Int? = nil, indent: Bool = true) -> Int {
        let n = min(capacity(style), maxLines ?? .max)
        guard n > 0 else { return 0 }
        let lines = makeLines(source: source, font: style.font, width: region.width, count: n,
                              indent: indent ? style.indent : 0)
        place(lines, style: style)
        return n
    }

    func heading(_ text: String, font: CTFont, before: CGFloat, after: CGFloat, align: TextAlign = .left) {
        cursor -= before
        let baseline = cursor - CTFontGetCapHeight(font)
        let x: CGFloat = switch align { case .left: region.minX; case .center: region.midX; case .right: region.maxX }
        note(canvas.text(text, font: font, at: CGPoint(x: x, y: baseline), align: align))
        cursor = baseline - CTFontGetDescent(font) - after
    }

    /// Avança o cursor sem desenhar.
    func skip(_ h: CGFloat) { cursor -= h }
}
