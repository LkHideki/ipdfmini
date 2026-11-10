import CoreGraphics
import CoreText
import Foundation

/// Definição página a página de cada cenário. Dimensões em pontos.
enum Scenarios {
    static func plan(for s: Scenario) -> Plan {
        // Sementes fixas por cenário.
        switch s {
        case .book6x9: return book6x9(TextSource(seed: 0xB006_0001))
        case .a4Report: return a4Report(TextSource(seed: 0xA400_0002))
        case .latexArticleA4: return latexArticle(TextSource(seed: 0x1A7E_0003))
        case .twoColumnArticle: return twoColumn(TextSource(seed: 0x2C01_0004))
        case .rotatedPages: return rotated(TextSource(seed: 0x4074_0005))
        case .offsetBoxes: return offsetBoxes(TextSource(seed: 0x0FF5_0006))
        case .cropMarks: return cropMarks(TextSource(seed: 0xC40B_0007))
        case .arxivStamp: return arxivStamp(TextSource(seed: 0xA4C1_0008))
        case .navigation: return navigation(TextSource(seed: 0x7A71_0009))
        case .scannedPage: return scanned(TextSource(seed: 0x5CA2_000A))
        case .mixedSizes: return mixedSizes(TextSource(seed: 0x31ED_000B))
        case .arxivTwoColumn: return arxivTwoColumn(TextSource(seed: 0x3A2C_000C))
        case .reportWithFigures: return reportWithFigures(TextSource(seed: 0x3E90_000D))
        case .tallFigure: return tallFigure(TextSource(seed: 0x7A11_000E))
        }
    }

    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let book = CGRect(x: 0, y: 0, width: 432, height: 648)

    // MARK: livro 6x9

    static var bookStyle: BodyStyle { BodyStyle(font: Face.times(10), leading: 12.1) }

    /// Página de livro: mancha de 324 × 518 pt, deslocada pela lombada (ímpar = recto,
    /// margem interna à esquerda), cabeçalho corrido e folio. Os 518 pt cabem 43 linhas.
    static func bookPage(_ c: Canvas, in page: CGRect, number: Int, source: TextSource,
                         chapter: String? = nil, maxLines: Int? = nil) {
        let recto = number % 2 == 1
        let region = CGRect(x: page.minX + (recto ? 60 : 48), y: page.maxY - 70 - 518, width: 324, height: 518)
        let flow = Flow(canvas: c, region: region)
        if let chapter { flow.heading(chapter, font: Face.helveticaBold(16), before: 0, after: 24) }
        flow.fill(source: source, style: bookStyle, maxLines: maxLines)
        if let u = flow.union { c.columns.append(u) }
        c.text("The Synthetic Corpus", font: Face.timesItalic(8), at: CGPoint(x: region.midX, y: region.maxY + 18),
               align: .center, role: .headerFooter)
        c.text("\(number)", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30),
               align: .center, role: .headerFooter)
    }

    static func book6x9(_ src: TextSource) -> Plan {
        // Capítulos começam em páginas ímpares; a 4 é a página em branco que garante isso.
        // 3, 8 e 12 são as últimas, curtas, de cada capítulo.
        let chapterStarts: [Int: Int] = [1: 1, 5: 2, 9: 3]
        let short: [Int: Int] = [3: 9, 8: 14, 12: 6]
        let pages = (1...12).map { n in
            PageSpec(media: book) { c in
                if n == 4 { return }
                let title = chapterStarts[n].map { "Chapter \($0) \(src.title(words: 2))" }
                bookPage(c, in: book, number: n, source: src, chapter: title, maxLines: short[n])
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: relatório A4

    static func a4Report(_ src: TextSource) -> Plan {
        let style = BodyStyle(font: Face.helvetica(10), leading: 13)
        let region = a4.insetBy(dx: 72, dy: 72)
        let pages = (1...4).map { n in
            PageSpec(media: a4) { c in
                let flow = Flow(canvas: c, region: region)
                if n == 1 {
                    flow.heading("Synthetic Quarterly Report", font: Face.helveticaBold(20), before: 0, after: 8)
                    flow.heading(src.title(words: 3), font: Face.helvetica(11), before: 0, after: 14)
                }
                flow.heading("\(n). \(src.title(words: 2))", font: Face.helveticaBold(13), before: n == 1 ? 6 : 0, after: 8)
                flow.fill(source: src, style: style, maxLines: 22)
                flow.heading("\(n).1 \(src.title(words: 3))", font: Face.helveticaBold(11), before: 8, after: 6)
                flow.fill(source: src, style: style, maxLines: n == 4 ? 16 : nil)
                if let u = flow.union { c.columns.append(u) }
                c.text("Synthetic Quarterly Report", font: Face.helvetica(8),
                       at: CGPoint(x: region.minX, y: region.maxY + 30), role: .headerFooter)
                c.text("Page \(n)", font: Face.helvetica(8), at: CGPoint(x: region.midX, y: region.minY - 36),
                       align: .center, role: .headerFooter)
            }
        }
        return Plan(pages: pages, bodyFont: Face.helvetica(10))
    }

    // MARK: artigo LaTeX A4

    static func latexArticle(_ src: TextSource) -> Plan {
        // article 10 pt em A4: textwidth 345 pt, textheight 598 pt, baselineskip 12 pt.
        let style = BodyStyle(font: Face.times(10), leading: 12, indent: 15)
        let region = CGRect(x: 125, y: 842 - 110 - 598, width: 345, height: 598)
        let pages = (1...4).map { n in
            PageSpec(media: a4) { c in
                let flow = Flow(canvas: c, region: region)
                if n == 1 {
                    flow.heading(src.title(words: 4), font: Face.timesBold(17), before: 0, after: 14, align: .center)
                    flow.heading(src.title(words: 2), font: Face.times(12), before: 0, after: 18, align: .center)
                    flow.heading("Abstract", font: Face.timesBold(10), before: 0, after: 6, align: .center)
                    let abstract = Flow(canvas: c, region: CGRect(x: region.minX + 25, y: region.minY,
                                                                  width: region.width - 50, height: flow.cursor - region.minY))
                    abstract.fill(source: src, style: style, maxLines: 7)
                    if let u = abstract.union { c.columns.append(u) }
                    flow.skip(7 * style.leading + 14)
                    flow.heading("1 \(src.title(words: 1))", font: Face.timesBold(12), before: 0, after: 6)
                }
                flow.fill(source: src, style: style, maxLines: n == 4 ? 21 : nil)
                if let u = flow.union { c.columns.append(u) }
                c.text("\(n)", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30),
                       align: .center, role: .headerFooter)
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: artigo em duas colunas (Letter)

    static func twoColumn(_ src: TextSource) -> Plan {
        let style = BodyStyle(font: Face.times(10), leading: 12)
        let colWidth: CGFloat = 245, gutter: CGFloat = 14
        let left: CGFloat = 54, top: CGFloat = 792 - 60, bottom: CGFloat = 66
        let pages = (1...3).map { n in
            PageSpec(media: letter) { c in
                var colTop = top
                if n == 1 {
                    let head = Flow(canvas: c, region: CGRect(x: left, y: bottom, width: 504, height: top - bottom))
                    head.heading(src.title(words: 4), font: Face.helveticaBold(18), before: 0, after: 8, align: .center)
                    head.heading(src.title(words: 3) + ", " + src.title(words: 2), font: Face.helvetica(10),
                                 before: 0, after: 14, align: .center)
                    head.heading("Abstract", font: Face.helveticaBold(10), before: 0, after: 4)
                    head.fill(source: src, style: style, maxLines: 6)
                    colTop = head.cursor - 14
                }
                let colRect = { (i: Int) in
                    CGRect(x: left + CGFloat(i) * (colWidth + gutter), y: bottom, width: colWidth, height: colTop - bottom)
                }
                let c1 = Flow(canvas: c, region: colRect(0))
                c1.fill(source: src, style: style)
                if let u = c1.union { c.columns.append(u) }
                let c2 = Flow(canvas: c, region: colRect(1))
                c2.fill(source: src, style: style, maxLines: n == 3 ? 22 : nil)
                if let u = c2.union { c.columns.append(u) }
                c.text("\(n)", font: Face.times(10), at: CGPoint(x: 306, y: 36), align: .center, role: .headerFooter)
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: páginas rotacionadas

    /// Corpo de texto simples dentro de `region`, com título e folio.
    static func plainPage(_ c: Canvas, region: CGRect, number: Int, title: String, source: TextSource,
                          footerY: CGFloat) {
        let style = BodyStyle(font: Face.times(10), leading: 12)
        let flow = Flow(canvas: c, region: region)
        flow.heading(title, font: Face.helveticaBold(12), before: 0, after: 10)
        flow.fill(source: source, style: style)
        if let u = flow.union { c.columns.append(u) }
        c.text("\(number)", font: Face.times(10), at: CGPoint(x: region.midX, y: footerY),
               align: .center, role: .headerFooter)
    }

    static func rotated(_ src: TextSource) -> Plan {
        // Margens assimétricas (esq 60, dir 30, base 80, topo 40) denunciam erro de rotação.
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let region = CGRect(x: 60, y: 80, width: 310, height: 480)
        let pages = [0, 90, 180, 270].enumerated().map { i, rot in
            var spec = PageSpec(media: media) { c in
                plainPage(c, region: region, number: i + 1, title: "Rotation \(rot) degrees", source: src, footerY: 50)
            }
            spec.rotation = rot
            return spec
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: caixas com origem deslocada

    static func offsetBoxes(_ src: TextSource) -> Plan {
        // Tipo A: MediaBox 612×792 com origem (36,48); CropBox 540×700 dentro dela.
        // Tipo B: MediaBox A4 com origem (24,18); CropBox deslocada. Origem negativa não é gerada:
        // o CGContext recorta o desenho à página, e coordenadas negativas ficariam de fora.
        let mediaA = CGRect(x: 36, y: 48, width: 612, height: 792)
        let cropA = CGRect(x: 72, y: 96, width: 540, height: 700)
        let mediaB = CGRect(x: 24, y: 18, width: 595, height: 842)
        let cropB = CGRect(x: 60, y: 40, width: 500, height: 760)
        let specs: [(CGRect, CGRect, Int)] = [(mediaA, cropA, 0), (mediaB, cropB, 0), (mediaA, cropA, 90), (mediaB, cropB, 270)]
        let pages = specs.enumerated().map { i, s in
            var spec = PageSpec(media: s.0, crop: s.1) { c in
                let region = s.1.insetBy(dx: 40, dy: 50)
                plainPage(c, region: region, number: i + 1, title: "Offset boxes \(i + 1)", source: src,
                          footerY: s.1.minY + 22)
            }
            spec.rotation = s.2
            return spec
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: marcas de corte

    static func cropMarks(_ src: TextSource) -> Plan {
        let media = CGRect(x: 0, y: 0, width: 504, height: 720)
        let trim = CGRect(x: 36, y: 36, width: 432, height: 648)
        let bleed = trim.insetBy(dx: -9, dy: -9)
        let pages = (1...3).map { n in
            let spec = PageSpec(media: media, trim: trim, bleed: bleed) { c in
                bookPage(c, in: trim, number: n, source: src, maxLines: n == 3 ? 12 : nil)
                // Marcas de corte: 20 pt de traço a 12 pt do corte, em cada canto e eixo.
                let off: CGFloat = 12, len: CGFloat = 20, w: CGFloat = 0.5
                for x in [trim.minX, trim.maxX] {
                    let dir: CGFloat = x == trim.minX ? -1 : 1
                    for y in [trim.minY, trim.maxY] {
                        let vdir: CGFloat = y == trim.minY ? -1 : 1
                        c.strokeSegment(from: CGPoint(x: x + dir * off, y: y), to: CGPoint(x: x + dir * (off + len), y: y),
                                        width: w, role: .ignorable)
                        c.strokeSegment(from: CGPoint(x: x, y: y + vdir * off), to: CGPoint(x: x, y: y + vdir * (off + len)),
                                        width: w, role: .ignorable)
                    }
                }
                // Alvos de registro nos meios do pé e da esquerda.
                for centre in [CGPoint(x: trim.midX, y: 18), CGPoint(x: 18, y: trim.midY)] {
                    c.strokeCircle(center: centre, radius: 5, width: w, role: .ignorable)
                    c.strokeSegment(from: CGPoint(x: centre.x - 8, y: centre.y), to: CGPoint(x: centre.x + 8, y: centre.y),
                                    width: w, role: .ignorable)
                    c.strokeSegment(from: CGPoint(x: centre.x, y: centre.y - 8), to: CGPoint(x: centre.x, y: centre.y + 8),
                                    width: w, role: .ignorable)
                }
            }
            return spec
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: carimbo arXiv

    static func arxivStamp(_ src: TextSource) -> Plan {
        let style = BodyStyle(font: Face.times(10), leading: 12)
        let region = letter.insetBy(dx: 72, dy: 72)
        let pages = (1...2).map { n in
            PageSpec(media: letter) { c in
                let flow = Flow(canvas: c, region: region)
                if n == 1 {
                    flow.heading(src.title(words: 4), font: Face.timesBold(16), before: 0, after: 8, align: .center)
                    flow.heading(src.title(words: 3), font: Face.times(11), before: 0, after: 16, align: .center)
                    // Carimbo: texto girado 90° (lê de baixo para cima) na margem esquerda, só na página 1.
                    c.text("arXiv:2411.01234v1 [cs.CV] 4 Nov 2024", font: Face.times(20), at: CGPoint(x: 34, y: 220),
                           angle: .pi / 2, gray: 0.5, role: .ignorable)
                }
                flow.fill(source: src, style: style)
                if let u = flow.union { c.columns.append(u) }
                c.text("\(n)", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30),
                       align: .center, role: .headerFooter)
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    // MARK: navegação

    static func navigation(_ src: TextSource) -> Plan {
        let style = BodyStyle(font: Face.times(10), leading: 12)
        let region = letter.insetBy(dx: 72, dy: 72)
        let top = CGPoint(x: region.minX, y: region.maxY)
        let chapterTitles = (1...3).map { _ in src.title(words: 2) }
        // Destino de cada capítulo no sumário: páginas 2, 4 e 6 (índices 1, 3 e 5).
        let chapterPages = [1, 3, 5]

        func body(_ c: Canvas, n: Int, title: String?, sub: String?, lines: Int? = nil) -> Flow {
            let flow = Flow(canvas: c, region: region)
            if let title { flow.heading(title, font: Face.helveticaBold(16), before: 0, after: 12) }
            if let sub { flow.heading(sub, font: Face.helveticaBold(12), before: 0, after: 8) }
            flow.fill(source: src, style: style, maxLines: lines)
            if let u = flow.union { c.columns.append(u) }
            c.text("\(n)", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30),
                   align: .center, role: .headerFooter)
            return flow
        }

        var pages: [PageSpec] = []
        pages.append(PageSpec(media: letter) { c in
            let flow = Flow(canvas: c, region: region)
            flow.heading("Navigation Test Document", font: Face.helveticaBold(20), before: 0, after: 20)
            flow.heading("Contents", font: Face.helveticaBold(12), before: 0, after: 10)
            for (i, t) in chapterTitles.enumerated() {
                let baseline = flow.cursor - CTFontGetCapHeight(Face.times(12))
                let a = c.text("Chapter \(i + 1) \(t)", font: Face.times(12), at: CGPoint(x: region.minX, y: baseline))
                let b = c.text("\(chapterPages[i] + 1)", font: Face.times(12), at: CGPoint(x: region.maxX, y: baseline), align: .right)
                if let a, let b {
                    c.links.append(LinkSpec(rect: a.union(b), target: .page(chapterPages[i], top)))
                }
                flow.skip(22)
            }
            c.text("1", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30), align: .center, role: .headerFooter)
        })
        // Página 2: capítulo 1, seção 1.1, com um realce numa linha do meio.
        pages.append(PageSpec(media: letter) { c in
            let flow = body(c, n: 2, title: "Chapter 1 \(chapterTitles[0])", sub: "1.1 \(src.title(words: 2))")
            let target = flow.lineRects[8]
            c.highlights.append(CGRect(x: target.minX + 30, y: target.minY, width: 120, height: target.height))
        })
        // Página 3: seção 1.2 e uma linha com URL externa.
        pages.append(PageSpec(media: letter) { c in
            let flow = Flow(canvas: c, region: region)
            flow.heading("1.2 \(src.title(words: 2))", font: Face.helveticaBold(12), before: 0, after: 8)
            flow.fill(source: src, style: style, maxLines: 12)
            let urlLine = "See https://example.org/ipdfmini for details."
            flow.place([TextLine(text: urlLine, justify: false, indent: 0)], style: style)
            if let r = flow.lineRects.last {
                c.links.append(LinkSpec(rect: r, target: .url(URL(string: "https://example.org/ipdfmini")!)))
            }
            flow.fill(source: src, style: style)
            if let u = flow.union { c.columns.append(u) }
            c.text("3", font: Face.times(10), at: CGPoint(x: region.midX, y: region.minY - 30), align: .center, role: .headerFooter)
        })
        pages.append(PageSpec(media: letter) { c in
            _ = body(c, n: 4, title: "Chapter 2 \(chapterTitles[1])", sub: nil)
        })
        pages.append(PageSpec(media: letter) { c in
            _ = body(c, n: 5, title: nil, sub: "2.1 \(src.title(words: 2))")
        })
        // Página 6: capítulo 3 e um link de volta ao sumário.
        pages.append(PageSpec(media: letter) { c in
            let flow = body(c, n: 6, title: "Chapter 3 \(chapterTitles[2])", sub: nil, lines: 30)
            flow.skip(style.leading)
            flow.place([TextLine(text: "Back to contents", justify: false, indent: 0)], style: style)
            if let r = flow.lineRects.last {
                c.links.append(LinkSpec(rect: r, target: .page(0, top)))
            }
            if let u = flow.union { c.columns = [u] }
        })

        let outline = [
            OutlineItem(title: "Chapter 1 \(chapterTitles[0])", page: 1, point: top, children: [
                OutlineItem(title: "1.1", page: 1, point: top),
                OutlineItem(title: "1.2", page: 2, point: top),
            ]),
            OutlineItem(title: "Chapter 2 \(chapterTitles[1])", page: 3, point: top, children: [
                OutlineItem(title: "2.1", page: 4, point: top),
            ]),
            OutlineItem(title: "Chapter 3 \(chapterTitles[2])", page: 5, point: top),
        ]
        return Plan(pages: pages, outline: outline, bodyFont: Face.times(10))
    }

    // MARK: página escaneada

    static func scanned(_ src: TextSource) -> Plan {
        let pages = (1...2).map { n in
            PageSpec(media: book) { c in
                scanPage(c, media: book, seed: 0x5CA2_0000 + UInt64(n)) { sub in
                    bookPage(sub, in: book, number: n, source: src, maxLines: n == 2 ? 30 : nil)
                }
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }

    /// Rasteriza `draw` num bitmap cinza de 2 px/pt (144 dpi) com papel levemente acinzentado e ruído,
    /// e o cola cobrindo a página. A tinta registrada vem dos mesmos glifos desenhados no bitmap;
    /// não há camada de texto, então nenhuma palavra entra na verdade.
    static func scanPage(_ c: Canvas, media: CGRect, scale: CGFloat = 2, seed: UInt64,
                         draw: (Canvas) -> Void) {
        let w = Int(media.width * scale), h = Int(media.height * scale)
        var pixels = [UInt8](repeating: 0, count: w * h)
        var rng = SplitMix64(state: seed)
        // Papel ~0,91 com leve gradiente horizontal e ruído uniforme de ±6 níveis.
        for y in 0..<h {
            for x in 0..<w {
                let base = 236.0 - 8.0 * Double(x) / Double(w)
                pixels[y * w + x] = UInt8(base + Double(Int.random(in: -6...6, using: &rng)))
            }
        }
        let sub: Canvas? = pixels.withUnsafeMutableBytes { buf -> Canvas? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            let canvas = Canvas(ctx: ctx)
            draw(canvas)
            // Bitmap e página compartilham o espaço em pontos (mídia na origem).
            if let image = ctx.makeImage() {
                c.ctx.draw(image, in: media)
            }
            return canvas
        }
        guard let sub else { fatalError("SyntheticCorpus: bitmap do scan não criado") }
        c.ink += sub.ink
        c.lines += sub.lines
        c.headerFooter += sub.headerFooter
        c.columns += sub.columns
        c.isScan = true
    }

    // MARK: livro com prancha em paisagem

    static func mixedSizes(_ src: TextSource) -> Plan {
        let landscape = CGRect(x: 0, y: 0, width: 648, height: 432)
        let pages = (1...7).map { n in
            if n == 4 {
                return PageSpec(media: landscape) { c in
                    let fig = CGRect(x: 72, y: 110, width: 504, height: 250)
                    c.figure(fig, fillGray: 0.85, borderWidth: 1)
                    c.text("Plate 1 \(src.title(words: 3))", font: Face.times(9),
                           at: CGPoint(x: fig.midX, y: 80), align: .center)
                }
            }
            return PageSpec(media: book) { c in
                bookPage(c, in: book, number: n, source: src, maxLines: n == 7 ? 15 : nil)
            }
        }
        return Plan(pages: pages, bodyFont: Face.times(10))
    }
}
