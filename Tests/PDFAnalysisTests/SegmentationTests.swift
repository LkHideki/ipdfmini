import CoreGraphics
import Foundation
import MiniGeometry
import PDFKit
import SyntheticCorpus
import Testing
@testable import PDFAnalysis

// Segmentação (PLAN.md §5.6): contrato de `Block` provado pixel a pixel contra
// a máscara recalculada pelo mesmo render da análise.

private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

private func analyze(_ data: Data) async throws -> DocumentAnalysis {
    try await DocumentAnalyzer().analyze(data: data)
}

// MARK: verificação do contrato

private struct ContractReport {
    var inkPixels = 0
    var uncovered = 0
    /// Pixel de tinta em mais de um bloco.
    var multiple = 0
    /// Pixel de tinta de bloco de texto fora de todas as linhas do bloco.
    var outsideLines = 0
    var overlappingPairs: [(Int, Int)] = []
    var linesOutsideBlock = 0
}

/// Máscara como a análise calcula (página sem região ignorada nem TrimBox).
private func analysisMask(_ data: Data, page i: Int, geometry g: PageGeometry, scan: Bool) throws -> (InkMask, RasterMapping) {
    let page = try #require(PDFDocument(data: data)?.page(at: i))
    let r = try #require(GrayRaster.render(page: page, geometry: g, pixelsPerPoint: 2))
    let hist = r.histogram()
    let bg = InkMask.mode(hist)
    var m = scan ? InkMask.scan(r, histogram: hist, background: bg) : InkMask.vector(r, background: bg)
    if scan { m.clean(minArea: 4) }
    return (m, r.mapping)
}

/// Pixels cujo centro cai em `r` (min inclusivo, max exclusivo, como `CGRect.contains`).
private func pixelSpan(_ r: CGRect, _ map: RasterMapping, width w: Int, height h: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    let s = map.pixelsPerPoint, box = map.pageBox
    let x0 = Int(((r.minX - box.minX) * s - 0.5).rounded(.up)), x1 = Int(((r.maxX - box.minX) * s - 0.5).rounded(.up))
    let y0 = Int(((box.maxY - r.maxY) * s - 0.5).rounded(.down)) + 1, y1 = Int(((box.maxY - r.minY) * s - 0.5).rounded(.down)) + 1
    return (max(0, x0), max(0, y0), min(w, x1), min(h, y1))
}

/// Cobertura, disjunção e linhas, por grade de pixels (laço por pixel em debug é caro).
/// `restrict`: em scan, tinta fora da caixa de tinta (salpico abaixo do limiar k) não conta.
private func checkContract(_ p: PageAnalysis, mask m: InkMask, map: RasterMapping, restrict: CGRect? = nil) -> ContractReport {
    var rep = ContractReport()
    let blocks = p.blocks
    for i in blocks.indices {
        for j in blocks.indices where j > i {
            let c = blocks[i].rect.intersection(blocks[j].rect)
            if !c.isNull && c.width > 1e-6 && c.height > 1e-6 { rep.overlappingPairs.append((i, j)) }
        }
        for l in blocks[i].lines where !blocks[i].rect.insetBy(dx: -1e-6, dy: -1e-6).contains(l.rect) {
            rep.linesOutsideBlock += 1
        }
    }
    let w = m.width, h = m.height
    var count = [UInt8](repeating: 0, count: w * h)
    var owner = [Int32](repeating: -1, count: w * h)
    var inLine = [Bool](repeating: false, count: w * h)
    for (bi, b) in blocks.enumerated() {
        let sp = pixelSpan(b.rect, map, width: w, height: h)
        for y in sp.y0..<max(sp.y0, sp.y1) {
            for x in sp.x0..<max(sp.x0, sp.x1) { count[y * w + x] &+= 1; owner[y * w + x] = Int32(bi) }
        }
        for l in b.lines {
            let lp = pixelSpan(l.rect, map, width: w, height: h)
            for y in lp.y0..<max(lp.y0, lp.y1) { for x in lp.x0..<max(lp.x0, lp.x1) { inLine[y * w + x] = true } }
        }
    }
    let lim = restrict.map { pixelSpan($0, map, width: w, height: h) } ?? (0, 0, w, h)
    m.values.withUnsafeBufferPointer { v in
        for y in lim.1..<lim.3 {
            for x in lim.0..<lim.2 where v[y * w + x] > 0 {
                let k = y * w + x
                rep.inkPixels += 1
                if count[k] == 0 { rep.uncovered += 1; continue }
                if count[k] > 1 { rep.multiple += 1 }
                if !blocks[Int(owner[k])].lines.isEmpty && !inLine[k] { rep.outsideLines += 1 }
            }
        }
    }
    return rep
}

private func expectContract(_ rep: ContractReport, _ tag: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(rep.inkPixels > 0, "\(tag): sem tinta", sourceLocation: sourceLocation)
    #expect(rep.uncovered == 0, "\(tag): \(rep.uncovered) de \(rep.inkPixels) pixels de tinta fora dos blocos", sourceLocation: sourceLocation)
    #expect(rep.multiple == 0, "\(tag): \(rep.multiple) pixels em mais de um bloco", sourceLocation: sourceLocation)
    #expect(rep.overlappingPairs.isEmpty, "\(tag): blocos sobrepostos \(rep.overlappingPairs)", sourceLocation: sourceLocation)
    #expect(rep.outsideLines == 0, "\(tag): \(rep.outsideLines) pixels de bloco de texto fora das linhas", sourceLocation: sourceLocation)
    #expect(rep.linesOutsideBlock == 0, "\(tag): \(rep.linesOutsideBlock) linhas fora do bloco", sourceLocation: sourceLocation)
}

private func maxEdge(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
}

private func block(containing r: CGRect, in p: PageAnalysis) -> (index: Int, block: Block)? {
    let probe = r.insetBy(dx: 0.5, dy: 0.5)
    return p.blocks.enumerated().first { $0.element.rect.contains(probe) }.map { ($0.offset, $0.element) }
}

private func dump(_ p: PageAnalysis) -> String {
    p.blocks.enumerated().map { i, b in
        let r = b.rect
        return String(format: "#%d %@ col=%@ (%.0f,%.0f %.0f×%.0f) %d linhas", i, b.type.rawValue,
                      b.column.map(String.init) ?? "-", r.minX, r.minY, r.width, r.height, b.lines.count)
    }.joined(separator: "\n")
}

// MARK: página de artigo construída

/// Verdade da página de artigo: tinta de cada elemento.
private struct ArticleTruth {
    var title = CGRect.null
    var abstract = CGRect.null
    var heading = CGRect.null
    var equation = CGRect.null
    var figure = CGRect.null
    var caption = CGRect.null
    var tableCaption = CGRect.null
    var table = CGRect.null
    var note = CGRect.null
    /// Linhas de corpo (tinta exata), por coluna.
    var leftLines: [CGRect] = []
    var rightLines: [CGRect] = []
    var abstractLines: [CGRect] = []
    /// Elementos de cada coluna em ordem de leitura.
    var leftOrder: [CGRect] = []
    var rightOrder: [CGRect] = []
}

/// Letter, título largo centrado, resumo de largura total, duas colunas com
/// título de seção em negrito, equação centrada numerada, figura vetorial com
/// legenda, tabela numérica de 4 colunas com legenda e nota de rodapé em 7 pt.
private func articlePage(_ t: inout ArticleTruth) -> PageSpec {
    let body: CGFloat = 9, lead: CGFloat = 11
    let colW = Ink.pool.map { Ink.width($0, size: body) }.max()!
    let lx: CGFloat = 54, rx: CGFloat = 320
    var truth = ArticleTruth()
    let spec = PageSpec(media: letter) { ctx in
        func para(_ n: Int, x: CGFloat, top: CGFloat, seed: Int) -> [CGRect] {
            (0..<n).map { i in
                Ink.text(Ink.pool[(i + seed) % Ink.pool.count], size: body, at: CGPoint(x: x, y: top - CGFloat(i) * lead), in: ctx)
            }
        }
        let title = "Reading Scientific Papers on a Small Tablet"
        truth.title = Ink.text(title, size: 18, at: CGPoint(x: 306 - Ink.width(title, size: 18) / 2, y: 730), in: ctx)
        truth.abstractLines = (0..<4).map { i in
            let s = Ink.pool[i] + " and " + Ink.pool[i + 3]
            return Ink.text(s, size: body, at: CGPoint(x: lx, y: 700 - CGFloat(i) * lead), in: ctx)
        }
        truth.abstract = truth.abstractLines.reduce(CGRect.null) { $0.union($1) }

        // coluna esquerda
        let p1 = para(12, x: lx, top: 640, seed: 0)
        truth.heading = Ink.text("2 Method", size: 11, at: CGPoint(x: lx, y: 500), font: "TimesNewRomanPS-BoldMT", in: ctx)
        let p2 = para(8, x: lx, top: 482, seed: 2)
        let eq = "f(x) = ax + by \u{2212} c"
        let mid = lx + colW / 2
        truth.equation = Ink.text(eq, size: body, at: CGPoint(x: mid - Ink.width(eq, size: body) / 2, y: 385), in: ctx)
            .union(Ink.text("(1)", size: body, at: CGPoint(x: lx + colW - Ink.width("(1)", size: body), y: 385), in: ctx))
        let p3 = para(10, x: lx, top: 362, seed: 5)
        truth.note = Ink.text("1 " + Ink.pool[7], size: 7, at: CGPoint(x: lx, y: 90), in: ctx)
            .union(Ink.text(Ink.pool[2], size: 7, at: CGPoint(x: lx, y: 81), in: ctx))
        truth.leftLines = p1 + p2 + p3
        truth.leftOrder = [p1.reduce(.null) { $0.union($1) }, truth.heading, p2.reduce(.null) { $0.union($1) },
                           truth.equation, p3.reduce(.null) { $0.union($1) }, truth.note]

        // coluna direita
        let q1 = para(6, x: rx, top: 640, seed: 1)
        // figura vetorial: eixos e barras, sem texto
        ctx.saveGState()
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rx + 10, y: 570)); ctx.addLine(to: CGPoint(x: rx + 10, y: 470)); ctx.addLine(to: CGPoint(x: rx + 230, y: 470))
        ctx.strokePath()
        ctx.setFillColor(gray: 0.4, alpha: 1)
        for (i, h) in [60.0, 85.0, 40.0, 95.0, 70.0].enumerated() {
            ctx.fill(CGRect(x: rx + 25 + CGFloat(i) * 40, y: 471, width: 25, height: h))
        }
        ctx.restoreGState()
        truth.figure = CGRect(x: rx + 9.5, y: 469.5, width: 221, height: 101)
        truth.caption = Ink.text("Figure 1: Bars of a synthetic chart drawn as vectors.", size: 8, at: CGPoint(x: rx, y: 455), in: ctx)
        let q2 = para(5, x: rx, top: 430, seed: 4)
        truth.tableCaption = Ink.text("Table 1: Accuracy of four methods.", size: 8, at: CGPoint(x: rx, y: 362), in: ctx)
        let rows = [["Method", "Acc.", "F1", "Time"], ["A", "0.912", "0.88", "1.2"], ["B", "0.874", "0.81", "0.9"],
                    ["C", "0.951", "0.93", "2.4"], ["D", "0.803", "0.77", "0.4"]]
        var table = CGRect.null
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                table = table.union(Ink.text(cell, size: 8, at: CGPoint(x: rx + 10 + CGFloat(c) * 60, y: 345 - CGFloat(r) * 10), in: ctx))
            }
        }
        truth.table = table
        let q3 = para(8, x: rx, top: 280, seed: 6)
        truth.rightLines = q1 + q2 + q3
        truth.rightOrder = [q1.reduce(.null) { $0.union($1) }, truth.figure, truth.caption, q2.reduce(.null) { $0.union($1) },
                            truth.tableCaption, truth.table, q3.reduce(.null) { $0.union($1) }]
    }
    _ = TestPDF.make([spec])   // força o desenho para capturar a verdade
    t = truth
    return spec
}

/// Cenários sem região ignorada nem TrimBox: a máscara do teste é a mesma da análise.
let plainScenarios: [Scenario] = [.book6x9, .a4Report, .latexArticleA4, .twoColumnArticle, .rotatedPages,
                                          .offsetBoxes, .navigation, .mixedSizes, .scannedPage]

/// Serializada: análise pesada (corpus inteiro, grade de pixels) não roda ao mesmo
/// tempo que o `digitalPageBudget` (extensão em DocumentAnalyzerTests), que mede
/// relógio de parede; em paralelo, a disputa por CPU inflava a medida ~10×.
@Suite(.serialized) struct SerialAnalysisTests {
    @Test func articlePageSegmentation() async throws {
        var t = ArticleTruth()
        let data = TestPDF.make([articlePage(&t)])
        let p = try await analyze(data).pages[0]
        let tag = "artigo\n" + dump(p)

        // contrato: cobertura total, disjunção, linhas coladas
        let (m, map) = try analysisMask(data, page: 0, geometry: p.geometry, scan: false)
        expectContract(checkContract(p, mask: m, map: map), "\(tag)")

        // cada elemento inteiro num bloco só, com o tipo esperado
        let expected: [(String, CGRect, BlockType, Int?)] = [
            ("título", t.title, .heading, nil), ("resumo", t.abstract, .paragraph, nil),
            ("seção", t.heading, .heading, 0), ("equação", t.equation, .equation, 0), ("nota", t.note, .note, 0),
            ("figura", t.figure, .figure, 1), ("legenda", t.caption, .caption, 1),
            ("legenda da tabela", t.tableCaption, .caption, 1), ("tabela", t.table, .table, 1),
        ]
        for (name, r, type, column) in expected {
            guard let (_, b) = block(containing: r, in: p) else {
                Issue.record("\(name) \(r) não cabe num bloco só\n\(tag)")
                continue
            }
            #expect(b.type == type, "\(name): \(b.type)\n\(tag)")
            #expect(b.column == column, "\(name): coluna \(String(describing: b.column))\n\(tag)")
        }

        // ordem de leitura: título, resumo, coluna esquerda inteira, depois a direita
        let order = { (r: CGRect) -> Int in block(containing: r, in: p)?.index ?? -1 }
        let left = t.leftOrder.map(order), right = t.rightOrder.map(order)
        #expect(order(t.title) == 0 && order(t.abstract) == 1, "\(tag)")
        #expect(left == left.sorted() && right == right.sorted(), "ordem dentro das colunas \(left) \(right)\n\(tag)")
        #expect(left.allSatisfy { $0 >= 0 } && right.allSatisfy { $0 >= 0 }, "\(tag)")
        #expect((left.max() ?? 0) < (right.min() ?? 0), "esquerda antes da direita \(left) \(right)\n\(tag)")
        #expect(p.blocks.filter { $0.column == 0 }.allSatisfy { $0.rect.maxX < 320 }, "\(tag)")
        #expect(p.blocks.filter { $0.column == 1 }.allSatisfy { $0.rect.minX > 300 }, "\(tag)")

        // linhas coladas à tinta: cada linha de corpo é uma linha de bloco (±1 pt), nunca partida
        let blockLines = p.blocks.flatMap(\.lines)
        for l in t.leftLines + t.rightLines + t.abstractLines {
            let near = blockLines.filter { $0.rect.intersects(l) }
            #expect(near.count == 1, "linha \(l): \(near.count) linhas de bloco")
            if let b = near.first { #expect(maxEdge(b.rect, l) <= 1, "linha \(l) × \(b.rect)") }
        }
        // altura-x por linha do método atual: corpo de 9 pt dentro de 5%
        let bodyLine = try #require(blockLines.first { $0.rect.intersects(t.leftLines[0]) })
        #expect(abs(bodyLine.xHeightPt - Ink.xHeight(9)) <= 0.05 * Ink.xHeight(9), "altura-x \(bodyLine.xHeightPt)")
        // palavras pelas posições dos caracteres: "the quick brown fox jumps over the lazy dog and runs away"
        #expect(bodyLine.words.count == 12, "palavras \(bodyLine.words.count)")
        #expect(bodyLine.words.allSatisfy { bodyLine.rect.insetBy(dx: -1e-6, dy: -1e-6).contains($0) })
    }

    @Test func tableIsNotTwoColumns() async throws {
        // tabela de largura total numa página de coluna única: vãos alinhados, células estreitas
        var table = CGRect.null
        let data = TestPDF.make([PageSpec(media: letter) { ctx in
            Ink.paragraph(lines: 15, size: 10, leading: 12, x: 72, top: 720, in: ctx)
            for r in 0..<8 {
                for c in 0..<5 {
                    let cell = r == 0 ? ["Name", "Size", "Time", "Error", "Rank"][c] : String(format: "%d.%02d", r * (c + 1), (r * 7 + c * 13) % 100)
                    table = table.union(Ink.text(cell, size: 9, at: CGPoint(x: 90 + CGFloat(c) * 90, y: 500 - CGFloat(r) * 12), in: ctx))
                }
            }
            Ink.paragraph(lines: 15, size: 10, leading: 12, x: 72, top: 380, seed: 3, in: ctx)
        }])
        let doc = try await analyze(data)
        let p = doc.pages[0]
        let (m, map) = try analysisMask(data, page: 0, geometry: p.geometry, scan: false)
        expectContract(checkContract(p, mask: m, map: map), "tabela\n" + dump(p))
        let b = try #require(block(containing: table, in: p), "tabela partida\n\(dump(p))")
        #expect(b.block.type == .table, "\(dump(p))")
        #expect(p.blocks.allSatisfy { $0.column == nil }, "\(dump(p))")
        #expect(doc.kind == .a4Report)
    }

    @Test func twoColumnTableInsideColumnStaysOneBlock() async throws {
        // tabela de 2 colunas de células curtas: calha larga, mas lados estreitos → não é coluna
        var table = CGRect.null
        let data = TestPDF.make([PageSpec(media: letter) { ctx in
            Ink.paragraph(lines: 10, size: 10, leading: 12, x: 72, top: 720, in: ctx)
            for r in 0..<6 {
                table = table.union(Ink.text("Item \(r + 1)", size: 9, at: CGPoint(x: 200, y: 560 - CGFloat(r) * 12), in: ctx))
                table = table.union(Ink.text(String(format: "%.2f", Double(r) * 1.37), size: 9, at: CGPoint(x: 330, y: 560 - CGFloat(r) * 12), in: ctx))
            }
            Ink.paragraph(lines: 10, size: 10, leading: 12, x: 72, top: 460, seed: 2, in: ctx)
        }])
        let p = try await analyze(data).pages[0]
        let b = try #require(block(containing: table, in: p), "tabela partida\n\(dump(p))")
        #expect(b.block.column == nil, "\(dump(p))")
        #expect(b.block.type == .table, "\(dump(p))")
    }

    @Test func shortRightColumnStillReadsLeftFirst() async throws {
        // última página: coluna direita curta e vão de seção só na esquerda abaixo dela
        var left: [CGRect] = [], right: [CGRect] = []
        let data = TestPDF.make([PageSpec(media: letter) { ctx in
            left.append(Ink.paragraph(lines: 30, size: 9, leading: 11, x: 54, top: 720, in: ctx))
            left.append(Ink.paragraph(lines: 20, size: 9, leading: 11, x: 54, top: 370, seed: 3, in: ctx))
            right.append(Ink.paragraph(lines: 25, size: 9, leading: 11, x: 320, top: 720, seed: 1, in: ctx))
        }])
        let doc = try await analyze(data)
        let p = doc.pages[0]
        let li = left.compactMap { block(containing: $0, in: p)?.index }, ri = right.compactMap { block(containing: $0, in: p)?.index }
        #expect(li.count == 2 && ri.count == 1, "\(dump(p))")
        #expect((li.max() ?? 99) < (ri.min() ?? -1), "\(dump(p))")
        #expect(p.blocks.map(\.column) == [0, 0, 1], "\(dump(p))")
    }

    /// Margem esquerda indecisa (três recuos alternados, 1/3 das linhas cada): sem
    /// texto a calha seria rejeitada; a ordem do texto extraído desempata (§5.6).
    /// O caso linha a linha não se constrói assim: o PDFKit reordena por conta
    /// própria e devolve coluna a coluna mesmo com o conteúdo intercalado.
    @Test func textOrderBreaksTie() async throws {
        var left = CGRect.null
        let data = TestPDF.make([PageSpec(media: letter) { ctx in
            for i in 0..<30 {
                left = left.union(Ink.text(Ink.pool[i % 8], size: 9, at: CGPoint(x: 54 + CGFloat(i % 3) * 9, y: 720 - CGFloat(i) * 11), in: ctx))
            }
            Ink.paragraph(lines: 30, size: 9, leading: 11, x: 330, top: 720, seed: 3, in: ctx)
        }])
        let p = try await analyze(data).pages[0]
        #expect(p.blocks.map(\.column) == [0, 1], "\(dump(p))")
        #expect(block(containing: left, in: p)?.block.column == 0, "\(dump(p))")
    }

    @Test func listIsDetected() async throws {
        var list = CGRect.null
        let data = TestPDF.make([PageSpec(media: letter) { ctx in
            Ink.paragraph(lines: 8, size: 10, leading: 12, x: 72, top: 720, in: ctx)
            for i in 0..<4 {
                list = list.union(Ink.text("\u{2022} " + Ink.pool[i], size: 10, at: CGPoint(x: 90, y: 600 - CGFloat(i) * 12), in: ctx))
            }
            Ink.paragraph(lines: 8, size: 10, leading: 12, x: 72, top: 530, seed: 2, in: ctx)
        }])
        let p = try await analyze(data).pages[0]
        let b = try #require(block(containing: list, in: p), "\(dump(p))")
        #expect(b.block.type == .list, "\(dump(p))")
    }

    // MARK: corpus sintético


    @Test(arguments: plainScenarios)
    func corpusContractHolds(_ s: Scenario) async throws {
        let doc = Corpus.make(s)
        let a = try await analyze(doc.data)
        for (p, tp) in zip(a.pages, doc.truth.pages) {
            let tag = "\(s) p. \(p.index + 1)"
            guard tp.inkBox != nil else {
                #expect(p.blocks.isEmpty, "\(tag): página vazia com blocos")
                continue
            }
            let (m, map) = try analysisMask(doc.data, page: p.index, geometry: p.geometry, scan: tp.isScan)
            expectContract(checkContract(p, mask: m, map: map, restrict: tp.isScan ? p.inkBox : nil), tag + "\n" + dump(p))
            // nenhuma linha da verdade partida entre blocos ou linhas de bloco
            let blockLines = p.blocks.flatMap(\.lines)
            let tol: CGFloat = tp.isScan ? 2 : 1
            // página girada com o texto deitado: tudo vira bloco atômico (sem linhas
            // horizontais); basta que nenhuma linha seja partida entre blocos
            let sideways = tp.lines.filter { $0.height > 1.5 * $0.width }.count * 2 > tp.lines.count
            for l in tp.lines {
                let owners = p.blocks.filter { $0.rect.intersects(l.insetBy(dx: 0.5, dy: 0.5)) }
                #expect(owners.count == 1, "\(tag): linha \(l) em \(owners.count) blocos")
                // texto vertical (página girada, texto deitado) não tem linha horizontal:
                // fica num bloco atômico; basta não ser partido
                if sideways || l.height > 1.5 * l.width { continue }
                let near = blockLines.filter { $0.rect.intersects(l.insetBy(dx: 0.5, dy: 0.5)) }
                #expect(near.count == 1, "\(tag): linha \(l) em \(near.count) linhas de bloco")
            }
            // Linha de bloco colada à tinta: contém os trechos da verdade que toca e
            // tem a mesma altura. Na horizontal pode passar deles: o sumário registra
            // título e número em separado, sem os pontos-guia entre os dois.
            for b in blockLines where !sideways {
                let u = tp.lines.filter { b.rect.intersects($0.insetBy(dx: 0.5, dy: 0.5)) }.reduce(CGRect.null) { $0.union($1) }
                guard !u.isNull else { continue }   // tinta que a verdade não registra como linha (fios, figuras)
                #expect(b.rect.insetBy(dx: -tol, dy: -tol).contains(u) && abs(b.rect.minY - u.minY) <= tol && abs(b.rect.maxY - u.maxY) <= tol,
                        "\(tag): linha de bloco \(b.rect) × verdade \(u)")
            }
        }
    }

    @Test func corpusTwoColumnReadingOrder() async throws {
        let doc = Corpus.make(.twoColumnArticle)
        let a = try await analyze(doc.data)
        #expect(a.kind == .twoColumnArticle)
        for (p, tp) in zip(a.pages, doc.truth.pages) {
            let tag = "p. \(p.index + 1)\n" + dump(p)
            // colunas da verdade: na p. 1 a primeira é o resumo (largura total)
            let cols = tp.columns.filter { $0.width < 300 }
            #expect(cols.count == 2, "\(tag)")
            let col0 = p.blocks.enumerated().filter { $0.element.column == 0 }
            let col1 = p.blocks.enumerated().filter { $0.element.column == 1 }
            #expect(!col0.isEmpty && !col1.isEmpty, "\(tag)")
            #expect(col0.allSatisfy { cols[0].insetBy(dx: -2, dy: -2).contains($0.element.rect) }, "\(tag)")
            #expect(col1.allSatisfy { cols[1].insetBy(dx: -2, dy: -2).contains($0.element.rect) }, "\(tag)")
            #expect((col0.map(\.offset).max() ?? 0) < (col1.map(\.offset).min() ?? 0), "\(tag)")
            // largura total (título, resumo) antes das colunas; rodapé no fim
            let full = p.blocks.enumerated().filter { $0.element.column == nil && $0.element.type != .headerFooter }
            #expect(full.allSatisfy { $0.offset < (col0.map(\.offset).min() ?? 0) }, "\(tag)")
            #expect(p.blocks.last?.type == .headerFooter, "\(tag)")
            if p.index == 0 { #expect(p.blocks.first?.type == .heading, "\(tag)") }
        }
    }

    @Test func corpusLatexArticleIsOneColumn() async throws {
        let doc = Corpus.make(.latexArticleA4)
        let a = try await analyze(doc.data)
        #expect(a.kind == .a4Report)
        for p in a.pages {
            #expect(p.blocks.allSatisfy { $0.column == nil }, "p. \(p.index + 1)\n\(dump(p))")
            #expect(p.blocks.filter { $0.type == .headerFooter }.count == 1, "p. \(p.index + 1)\n\(dump(p))")
        }
        // título e "Abstract" da p. 1 como títulos
        let first = a.pages[0]
        #expect(first.blocks.prefix(3).allSatisfy { $0.type == .heading }, "\(dump(first))")
    }

    @Test func scannedWordsFromGapDistribution() async throws {
        let doc = Corpus.make(.scannedPage)
        let p = try await analyze(doc.data).pages[0]
        let lines = p.blocks.filter { $0.type == .paragraph }.flatMap(\.lines)
        #expect(lines.count >= 20, "\(dump(p))")
        // linhas do corpus de livro têm 8–14 palavras; scan sem texto → só a tinta
        let counts = lines.dropLast().map(\.words.count)
        let median = counts.sorted()[counts.count / 2]
        #expect((7...16).contains(median), "palavras por linha \(counts)")
        for l in lines { #expect(l.words.allSatisfy { l.rect.insetBy(dx: -1e-6, dy: -1e-6).contains($0) }) }
    }
}
