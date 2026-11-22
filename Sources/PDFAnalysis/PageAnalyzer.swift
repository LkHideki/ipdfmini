import CoreGraphics
import Foundation
import MiniGeometry
import PDFKit

/// Resultado de uma página com o que a etapa de documento ainda precisa.
struct PageWork: Sendable, Equatable {
    var analysis: PageAnalysis
    /// Texto de cada linha, paralelo a `analysis.lines` ("" quando veio do perfil).
    var lineTexts: [String]
    /// Colunas da segmentação (`columnCount`); base do `twoColumnArticle`.
    var columns: Int
    var imageCoverage: Double
    var samples: [XHeightSample]
    /// Extensão horizontal da tinta por linha de pixel, para a caixa sem cabeçalho/rodapé.
    var inkRows: InkRows? = nil
}

/// Análise de uma página.
enum PageAnalyzer {
    struct TextLine {
        var text: String
        var userRect: CGRect
        /// `characterBounds` (espaço do usuário) de minúsculas de altura-x e de
        /// letras de base reta: dão a altura-x pelo contorno dos glifos.
        var xLetters: [CGRect] = []
        var flatBottoms: [CGRect] = []
        /// Topos planos: `xTops` (x, v, w) e `flatTops` (u v w x y z).
        var xTops: [CGRect] = []
        var flatTops: [CGRect] = []
        /// Palavras: `characterBounds` agrupados entre espaços (espaço do usuário).
        var words: [CGRect] = []
    }

    static let xHeightLetters = Set("acegmnopqrsuvwxyz")
    static let flatBottomLetters = Set("hiklmnrxzABDEFHIKLMNPRTXZ")
    /// Letras redondas (a c e o s…) passam da linha x por compensação óptica; com
    /// elas na mediana dos topos a altura-x saía ~3% alta no corpus (Times).
    /// A altura-x da fonte (OS/2 sxHeight) é por definição o topo do "x"; em
    /// Helvetica u, y e z sobem 2,4% acima dele (medido no CoreText), v e w não.
    /// Ordem: x/v/w (1 basta: `characterBounds` é exato no contorno, S3), depois
    /// u–z (≥ 3), depois todas as minúsculas de altura-x.
    static let xTopLetters = Set("vwx")
    static let flatTopLetters = Set("uvwxyz")
    static let minFlatTops = 3
    /// Discordância máxima glifo × tinta antes de preferir a tinta.
    static let glyphInkTolerance: CGFloat = 0.25

    static let scanImageCoverage = 0.9
    static let mixedImageCoverage = 0.25
    static let divergenceWarningPt: CGFloat = 12

    static func analyze(page: PDFPage, index: Int, pixelsPerPoint: CGFloat) -> PageWork {
        guard let cg = page.pageRef else {
            let g = PageGeometry(effectiveBox: page.bounds(for: .cropBox), rotation: page.rotation)
            let boxes = PageBoxes(media: page.bounds(for: .mediaBox), crop: page.bounds(for: .cropBox))
            let a = PageAnalysis(index: index, boxes: boxes, geometry: g, kind: .mixed, inkBox: g.pageBox,
                                 warnings: [.renderFailed("página sem CGPDFPage")])
            return PageWork(analysis: a, lineTexts: [], columns: 1, imageCoverage: 0, samples: [])
        }
        let (boxes, rotation) = PageBoxReader.read(cg)
        let visible = PageBoxReader.visibleBox(boxes)
        // g0: geometria da área visível, onde vive o raster; g: geometria final
        let g0 = PageGeometry(effectiveBox: visible, rotation: rotation)
        var warnings: [AnalysisWarning] = []

        let content = ContentScanner.scan(cg)
        let textLines = readTextLines(page)
        let imageCoverage = content.imageCoverage(of: visible)
        let hasVisibleText = !textLines.isEmpty && content.visibleTextOps > 0
        let scanLike = imageCoverage >= scanImageCoverage && !hasVisibleText

        guard let raster = GrayRaster.render(page: page, geometry: g0, pixelsPerPoint: pixelsPerPoint) else {
            // sem raster, a página inteira é a caixa: nunca cortar tinta
            let a = PageAnalysis(index: index, boxes: boxes, geometry: g0, kind: hasVisibleText ? .digitalText : .mixed,
                                 inkBox: g0.pageBox, warnings: [.renderFailed("falha ao rasterizar")])
            return PageWork(analysis: a, lineTexts: [], columns: 1, imageCoverage: imageCoverage, samples: [])
        }
        let map = raster.mapping
        let s = map.pixelsPerPoint
        let hist = raster.histogram()
        let bg = InkMask.mode(hist)
        var mask = scanLike ? InkMask.scan(raster, histogram: hist, background: bg)
                            : InkMask.vector(raster, background: bg)

        // TrimBox menor com tinta fora dela (marcas de corte) → parte-se da TrimBox
        var effective = visible
        var pendingIgnored: [(CGRect, String)] = []   // em espaço de página de g0
        if let trim = PageBoxReader.candidateTrim(boxes, visible: visible) {
            let t = map.pixelRect(g0.toPage(trim))
            let strips = [(0, 0, mask.width, t.y0), (0, t.y1, mask.width, mask.height),
                          (0, t.y0, t.x0, t.y1), (t.x1, t.y0, mask.width, t.y1)]
            let found = strips.compactMap { mask.bounds(x0: $0.0, y0: $0.1, x1: $0.2, y1: $0.3) }
            if !found.isEmpty {
                effective = trim
                let u = found.dropFirst().reduce(found[0]) { (min($0.x0, $1.x0), min($0.y0, $1.y0), max($0.x1, $1.x1), max($0.y1, $1.y1)) }
                pendingIgnored.append((map.pageRect(pixelX: u.0, y: u.1, toX: u.2, toY: u.3), "cropMarks"))
                mask.keepOnly(x0: t.x0, y0: t.y0, x1: t.x1, y1: t.y1)
            }
        }
        let g = PageGeometry(effectiveBox: effective, rotation: rotation)
        func toFinal(_ r: CGRect) -> CGRect { g.toPage(g0.toUser(r)) }
        let effectivePage0 = g0.toPage(effective)

        // carimbo lateral do arXiv, só na página 1
        var excluded = Set<Int>()
        let pageW = g0.pageBox.width
        if index == 0 {
            for (i, l) in textLines.enumerated() {
                let r = g0.toPage(l.userRect)
                guard r.height >= 4 * r.width, r.width <= 0.1 * pageW,
                      r.maxX <= g0.pageBox.minX + 0.2 * pageW,
                      l.text.range(of: "arxiv", options: .caseInsensitive) != nil else { continue }
                let region = r.insetBy(dx: -2, dy: -2)
                let p = map.pixelRect(region)
                mask.clear(x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1)
                pendingIgnored.append((region, "arXivStamp"))
                excluded.insert(i)
            }
        }
        // Fora do escopo do M1: marca-d'água diagonal (ignorar no cálculo)
        // e numeração de linhas na margem (opção de remover).
        for (r, reason) in pendingIgnored { warnings.append(.ignoredRegion(toFinal(r), reason: reason)) }

        if scanLike { mask.clean(minArea: max(2, Int((s * s).rounded()))) }

        let (rows, cols) = mask.profiles()
        // k > 1 em scan: salpico que sobreviveu à limpeza não define a caixa
        let k: Float = scanLike ? Float(max(2, (1.5 * s).rounded())) : 1
        let inkPx = InkMask.inkBox(rows: rows, cols: cols, k: k)
        var inkPage0: CGRect?
        if let b = inkPx {
            // meio pixel de folga pelo antialiasing
            let r = map.pageRect(pixelX: b.x0, y: b.y0, toX: b.x1, toY: b.y1).insetBy(dx: -0.5 / s, dy: -0.5 / s)
            let clipped = r.intersection(effectivePage0)
            inkPage0 = clipped.isNull ? nil : clipped
        }

        // linhas e altura-x
        var lines: [(line: Line, text: String)] = []
        var texts: [TextBox] = []   // espaço de página de g0, na ordem do texto extraído
        var samples: [XHeightSample] = []
        let darkness = DarknessMap(raster, background: bg, mask: scanLike ? mask : nil)
        func measureLine(_ r0: CGRect, text: String, glyph: (xHeight: CGFloat, baseline: CGFloat)? = nil,
                         words: [CGRect] = []) {
            let p = map.pixelRect(r0)
            let prof = darkness.rowProfile(x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1)
            var ink: CGFloat?
            // sem medida (texto invisível, só pontuação): base estimada pela caixa tipográfica
            var baseY = r0.minY + 0.22 * r0.height
            if let m = XHeight.measure(prof) {
                ink = CGFloat(m.baseline - m.xLine) / s
                baseY = map.pageBox.maxY - (CGFloat(p.y0) + CGFloat(m.baseline)) / s
            }
            // Glifo primeiro: a 2 px/pt o rasterizador ajusta a altura-x à grade
            // de pixels em corpos pequenos (8 pt sai ~10% maior na tinta).
            // Tinta é o fallback (scan, linha sem minúsculas) e a verificação cruzada.
            var xh: CGFloat = ink ?? 0
            if let gl = glyph, ink.map({ abs($0 - gl.xHeight) <= Self.glyphInkTolerance * gl.xHeight }) ?? true {
                xh = gl.xHeight
                baseY = gl.baseline
            }
            if xh > 0 { samples.append(XHeightSample(xHeight: xh, weight: r0.width)) }
            let rect = toFinal(r0)
            let base = g.toPage(g0.toUser(CGPoint(x: r0.midX, y: baseY))).y
            lines.append((Line(rect: rect, baseline: base, xHeightPt: xh), text))
            if !text.isEmpty { texts.append(TextBox(rect: r0, text: text, xHeight: xh, baseline: baseY, words: words)) }
        }
        let usable = textLines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        if !usable.isEmpty {
            for l in usable {
                let r0 = g0.toPage(l.userRect).intersection(effectivePage0)
                guard !r0.isNull, r0.width > 0.5, r0.height > 0.5 else { continue }
                // texto vertical não tem linha de base horizontal: fica na tinta, fora das linhas
                if r0.height > 1.5 * r0.width && l.text.count >= 3 { continue }
                measureLine(r0, text: l.text, glyph: glyphXHeight(l, g0), words: l.words.map(g0.toPage))
            }
        } else if let b = inkPx {
            for band in ProfileLines.bands(rows: rows, from: b.y0, to: b.y1, k: k) {
                let h = band.1 - band.0
                guard h >= 3, CGFloat(h) <= 60 * s,
                      let c = mask.bounds(x0: b.x0, y0: band.0, x1: b.x1, y1: band.1) else { continue }
                measureLine(map.pageRect(pixelX: c.x0, y: max(0, band.0 - 1), toX: c.x1, toY: min(mask.height, band.1 + 1)), text: "")
            }
        }
        lines.sort { $0.line.rect.maxY != $1.line.rect.maxY ? $0.line.rect.maxY > $1.line.rect.maxY : $0.line.rect.minX < $1.line.rect.minX }

        // texto + imagens contra o raster
        if hasVisibleText, let ink = inkPage0 {
            var u = CGRect.null
            for l in usable { u = u.union(g0.toPage(l.userRect)) }
            for r in content.imageRects { u = u.union(g0.toPage(r)) }
            u = u.intersection(effectivePage0)
            if !u.isNull {
                let d = max(abs(ink.minX - u.minX), abs(ink.maxX - u.maxX), abs(ink.minY - u.minY), abs(ink.maxY - u.maxY))
                if d > divergenceWarningPt { warnings.append(.inkBoxDivergence(points: (d * 100).rounded() / 100)) }
            }
        }
        if inkPage0 != nil && textLines.isEmpty { warnings.append(.noTextFound) }

        let kind: PageKind
        if inkPage0 == nil { kind = .empty }
        else if scanLike { kind = .scan }
        else if hasVisibleText && imageCoverage < mixedImageCoverage { kind = .digitalText }
        else { kind = .mixed }   // texto + imagens grandes, ou só vetor/imagem parcial

        let inkRows = inkPx.map { _ in
            InkRows(mask: mask, rows: rows, k: k, mapping: map, g0: g0, g: g, clip: effectivePage0)
        }
        let modes = XHeightStats.modes(samples)

        // XY-cut sobre a mesma máscara. Raiz = caixa de tinta: em scan, o
        // salpico fora dela (linhas com < k pixels) não conta como tinta, como na caixa.
        var blocks: [Block] = []
        if let b = inkPx {
            var seg = Segmenter(mask: mask, map: map, darkness: darkness, texts: texts,
                                images: content.imageRects.map(g0.toPage), isScan: scanLike, bodyXHeight: modes?.body)
            func clipFinal(_ r: CGRect) -> CGRect? {
                let c = r.intersection(effectivePage0)
                return c.isNull || c.isEmpty ? nil : toFinal(c)
            }
            for blk in seg.run(root: PixelBox(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)) {
                guard let rect = clipFinal(blk.rect) else { continue }
                let ls = blk.lines.compactMap { l -> Line? in
                    guard let r = clipFinal(l.rect) else { return nil }
                    let base = g.toPage(g0.toUser(CGPoint(x: l.rect.midX, y: l.baseline))).y
                    return Line(rect: r, baseline: base, xHeightPt: l.xHeightPt, words: l.words.compactMap(clipFinal))
                }
                blocks.append(Block(rect: rect, type: blk.type, lines: ls, column: blk.column))
            }
        }
        let columns = columnCount(blocks)
        let analysis = PageAnalysis(index: index, boxes: boxes, geometry: g, kind: kind,
                                    inkBox: inkPage0.map(toFinal), lines: lines.map(\.line), blocks: blocks,
                                    bodyXHeightPt: modes?.body, smallestXHeightPt: modes?.smallest,
                                    warnings: warnings)
        return PageWork(analysis: analysis, lineTexts: lines.map(\.text), columns: columns,
                        imageCoverage: imageCoverage, samples: samples, inkRows: inkRows)
    }

    /// Linhas de `selectionsByLine` (caixa tipográfica, não tinta).
    ///
    /// Altura-x por `characterBounds`, que devolve a tinta do contorno nas
    /// bordas verticais (spike S3). Não usa `attributedString`: a resolução de
    /// fonte por nome que ele faz travou (XPC do registro de fontes sem
    /// resposta) com CoreText em uso por outras threads.
    static func readTextLines(_ page: PDFPage) -> [TextLine] {
        guard let sel = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        // range(at:on:) indexa page.string, que tem quebras de linha que o
        // índice de characterBounds não conta (spike S3): desconta-se as anteriores
        let pageText = (page.string ?? "") as NSString
        var scanned = 0, breaks = 0
        func breaksBefore(_ loc: Int) -> Int {
            let end = min(loc, pageText.length)
            if end < scanned { scanned = 0; breaks = 0 }   // linhas fora de ordem
            while scanned < end {
                let c = pageText.character(at: scanned)
                if c == 0x0A || c == 0x0D { breaks += 1 }
                scanned += 1
            }
            return breaks
        }
        return sel.selectionsByLine().compactMap { l in
            guard let raw = l.string, case let t = raw.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let r = l.bounds(for: page).standardized
            guard !r.isEmpty else { return nil }
            var line = TextLine(text: t, userRect: r)
            let range = l.range(at: 0, on: page)
            guard range.location != NSNotFound else { return line }
            let base = range.location - breaksBefore(range.location)
            let ns = raw as NSString
            // índice de characterBounds pode divergir do texto: caixa fora da linha é descartada
            let guardRect = r.insetBy(dx: -2, dy: -2)
            var word = CGRect.null
            for i in 0..<min(ns.length, range.length) {
                guard let u = Unicode.Scalar(ns.character(at: i)) else { continue }
                let c = Character(u)
                if c.isWhitespace {
                    if !word.isNull { line.words.append(word); word = .null }
                    continue
                }
                let b = page.characterBounds(at: base + i).standardized
                guard !b.isEmpty, guardRect.contains(b) else { continue }
                word = word.union(b)
                let isX = xHeightLetters.contains(c), isFlat = flatBottomLetters.contains(c)
                guard isX || isFlat else { continue }
                if isX { line.xLetters.append(b) }
                if isFlat { line.flatBottoms.append(b) }
                if flatTopLetters.contains(c) { line.flatTops.append(b) }
                if xTopLetters.contains(c) { line.xTops.append(b) }
            }
            if !word.isNull { line.words.append(word) }
            return line
        }
    }

    /// Altura-x e linha de base (espaço de página de `g0`) pelos glifos:
    /// mediana dos topos das minúsculas de topo plano (ou de todas, se a linha
    /// tem poucas) menos mediana das bases retas.
    static func glyphXHeight(_ l: TextLine, _ g0: PageGeometry) -> (xHeight: CGFloat, baseline: CGFloat)? {
        guard l.xLetters.count >= 3, l.flatBottoms.count >= 2 else { return nil }
        func median(_ v: [CGFloat]) -> CGFloat { let s = v.sorted(); return s[s.count / 2] }
        let tops = !l.xTops.isEmpty ? l.xTops : l.flatTops.count >= minFlatTops ? l.flatTops : l.xLetters
        // Topo e base no espaço do usuário, onde o texto está em pé: em página
        // com /Rotate 180 o espaço de página inverte topo e base, a medida dava
        // negativa e caía no raster (~+5% a 2 px/pt).
        let top = median(tops.map(\.maxY))
        let base = median(l.flatBottoms.map(\.minY))
        let xh = top - base
        guard xh > 0.5 else { return nil }
        return (xh, g0.toPage(CGPoint(x: l.userRect.midX, y: base)).y)
    }

    /// Colunas da seção dominante: blocos com `column` ocupando ≥ 40% da área
    /// dos blocos; senão 1 (figura larga ou coluna única). 0 = sem tinta.
    static func columnCount(_ blocks: [Block]) -> Int {
        guard !blocks.isEmpty else { return 0 }
        let area = { (b: Block) in b.rect.width * b.rect.height }
        let total = blocks.reduce(0) { $0 + area($1) }
        let inColumns = blocks.filter { $0.column != nil }
        guard total > 0, inColumns.reduce(0, { $0 + area($1) }) >= 0.4 * total else { return 1 }
        return (inColumns.compactMap(\.column).max() ?? 0) + 1
    }
}
