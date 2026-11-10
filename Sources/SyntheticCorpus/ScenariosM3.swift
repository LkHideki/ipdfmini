import CoreGraphics
import CoreText
import Foundation

// Cenários do M3 (PLAN.md §5.6, E3–E5): blocos, colunas, figuras e tabelas.
// Ordem de leitura de referência = ordem em que os blocos são desenhados: largura total de
// cima para baixo, intercalada nas posições certas; dentro de uma seção de 2 colunas, a
// coluna esquerda inteira antes da direita; folio por último.

extension Scenarios {
    private static func pageNumber(_ c: Canvas, _ text: String, at p: CGPoint, role: InkRole = .headerFooter) {
        c.block("headerFooter", column: nil) {
            c.text(text, font: Face.times(10), at: p, align: .center, role: role)
        }
    }

    // MARK: artigo arXiv em duas colunas (Letter)

    static func arxivTwoColumn(_ src: TextSource) -> Plan {
        let body = BodyStyle(font: Face.times(10), leading: 12)
        let left: CGFloat = 45, colW: CGFloat = 252, gutter: CGFloat = 18
        let top: CGFloat = 738, bottom: CGFloat = 72
        let full = CGRect(x: left, y: bottom, width: 522, height: top - bottom)

        /// Seção de duas colunas de `top` até o pé; devolve o menor cursor das duas.
        /// A verdade `columns` é a união dos blocos de cada coluna.
        @discardableResult
        func columns(_ c: Canvas, top: CGFloat, bottoms: [CGFloat] = [bottom, bottom],
                     _ build: (Int, Flow) -> Void) -> CGFloat {
            var lowest = top
            for i in 0..<2 {
                let flow = Flow(canvas: c, region: CGRect(x: left + CGFloat(i) * (colW + gutter), y: bottoms[i],
                                                          width: colW, height: top - bottoms[i]))
                flow.columnIndex = i
                let start = c.blocks.count
                build(i, flow)
                if let u = c.blocksUnion(from: start) {
                    c.columns.append(u)
                }
                lowest = min(lowest, flow.cursor)
            }
            return lowest
        }
        func folio(_ c: Canvas, _ n: Int) { pageNumber(c, "\(n)", at: CGPoint(x: 306, y: 36)) }
        func sectionTitle(_ n: String) -> String { "\(n) \(src.title(words: 2))" }
        let h1 = Face.timesBold(11), h2 = Face.timesBold(10)

        let p1 = PageSpec(media: letter) { c in
            let head = Flow(canvas: c, region: full)
            head.headingBlock(src.title(words: 5), font: Face.helveticaBold(17), before: 0, after: 8, align: .center)
            c.block("paragraph", column: nil) {
                head.heading(src.title(words: 2) + ",  " + src.title(words: 2) + ",  " + src.title(words: 2),
                             font: Face.times(11), before: 0, after: 3, align: .center)
                head.heading(src.title(words: 3) + " University", font: Face.timesItalic(9), before: 0, after: 14, align: .center)
            }
            head.headingBlock("Abstract", font: Face.timesBold(10), before: 0, after: 4, align: .center)
            let abstract = Flow(canvas: c, region: CGRect(x: left + 36, y: bottom, width: 450, height: head.cursor - bottom))
            abstract.paragraphs(source: src, style: body, lines: 7, indent: false)
            let colTop = abstract.cursor - 10
            let noteLines = 3
            let noteTop = bottom + Flow.height(lines: noteLines, style: BodyStyle(font: Face.times(8), leading: 9.5)) + 10
            columns(c, top: colTop, bottoms: [noteTop, bottom]) { i, f in
                if i == 0 {
                    f.headingBlock(sectionTitle("1"), font: h1, before: 0, after: 5)
                    f.paragraphs(source: src, style: body, lines: 22)
                    f.headingBlock(sectionTitle("1.1"), font: h2, before: 6, after: 4)
                    f.paragraphs(source: src, style: body, indent: false)
                    Flow.footnote(canvas: c, x: left, width: colW, bottom: bottom, lines: noteLines, source: src, column: 0)
                } else {
                    f.paragraphs(source: src, style: body, lines: 16)
                    f.figure(.plot, width: 232, height: 128, source: src, before: 8)
                    f.caption("Figure 1: ", source: src, lines: 3)
                    f.skip(8)
                    f.paragraphs(source: src, style: body, indent: false)
                }
            }
            folio(c, 1)
        }

        let p2 = PageSpec(media: letter) { c in
            let head = Flow(canvas: c, region: full)
            head.figure(.twinPlots, height: 150, source: src, before: 0)
            head.caption("Figure 2: ", source: src, lines: 2)
            columns(c, top: head.cursor - 14) { i, f in
                if i == 0 {
                    f.headingBlock(sectionTitle("2"), font: h1, before: 0, after: 5)
                    f.paragraphs(source: src, style: body, lines: 14)
                    f.equation(number: 1, source: src)
                    f.paragraphs(source: src, style: body, lines: 10, indent: false)
                    f.headingBlock(sectionTitle("2.1"), font: h2, before: 6, after: 4)
                    f.paragraphs(source: src, style: body, indent: false)
                } else {
                    f.paragraphs(source: src, style: body, lines: 20, indent: false)
                    f.headingBlock(sectionTitle("2.2"), font: h2, before: 6, after: 4)
                    f.paragraphs(source: src, style: body)
                }
            }
            folio(c, 2)
        }

        let p3 = PageSpec(media: letter) { c in
            // Seção superior com as duas colunas de mesma altura nominal (22 linhas).
            let lowest = columns(c, top: top) { i, f in
                if i == 0 {
                    f.paragraphs(source: src, style: body, lines: 22, indent: false)
                } else {
                    f.paragraphs(source: src, style: body, lines: 12, indent: false)
                    f.headingBlock(sectionTitle("3"), font: h1, before: 6, after: 4)
                    f.paragraphs(source: src, style: body, lines: 8)
                }
            }
            let wide = Flow(canvas: c, region: CGRect(x: left, y: bottom, width: 522, height: lowest - 14 - bottom))
            wide.caption("Table 1: ", source: src, lines: 2, before: 0)
            wide.skip(6)
            wide.cellGrid(rows: 5, cols: 6, cellHeight: 15, gap: 5, source: src)
            columns(c, top: wide.cursor - 14) { i, f in
                if i == 0 {
                    f.paragraphs(source: src, style: body, indent: false)
                } else {
                    f.headingBlock(sectionTitle("3.1"), font: h2, before: 0, after: 4)
                    f.paragraphs(source: src, style: body)
                }
            }
            folio(c, 3)
        }

        let p4 = PageSpec(media: letter) { c in
            columns(c, top: top) { i, f in
                if i == 0 {
                    f.headingBlock(sectionTitle("4"), font: h1, before: 0, after: 5)
                    f.paragraphs(source: src, style: body, lines: 20)
                    f.equation(number: 2, source: src)
                    f.paragraphs(source: src, style: body, indent: false)
                } else {
                    f.paragraphs(source: src, style: body, indent: false)
                }
            }
            folio(c, 4)
        }

        // Última página: colunas de alturas bem diferentes (38 × 16 linhas).
        let p5 = PageSpec(media: letter) { c in
            columns(c, top: top) { i, f in
                if i == 0 {
                    f.paragraphs(source: src, style: body, lines: 38, indent: false)
                    f.headingBlock(sectionTitle("5"), font: h1, before: 6, after: 5)
                    f.paragraphs(source: src, style: body, lines: 10, indent: false)
                } else {
                    f.paragraphs(source: src, style: body, lines: 16, indent: false)
                    f.headingBlock("References", font: h1, before: 8, after: 5)
                    f.paragraphs(source: src, style: body, lines: 6, indent: false)
                }
            }
            folio(c, 5)
        }
        return Plan(pages: [p1, p2, p3, p4, p5], bodyFont: Face.times(10))
    }

    // MARK: relatório A4 com figura alta, tabela e lista

    static func reportWithFigures(_ src: TextSource) -> Plan {
        let body = BodyStyle(font: Face.times(10), leading: 12)
        // Mancha 451 × 698 pt: com ela, a escala de fatia em paisagem (500,47 / 451) deixa ~296 pt
        // de altura útil por tela; a figura alta tem 340 pt.
        let region = a4.insetBy(dx: 72, dy: 72)
        let h1 = Face.timesBold(13), h2 = Face.timesBold(11)

        func page(_ n: Int, _ build: @escaping (Flow) -> Void) -> PageSpec {
            PageSpec(media: a4) { c in
                c.block("headerFooter", column: nil) {
                    c.text("Synthetic Report with Figures", font: Face.timesItalic(8),
                           at: CGPoint(x: region.minX, y: region.maxY + 30), role: .headerFooter)
                }
                let start = c.blocks.count
                let flow = Flow(canvas: c, region: region)
                build(flow)
                if let u = c.blocksUnion(from: start) {
                    c.columns.append(u)
                }
                pageNumber(c, "Page \(n)", at: CGPoint(x: region.midX, y: region.minY - 36))
            }
        }

        let p1 = page(1) { f in
            f.headingBlock(src.title(words: 4), font: Face.timesBold(18), before: 0, after: 12)
            f.headingBlock("1 \(src.title(words: 2))", font: h1, before: 0, after: 6)
            f.paragraphs(source: src, style: body, lines: 12)
            f.headingBlock("2 \(src.title(words: 2))", font: h1, before: 10, after: 6)
            f.paragraphs(source: src, style: body, lines: 7)
            f.skip(8)
            f.bulletList(lines: [2, 3, 2, 2], style: body, source: src)
            f.skip(8)
            f.paragraphs(source: src, style: body, lines: 14, indent: false)
        }
        let p2 = page(2) { f in
            f.headingBlock("3 \(src.title(words: 2))", font: h1, before: 0, after: 6)
            f.paragraphs(source: src, style: body, lines: 10)
            f.figure(.diagram, width: 360, height: 340, source: src, before: 10)
            f.caption("Figure 1: ", source: src, lines: 2)
            f.skip(10)
            f.paragraphs(source: src, style: body, lines: 14, indent: false)
        }
        let p3 = page(3) { f in
            f.headingBlock("4 \(src.title(words: 2))", font: h1, before: 0, after: 6)
            f.paragraphs(source: src, style: body, lines: 8)
            f.skip(8)
            f.caption("Table 1: ", source: src, lines: 2, before: 0)
            f.skip(6)
            f.ruledTable(rows: 7, cols: 4, cellHeight: 16, width: 380, source: src)
            f.skip(10)
            f.headingBlock("4.1 \(src.title(words: 2))", font: h2, before: 0, after: 5)
            f.paragraphs(source: src, style: body, lines: 18, indent: false)
        }
        let p4 = page(4) { f in
            f.headingBlock("5 \(src.title(words: 1))", font: h1, before: 0, after: 6)
            f.paragraphs(source: src, style: body, lines: 16)
        }
        return Plan(pages: [p1, p2, p3, p4], bodyFont: Face.times(10))
    }

    // MARK: figura mais alta que a tela em qualquer escala legível

    static func tallFigure(_ src: TextSource) -> Plan {
        let body = BodyStyle(font: Face.times(10), leading: 12)
        let region = a4.insetBy(dx: 72, dy: 54)
        // 650 pt: a escala que a faz caber na tela em retrato (500,47 pt) é ≤ 0,77, abaixo do 0,9
        // que mantém o corpo de 10 pt em 9 pt. Não há vale para fatiar: página própria reduzida.
        let page1 = PageSpec(media: a4) { c in
            let f = Flow(canvas: c, region: region)
            f.headingBlock("1 \(src.title(words: 2))", font: Face.timesBold(13), before: 0, after: 6)
            f.paragraphs(source: src, style: body, lines: 34)
            c.columns.append(c.blocksUnion(from: 0)!)
            pageNumber(c, "1", at: CGPoint(x: region.midX, y: 30))
        }
        let page2 = PageSpec(media: a4) { c in
            let f = Flow(canvas: c, region: region)
            f.headingBlock("Appendix A \(src.title(words: 2))", font: Face.timesBold(13), before: 0, after: 8)
            f.figure(.diagram, width: 380, height: 650, source: src, before: 0)
            f.caption("Figure 1: ", source: src, lines: 2)
            c.columns.append(c.blocksUnion(from: 0)!)
            pageNumber(c, "2", at: CGPoint(x: region.midX, y: 30))
        }
        return Plan(pages: [page1, page2], bodyFont: Face.times(10))
    }
}
