import CoreGraphics
import Foundation
import MiniGeometry
import PDFKit

/// Resultado de uma página com o que a etapa de documento ainda precisa.
struct PageWork: Sendable, Equatable {
    var analysis: PageAnalysis
    /// Texto de cada linha, paralelo a `analysis.lines` ("" quando veio do perfil).
    var lineTexts: [String]
    var columns: Int
    var imageCoverage: Double
    var samples: [XHeightSample]
}

/// Análise de uma página. PLAN.md §5.1–§5.5.
enum PageAnalyzer {
    struct TextLine {
        var text: String
        var userRect: CGRect
        /// `characterBounds` (espaço do usuário) de minúsculas de altura-x e de
        /// letras de base reta: dão a altura-x pelo contorno dos glifos.
        var xLetters: [CGRect] = []
        var flatBottoms: [CGRect] = []
    }

    static let xHeightLetters = Set("acegmnopqrsuvwxyz")
    static let flatBottomLetters = Set("hiklmnrxzABDEFHIKLMNPRTXZ")
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

        // §5.1/§5.4: TrimBox menor com tinta fora dela (marcas de corte) → parte-se da TrimBox
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

        // §5.4: carimbo lateral do arXiv, só na página 1
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
        // Fora do escopo do M1: marca-d'água diagonal (§5.4, ignorar no cálculo)
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

        // §5.5: linhas e altura-x
        var lines: [(line: Line, text: String)] = []
        var samples: [XHeightSample] = []
        let darkness = DarknessMap(raster, background: bg, mask: scanLike ? mask : nil)
        func measureLine(_ r0: CGRect, text: String, glyph: (xHeight: CGFloat, baseline: CGFloat)? = nil) {
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
        }
        let usable = textLines.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        if !usable.isEmpty {
            for l in usable {
                let r0 = g0.toPage(l.userRect).intersection(effectivePage0)
                guard !r0.isNull, r0.width > 0.5, r0.height > 0.5 else { continue }
                // texto vertical não tem linha de base horizontal: fica na tinta, fora das linhas
                if r0.height > 1.5 * r0.width && l.text.count >= 3 { continue }
                measureLine(r0, text: l.text, glyph: glyphXHeight(l, g0))
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

        // §5.3 refino: texto + imagens contra o raster
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

        let columns = inkPx.map { countColumns(cols: cols, box: $0, s: s) } ?? 0
        let modes = XHeightStats.modes(samples)
        let analysis = PageAnalysis(index: index, boxes: boxes, geometry: g, kind: kind,
                                    inkBox: inkPage0.map(toFinal), lines: lines.map(\.line), blocks: [],
                                    bodyXHeightPt: modes?.body, smallestXHeightPt: modes?.smallest,
                                    warnings: warnings)
        return PageWork(analysis: analysis, lineTexts: lines.map(\.text), columns: columns,
                        imageCoverage: imageCoverage, samples: samples)
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
            for i in 0..<min(ns.length, range.length) {
                guard let u = Unicode.Scalar(ns.character(at: i)) else { continue }
                let c = Character(u)
                let isX = xHeightLetters.contains(c), isFlat = flatBottomLetters.contains(c)
                guard isX || isFlat else { continue }
                let b = page.characterBounds(at: base + i).standardized
                guard !b.isEmpty, guardRect.contains(b) else { continue }
                if isX { line.xLetters.append(b) }
                if isFlat { line.flatBottoms.append(b) }
            }
            return line
        }
    }

    /// Altura-x e linha de base (espaço de página de `g0`) pelos glifos:
    /// mediana dos topos das minúsculas menos mediana das bases retas.
    static func glyphXHeight(_ l: TextLine, _ g0: PageGeometry) -> (xHeight: CGFloat, baseline: CGFloat)? {
        guard l.xLetters.count >= 3, l.flatBottoms.count >= 2 else { return nil }
        func median(_ v: [CGFloat]) -> CGFloat { let s = v.sorted(); return s[s.count / 2] }
        let top = median(l.xLetters.map { g0.toPage($0).maxY })
        let base = median(l.flatBottoms.map { g0.toPage($0).minY })
        let xh = top - base
        return xh > 0.5 ? (xh, base) : nil
    }

    /// Colunas por vale vertical simples (M1); o XY-cut do M3 substitui.
    /// Vale: ≥ 8 pt de largura, quase sem tinta (≤ 5% da altura, tolera título
    /// e cabeçalho atravessando a calha), no miolo da caixa de tinta.
    static func countColumns(cols: [Float], box: (x0: Int, y0: Int, x1: Int, y1: Int), s: CGFloat) -> Int {
        let w = box.x1 - box.x0, h = box.y1 - box.y0
        guard w > 0, h > 0 else { return 0 }
        let limit = Float(0.05 * Double(h))
        let minGap = Int((8 * s).rounded())
        let lo = box.x0 + Int(0.15 * Double(w)), hi = box.x1 - Int(0.15 * Double(w))
        var valleys = 0, run = 0
        for x in lo..<max(lo, hi) {
            if cols[x] <= limit { run += 1 } else { if run >= minGap { valleys += 1 }; run = 0 }
        }
        if run >= minGap { valleys += 1 }
        return valleys + 1
    }
}
