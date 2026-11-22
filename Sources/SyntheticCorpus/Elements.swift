import CoreGraphics
import CoreText
import Foundation

// Elementos de página do M3 (títulos, equação, figura, legenda, tabela, lista, nota).
// Cada um abre um bloco no `Canvas`: o retângulo e as linhas da verdade saem da tinta
// que o próprio elemento desenha. Chamar na ordem de leitura (ordem de leitura = ordem
// de criação dos blocos).

enum FigureKind {
    /// Eixos, marcas, rótulos pequenos, barras e curvas; sem moldura externa.
    case plot
    /// Dois gráficos lado a lado; o vão entre eles parece calha, mas é uma figura só.
    case twinPlots
    /// Moldura, caixas, conectores, círculos e uma curva.
    case diagram
}

extension Flow {
    /// Texto corrido como um bloco (vários parágrafos seguidos = um bloco, como o XY-cut vê).
    func paragraphs(_ type: String = "paragraph", source: TextSource, style: BodyStyle, lines: Int? = nil,
                    indent: Bool = true) {
        guard min(capacity(style), lines ?? .max) > 0 else { return }
        canvas.block(type, column: columnIndex) {
            fill(source: source, style: style, maxLines: lines, indent: indent)
        }
    }

    func headingBlock(_ text: String, font: CTFont, before: CGFloat, after: CGFloat, align: TextAlign = .left) {
        canvas.block("heading", column: columnIndex) {
            heading(text, font: font, before: before, after: after, align: align)
        }
    }

    /// Equação isolada: fração centrada na região, número "(n)" encostado à direita.
    /// Peças desenhadas à mão (texto + traço de fração), sem linhas na verdade: é bloco atômico.
    func equation(number: Int, source: TextSource) {
        func letter() -> String { String(UnicodeScalar(UInt8(97 + source.int(in: 0...25)))) }
        let font = Face.timesItalic(10)
        let cap = CTFontGetCapHeight(font)
        let top = cursor - 6
        let axis = top - 14  // eixo matemático (barra da fração)
        let lead = "\(letter()) =", num = "\(letter()) + \(letter())"
        let den = "\(letter()) + \(letter()) \(letter())", tail = "+ \(letter())"
        let wl = Canvas.width(lead, font: font), wt = Canvas.width(tail, font: font)
        let fracW = max(Canvas.width(num, font: font), Canvas.width(den, font: font)) + 6
        let x0 = region.midX - (wl + 4 + fracW + 4 + wt) / 2
        let fx = x0 + wl + 4
        canvas.block("equation", column: columnIndex) {
            canvas.text(lead, font: font, at: CGPoint(x: x0, y: axis - 3.5), recordLine: false)
            canvas.strokeSegment(from: CGPoint(x: fx, y: axis), to: CGPoint(x: fx + fracW, y: axis), width: 0.5, role: .body)
            canvas.text(num, font: font, at: CGPoint(x: fx + fracW / 2, y: axis + 3.5), align: .center, recordLine: false)
            canvas.text(den, font: font, at: CGPoint(x: fx + fracW / 2, y: axis - 3 - cap), align: .center, recordLine: false)
            canvas.text(tail, font: font, at: CGPoint(x: fx + fracW + 4, y: axis - 3.5), recordLine: false)
            canvas.text("(\(number))", font: Face.times(10), at: CGPoint(x: region.maxX, y: axis - 3.5), align: .right,
                        recordLine: false)
        }
        note(canvas.blocks.last?.rect)
        skip(6 + 28 + 6)
    }

    /// Figura vetorial desenhada em `width × height` centrada na região (a tinta real pode
    /// ser um pouco menor: é ela que vai para a verdade).
    func figure(_ kind: FigureKind, width: CGFloat? = nil, height: CGFloat, source: TextSource, before: CGFloat = 6) {
        skip(before)
        let w = width ?? region.width
        let rect = CGRect(x: region.minX + (region.width - w) / 2, y: cursor - height, width: w, height: height)
        canvas.block("figure", column: columnIndex) { canvas.drawFigure(kind, in: rect, source: source) }
        note(canvas.blocks.last?.rect)
        skip(height)
    }

    /// Legenda "Figure n: …" / "Table n: …" em corpo menor, `lines` linhas, última curta.
    func caption(_ label: String, source: TextSource, lines: Int, before: CGFloat = 6) {
        let style = BodyStyle(font: Face.times(9), leading: 10.5, indent: 0)
        skip(before)
        let ls = greedyLines(prefix: label, source: source, font: style.font, width: region.width, count: lines)
        canvas.block("caption", column: columnIndex) { place(ls, style: style) }
    }

    /// Tabela de células soltas: cada célula é um retângulo, separadas por `gap` pt em x e y.
    /// A largura de cada coluna é a do texto mais largo + 8 pt de respiro: os vãos verticais
    /// (100% da altura da tabela, entre colunas e entre a borda e o texto) ficam todos abaixo
    /// de 8 pt, o limiar de calha do segmentador. A tabela é centrada na região.
    func cellGrid(rows: Int, cols: Int, cellHeight: CGFloat, gap: CGFloat, source: TextSource) {
        let font = Face.times(8), bold = Face.timesBold(8)
        let texts: [[String]] = (0..<rows).map { r in
            (0..<cols).map { c in
                r == 0 ? source.title(words: 2)
                    : (c == 0 ? source.word(maxSyllables: 3) + " " + source.word(maxSyllables: 2) : "\(source.word(maxSyllables: 2)) \(numberCell(source))")
            }
        }
        let widths: [CGFloat] = (0..<cols).map { c in
            (0..<rows).map { r in Canvas.width(texts[r][c], font: r == 0 ? bold : font) }.max()! + 8
        }
        let total = widths.reduce(0, +) + gap * CGFloat(cols - 1)
        let top = cursor
        canvas.block("table", column: columnIndex) {
            var x = region.midX - total / 2
            for c in 0..<cols {
                for r in 0..<rows {
                    let rect = CGRect(x: x, y: top - CGFloat(r + 1) * cellHeight - CGFloat(r) * gap,
                                      width: widths[c], height: cellHeight)
                    canvas.figure(rect, fillGray: r == 0 ? 0.88 : 1, borderWidth: 0.5)
                    canvas.text(texts[r][c], font: r == 0 ? bold : font,
                                at: CGPoint(x: rect.midX, y: rect.midY - CTFontGetCapHeight(font) / 2),
                                align: .center, recordLine: false)
                }
                x += widths[c] + gap
            }
        }
        note(canvas.blocks.last?.rect)
        skip(CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap)
    }

    /// Tabela com grade de fios contínuos, `width` pt de largura, centrada.
    func ruledTable(rows: Int, cols: Int, cellHeight: CGFloat, width: CGFloat, source: TextSource) {
        let font = Face.times(9)
        let x0 = region.minX + (region.width - width) / 2
        let cw = width / CGFloat(cols)
        let top = cursor, h = CGFloat(rows) * cellHeight
        canvas.block("table", column: columnIndex) {
            for r in 0...rows {
                let y = top - CGFloat(r) * cellHeight
                canvas.strokeSegment(from: CGPoint(x: x0, y: y), to: CGPoint(x: x0 + width, y: y), width: 0.5, role: .body)
            }
            for c in 0...cols {
                let x = x0 + CGFloat(c) * cw
                canvas.strokeSegment(from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: top - h), width: 0.5, role: .body)
            }
            for r in 0..<rows {
                for c in 0..<cols {
                    let s = r == 0 ? source.title(words: 1) : (c == 0 ? source.word(maxSyllables: 2) : numberCell(source))
                    canvas.text(s, font: r == 0 ? Face.timesBold(9) : font,
                                at: CGPoint(x: x0 + (CGFloat(c) + 0.5) * cw,
                                            y: top - (CGFloat(r) + 0.5) * cellHeight - CTFontGetCapHeight(font) / 2),
                                align: .center, recordLine: false)
                }
            }
        }
        note(canvas.blocks.last?.rect)
        skip(h)
    }

    /// Lista com marcadores "•": cada item tem `lines[i]` linhas; a primeira linha inclui o marcador.
    func bulletList(lines counts: [Int], style: BodyStyle, source: TextSource) {
        let cap = CTFontGetCapHeight(style.font)
        let hang: CGFloat = 16
        canvas.block("list", column: columnIndex) {
            for n in counts {
                let ls = makeLines(source: source, font: style.font, width: region.width - hang, count: n, indent: 0)
                for (j, l) in ls.enumerated() {
                    let baseline = cursor - cap
                    let bullet = j == 0
                        ? canvas.text("•", font: style.font, at: CGPoint(x: region.minX + 4, y: baseline), recordLine: false)
                        : nil
                    let t = canvas.text(l.text, font: style.font, at: CGPoint(x: region.minX + hang, y: baseline),
                                        justifyWidth: l.justify ? region.width - hang : nil)
                    // A linha do item inclui o marcador.
                    if let t, let bullet { canvas.lines[canvas.lines.count - 1] = t.union(bullet) }
                    note(canvas.lines.last)
                    skip(style.leading)
                }
                skip(2)
            }
        }
    }

    /// Altura de região que comporta exatamente `n` linhas do estilo.
    static func height(lines n: Int, style: BodyStyle) -> CGFloat {
        CGFloat(n - 1) * style.leading + CTFontGetCapHeight(style.font) + CTFontGetDescent(style.font) + 0.01
    }

    /// Nota de rodapé: fio curto e `lines` linhas em corpo menor, encostadas em `bottom`.
    static func footnote(canvas: Canvas, x: CGFloat, width: CGFloat, bottom: CGFloat, lines n: Int,
                         source: TextSource, column: Int?) {
        let style = BodyStyle(font: Face.times(8), leading: 9.5, indent: 0)
        let flow = Flow(canvas: canvas, region: CGRect(x: x, y: bottom, width: width, height: height(lines: n, style: style)))
        canvas.block("note", column: column) {
            let y = flow.region.maxY + 3.5
            canvas.strokeSegment(from: CGPoint(x: x, y: y), to: CGPoint(x: x + width * 0.4, y: y), width: 0.6, role: .body)
            flow.fill(source: source, style: style, maxLines: n, indent: false)
        }
    }

    private func numberCell(_ source: TextSource) -> String {
        "\(source.int(in: 1...99)).\(source.int(in: 0...9))"
    }

    /// Linhas gulosas sem justificar: a primeira começa por `prefix`; a última é curta.
    private func greedyLines(prefix: String, source: TextSource, font: CTFont, width: CGFloat, count: Int) -> [TextLine] {
        var pending: String?
        var out: [TextLine] = []
        for i in 0..<count {
            var words = i == 0 ? prefix.split(separator: " ").map(String.init) : []
            let limit = i == count - 1 ? width * 0.6 : width
            while true {
                let w = pending ?? source.token()
                pending = nil
                if !words.isEmpty, Canvas.width((words + [w]).joined(separator: " "), font: font) > limit {
                    pending = w
                    break
                }
                words.append(w)
            }
            out.append(TextLine(text: words.joined(separator: " "), justify: false, indent: 0))
        }
        return out
    }
}

// MARK: figuras

extension Canvas {
    func drawFigure(_ kind: FigureKind, in r: CGRect, source: TextSource) {
        switch kind {
        case .plot: plot(in: r, source: source)
        case .twinPlots:
            let gap: CGFloat = 16
            let w = (r.width - gap) / 2
            plot(in: CGRect(x: r.minX, y: r.minY, width: w, height: r.height), source: source)
            plot(in: CGRect(x: r.minX + w + gap, y: r.minY, width: w, height: r.height), source: source)
        case .diagram: diagram(in: r, source: source)
        }
    }

    private func plot(in r: CGRect, source: TextSource) {
        let label = Face.times(6)
        let left = r.minX + 18, bottom = r.minY + 11, top = r.maxY - 2, right = r.maxX - 4
        strokeSegment(from: CGPoint(x: left, y: bottom), to: CGPoint(x: left, y: top), width: 0.8, role: .body)
        strokeSegment(from: CGPoint(x: left, y: bottom), to: CGPoint(x: right, y: bottom), width: 0.8, role: .body)
        // Barras: retângulos cinza-escuros assentados no eixo.
        let bars = 4
        let slot = (right - left) / CGFloat(bars + 1)
        for k in 0..<bars {
            let h = (top - bottom) * (0.15 + 0.1 * CGFloat(source.int(in: 0...5)))
            fillRect(CGRect(x: left + slot * (CGFloat(k) + 0.5), y: bottom + 0.4, width: slot * 0.6, height: h), gray: 0.55)
        }
        // Curvas suaves dentro da caixa dos eixos (o casco convexo dos pontos de controle fica dentro).
        for (gray, width) in [(CGFloat(0), CGFloat(1)), (0.35, 0.8)] {
            let path = CGMutablePath()
            func pt(_ fx: CGFloat) -> CGPoint {
                CGPoint(x: left + 4 + (right - left - 8) * fx,
                        y: bottom + 4 + (top - bottom - 8) * CGFloat(source.int(in: 10...90)) / 100)
            }
            path.move(to: pt(0))
            path.addCurve(to: pt(0.5), control1: pt(0.15), control2: pt(0.35))
            path.addCurve(to: pt(1), control1: pt(0.65), control2: pt(0.85))
            strokePath(path, width: width, gray: gray)
        }
        // Marcas e rótulos pequenos (só dígitos).
        for k in 1...5 {
            let x = left + (right - left) * CGFloat(k) / 5
            strokeSegment(from: CGPoint(x: x, y: bottom), to: CGPoint(x: x, y: bottom - 3), width: 0.6, role: .body)
            text("\(2 * k)", font: label, at: CGPoint(x: x, y: r.minY + 0.2), align: .center, recordLine: false)
            let y = bottom + (top - bottom) * CGFloat(k) / 5.5
            strokeSegment(from: CGPoint(x: left - 3, y: y), to: CGPoint(x: left, y: y), width: 0.6, role: .body)
            text("\(k)", font: label, at: CGPoint(x: left - 5, y: y - 2), align: .right, recordLine: false)
        }
    }

    private func diagram(in r: CGRect, source: TextSource) {
        figure(r, fillGray: 1, borderWidth: 1)
        let pitch: CGFloat = 54, boxH: CGFloat = 34, pad: CGFloat = 12
        let rows = max(1, Int((r.height - 2 * pad + 20) / pitch))
        let label = Face.times(6)
        for i in 0..<rows {
            let k = i % 3 + 1
            let gap: CGFloat = 14
            let usable = r.width - 2 * pad - 24  // 24 pt livres à direita para a curva
            let bw = (usable - gap * CGFloat(k - 1)) / CGFloat(k)
            let y = r.maxY - pad - CGFloat(i) * pitch - boxH
            let linkX = r.minX + pad + 20  // dentro da primeira caixa de toda linha
            for j in 0..<k {
                let box = CGRect(x: r.minX + pad + CGFloat(j) * (bw + gap), y: y, width: bw, height: boxH)
                figure(box, fillGray: j % 2 == 0 ? 0.82 : 1, borderWidth: 0.8)
                strokeCircle(center: CGPoint(x: box.midX, y: box.midY), radius: 4, width: 0.6, role: .body)
                if j == 0 {
                    text("n\(i + 1)", font: label, at: CGPoint(x: box.minX + 3, y: box.maxY - 8), recordLine: false)
                }
            }
            if i < rows - 1 {
                strokeSegment(from: CGPoint(x: linkX, y: y), to: CGPoint(x: linkX, y: y - (pitch - boxH)),
                              width: 0.8, role: .body)
            }
        }
        let curve = CGMutablePath()
        let cx = r.maxX - 10
        curve.move(to: CGPoint(x: cx, y: r.maxY - 8))
        curve.addCurve(to: CGPoint(x: cx, y: r.minY + 8), control1: CGPoint(x: cx - 8, y: r.midY + r.height / 4),
                       control2: CGPoint(x: cx - 8, y: r.midY - r.height / 4))
        strokePath(curve, width: 0.8, gray: 0.3)
    }
}
