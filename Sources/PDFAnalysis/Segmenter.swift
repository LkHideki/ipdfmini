import Accelerate
import CoreGraphics
import Foundation
import MiniGeometry

/// Retângulo de pixels do raster da análise, inclusivo-exclusivo.
struct PixelBox: Equatable, Sendable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var midX: Double { Double(x0 + x1) / 2 }
    var midY: Double { Double(y0 + y1) / 2 }

    func union(_ o: PixelBox) -> PixelBox {
        PixelBox(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

/// Linha tipográfica já medida (altura-x medida nos glifos), em espaço de
/// página do raster. A ordem do array é a do texto extraído.
struct TextBox: Sendable {
    var rect: CGRect
    var text: String
    /// 0 = sem medida.
    var xHeight: CGFloat
    var baseline: CGFloat
    var words: [CGRect]
}

/// XY-cut recursivo sobre a máscara de tinta.
///
/// Garantia do contrato de `Block`: cada corte passa só por faixas sem nenhum
/// pixel de tinta e cada nó é apertado à própria tinta; as folhas são, então,
/// disjuntas e cobrem toda a tinta do nó raiz. Linhas saem do perfil
/// horizontal dentro da folha, com o mesmo critério (nenhuma tinta fora).
struct Segmenter {
    let mask: InkMask
    let map: RasterMapping
    let darkness: DarknessMap
    let texts: [TextBox]
    /// Imagens em espaço de página do raster.
    let images: [CGRect]
    let isScan: Bool
    let bodyXHeight: CGFloat?

    // Limiares (pt, salvo indicação)
    /// Calha mínima entre colunas.
    static let gutterMinPt: CGFloat = 8
    /// Calha flanqueada por tinta em ≥ 70% da altura do nó: o lado mais
    /// alto cobre ≥ 70%; o outro, ≥ 20% (coluna direita curta na última página).
    static let gutterExtent = 0.7
    static let gutterShortSide = 0.2
    /// Coluna de texto tem ≥ 12 alturas-x de largura; célula de tabela, não.
    static let columnMinXHeights: CGFloat = 12
    /// Fração de linhas com a mesma margem esquerda (±2 pt): ≥ aceita, < rejeita, entre = desempate.
    static let marginAccept = 0.5
    static let marginReject = 0.3
    static let marginTolerancePt: CGFloat = 2
    /// Vão horizontal que separa blocos: ≥ 1,5 altura-x e ≥ 1,8× o vão típico entre linhas do nó.
    static let hGapXHeights: CGFloat = 1.5
    static let hGapTypical = 1.8
    static let maxDepth = 24

    private struct LeafLine {
        var box: PixelBox
        var xHeight: CGFloat
        var baseline: CGFloat
        var words: [CGRect]
        /// Linhas tipográficas casadas, a de maior sobreposição primeiro.
        var texts: [Int]
        /// Pixels de tinta por (largura × altura-x): traço negrito pesa ~1,5×.
        var density: Double
    }

    private struct Leaf {
        var box: PixelBox
        var column: Int?
        /// Nó da coluna (ou seção de largura total) onde a folha está: base de "centrado".
        var container: PixelBox
        var tableLike: Bool
        var lines: [LeafLine]
    }

    private var leaves: [Leaf] = []
    private var root = PixelBox(x0: 0, y0: 0, x1: 0, y1: 0)

    init(mask: InkMask, map: RasterMapping, darkness: DarknessMap, texts: [TextBox], images: [CGRect],
         isScan: Bool, bodyXHeight: CGFloat?) {
        self.mask = mask
        self.map = map
        self.darkness = darkness
        self.texts = texts
        self.images = images
        self.isScan = isScan
        self.bodyXHeight = bodyXHeight
    }

    private var s: CGFloat { map.pixelsPerPoint }
    /// Altura-x de referência em pixels; sem corpo medido, ~9 pt de corpo.
    private var xhPx: CGFloat { (bodyXHeight ?? 4) * s }

    /// Blocos em ordem de leitura, em espaço de página do raster.
    mutating func run(root r: PixelBox) -> [Block] {
        guard let t = tight(r) else { return [] }
        root = t
        leaves = []
        split(t, column: nil, container: t, depth: 0)
        return finish()
    }

    // MARK: XY-cut

    private mutating func split(_ b: PixelBox, column: Int?, container: PixelBox, depth: Int) {
        let v = verticalCuts(b)
        if depth < Self.maxDepth, !v.cuts.isEmpty {
            var start = b.x0
            var parts: [PixelBox] = []
            for g in v.cuts {
                parts.append(PixelBox(x0: start, y0: b.y0, x1: g.0, y1: b.y1))
                start = g.1
            }
            parts.append(PixelBox(x0: start, y0: b.y0, x1: b.x1, y1: b.y1))
            for (i, p) in parts.enumerated() {
                guard let t = tight(p) else { continue }
                // coluna aninhada (raro) herda o índice da seção mais externa
                split(t, column: column ?? i, container: t, depth: depth + 1)
            }
            return
        }
        let rows = rowProfile(b)
        let bands = runs(rows)
        if depth < Self.maxDepth, bands.count >= 2 {
            let gaps = zip(bands, bands.dropFirst()).map { $1.0 - $0.1 }
            var hMin = Double(Self.hGapXHeights * xhPx)
            // vão típico só com amostra: num nó de 2–3 linhas a mediana é o próprio vão
            if gaps.count >= 3 { hMin = max(hMin, Self.hGapTypical * median(gaps.map(Double.init))) }
            hMin = max(hMin, 3)
            var pieces: [PixelBox] = []
            var top = bands[0].0
            for (i, g) in gaps.enumerated() where Double(g) >= hMin {
                pieces.append(PixelBox(x0: b.x0, y0: b.y0 + top, x1: b.x1, y1: b.y0 + bands[i].1))
                top = bands[i + 1].0
            }
            if !pieces.isEmpty {
                pieces.append(PixelBox(x0: b.x0, y0: b.y0 + top, x1: b.x1, y1: b.y0 + bands[bands.count - 1].1))
                let tightPieces = pieces.compactMap(tight)
                // Faixas vizinhas que, juntas, têm calha válida são a mesma seção de
                // colunas: vão coincidente nas duas colunas não pode intercalar a leitura.
                var groups: [PixelBox] = []
                var cur = tightPieces[0]
                for p in tightPieces.dropFirst() {
                    let u = cur.union(p)
                    if !verticalCuts(u).cuts.isEmpty { cur = u } else { groups.append(cur); cur = p }
                }
                groups.append(cur)
                for g in groups { split(g, column: column, container: container, depth: depth + 1) }
                return
            }
        }
        makeLeaf(b, column: column, container: container, tableLike: v.tableLike, rows: rows)
    }

    /// Calhas aceitas (pixels [x0, x1) vazios) e se o nó parece tabela.
    private func verticalCuts(_ b: PixelBox) -> (cuts: [(Int, Int)], tableLike: Bool) {
        let cols = colProfile(b)
        let gaps = zeroRuns(cols).map { ($0.0 + b.x0, $0.1 + b.x0) }
        let minGap = Int((max(1.5 * xhPx, 4 * s)).rounded())
        let narrowLimit = Double(Self.columnMinXHeights * xhPx)
        // segmentos separados por vãos que nenhum espaço entre palavras alcança
        var segs: [Int] = []
        var start = b.x0
        for g in gaps where g.1 - g.0 >= minGap {
            segs.append(g.0 - start)
            start = g.1
        }
        segs.append(b.x1 - start)
        guard segs.count >= 2 else { return ([], false) }
        let narrow = segs.filter { Double($0) < narrowLimit }.count
        // vários vãos alinhados com células estreitas: tabela, nunca colunas
        if segs.count >= 3 && (narrow >= 2 || median(segs.map(Double.init)) < narrowLimit) { return ([], true) }
        let wideMin = Int((Self.gutterMinPt * s).rounded())
        let wide = gaps.filter { $0.1 - $0.0 >= wideMin }
        var cuts: [(Int, Int)] = []
        var tableLike = false
        for (i, g) in wide.enumerated() {
            let lx0 = i == 0 ? b.x0 : wide[i - 1].1
            let rx1 = i == wide.count - 1 ? b.x1 : wide[i + 1].0
            guard let l = tight(PixelBox(x0: lx0, y0: b.y0, x1: g.0, y1: b.y1)),
                  let r = tight(PixelBox(x0: g.1, y0: b.y0, x1: rx1, y1: b.y1)) else { continue }
            let j = judgeGutter(b, left: l, right: r, gap: g, narrowLimit: narrowLimit)
            if j.accept { cuts.append(g) } else if j.table { tableLike = true }
        }
        return (cuts, tableLike)
    }

    /// Critérios de calha; `table` = rejeitada com cara de tabela.
    private func judgeGutter(_ b: PixelBox, left l: PixelBox, right r: PixelBox, gap: (Int, Int),
                             narrowLimit: Double) -> (accept: Bool, table: Bool) {
        let h = Double(b.height)
        let tall = Double(max(l.height, r.height)), short = Double(min(l.height, r.height))
        guard tall >= Self.gutterExtent * h, short >= Self.gutterShortSide * h else { return (false, false) }
        let lx = leftEdges(l), rx = leftEdges(r)
        guard lx.count >= 3, rx.count >= 3 else { return (false, false) }
        guard Double(l.width) >= narrowLimit, Double(r.width) >= narrowLimit else { return (false, true) }
        let cl = consistency(lx), cr = consistency(rx)
        if cl >= Self.marginAccept && cr >= Self.marginAccept { return (true, false) }
        if cl < Self.marginReject || cr < Self.marginReject { return (false, true) }
        // indeciso: em PDF digital, a ordem do texto extraído desempata
        if let columnMajor = textOrderIsColumnMajor(b, gap: gap) { return (columnMajor, !columnMajor) }
        return (false, true)
    }

    /// Margem esquerda de cada linha (faixa do perfil) dentro do lado.
    private func leftEdges(_ side: PixelBox) -> [Int] {
        let rows = rowProfile(side)
        return lineBands(rows).compactMap {
            mask.bounds(x0: side.x0, y0: side.y0 + $0.0, x1: side.x1, y1: side.y0 + $0.1)?.x0
        }
    }

    private func consistency(_ xs: [Int]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let tol = Double(Self.marginTolerancePt * s)
        let best = xs.map { x in xs.filter { abs(Double($0 - x)) <= tol }.count }.max() ?? 0
        return Double(best) / Double(xs.count)
    }

    /// Texto lido coluna a coluna (≤ 2 trocas de lado) ou linha a linha; nil sem amostra.
    private func textOrderIsColumnMajor(_ b: PixelBox, gap: (Int, Int)) -> Bool? {
        var sides: [Bool] = []   // true = direita
        for t in texts {
            let p = map.pixelRect(t.rect)
            let cy = Double(p.y0 + p.y1) / 2
            guard cy >= Double(b.y0), cy < Double(b.y1), p.x1 > b.x0, p.x0 < b.x1 else { continue }
            if p.x1 <= gap.0 + 1 { sides.append(false) } else if p.x0 >= gap.1 - 1 { sides.append(true) }
        }
        let nR = sides.filter { $0 }.count, nL = sides.count - nR
        guard nL >= 3, nR >= 3 else { return nil }
        let transitions = zip(sides, sides.dropFirst()).filter { $0 != $1 }.count
        return transitions <= 2
    }

    // MARK: folhas e linhas

    private mutating func makeLeaf(_ b: PixelBox, column: Int?, container: PixelBox, tableLike: Bool, rows: [Float]) {
        var lines: [LeafLine] = []
        for band in lineBands(rows) {
            guard let t = tight(PixelBox(x0: b.x0, y0: b.y0 + band.0, x1: b.x1, y1: b.y0 + band.1)) else { continue }
            var ink: Float = 0
            for y in band.0..<band.1 { ink += rows[y] }
            lines.append(makeLine(t, ink: Double(ink)))
        }
        leaves.append(Leaf(box: b, column: column, container: container, tableLike: tableLike, lines: lines))
    }

    private func makeLine(_ t: PixelBox, ink: Double) -> LeafLine {
        let r = pageRect(t)
        var matched: [(Int, CGFloat)] = []
        for (i, tb) in texts.enumerated() {
            let v = min(r.maxY, tb.rect.maxY) - max(r.minY, tb.rect.minY)
            let hOverlap = min(r.maxX, tb.rect.maxX) - max(r.minX, tb.rect.minX)
            guard hOverlap > 0, v >= 0.5 * min(r.height, tb.rect.height) else { continue }
            matched.append((i, v * hOverlap))
        }
        matched.sort { $0.1 > $1.1 }
        let ids = matched.map(\.0)
        var xh: CGFloat = 0
        // sem medida: base estimada como na linha tipográfica (22% acima da base da caixa)
        var baseline = r.minY + 0.22 * r.height
        // altura-x medida nos glifos (tinta como reserva), da linha tipográfica casada
        if let best = ids.first(where: { texts[$0].xHeight > 0 }) {
            xh = texts[best].xHeight
            baseline = texts[best].baseline
        } else if let m = XHeight.measure(darkness.rowProfile(x0: t.x0, y0: t.y0, x1: t.x1, y1: t.y1)) {
            xh = CGFloat(m.baseline - m.xLine) / s
            baseline = map.pageBox.maxY - (CGFloat(t.y0) + CGFloat(m.baseline)) / s
        }
        let probe = r.insetBy(dx: -1, dy: -1)
        var words: [CGRect] = []
        for i in ids {
            for w in texts[i].words where probe.contains(CGPoint(x: w.midX, y: w.midY)) {
                let c = w.intersection(r)
                if !c.isNull && !c.isEmpty { words.append(c) }
            }
        }
        words.sort { $0.minX < $1.minX }
        if words.isEmpty { words = inkWords(t, xHeightPx: xh > 0 ? xh * s : xhPx) }
        let density = ink / (Double(max(1, t.width)) * Double(max(1, (xh > 0 ? xh : bodyXHeight ?? 4) * s)))
        return LeafLine(box: t, xHeight: xh, baseline: baseline, words: words, texts: ids, density: density)
    }

    /// Palavras pela distribuição bimodal dos vãos da linha: vãos entre
    /// letras e entre palavras formam duas classes; separa-se pelo limiar de Otsu
    /// quando as médias diferem ≥ 1,8×, senão por 0,3 altura-x.
    private func inkWords(_ t: PixelBox, xHeightPx: CGFloat) -> [CGRect] {
        let cols = colProfile(t)
        let segs = runs(cols)
        guard segs.count >= 2 else { return [pageRect(t)] }
        let gaps = zip(segs, segs.dropFirst()).map { Double($1.0 - $0.1) }
        var threshold = Double(0.3 * xHeightPx)
        let sorted = gaps.sorted()
        if sorted.count >= 2 {
            var bestVar = -1.0, bestK = 0
            let total = sorted.reduce(0, +)
            var acc = 0.0
            for k in 1..<sorted.count {
                acc += sorted[k - 1]
                let n0 = Double(k), n1 = Double(sorted.count - k)
                let m0 = acc / n0, m1 = (total - acc) / n1
                let v = n0 * n1 * (m1 - m0) * (m1 - m0)
                if v > bestVar { bestVar = v; bestK = k }
            }
            let m0 = sorted[..<bestK].reduce(0, +) / Double(bestK)
            let m1 = sorted[bestK...].reduce(0, +) / Double(sorted.count - bestK)
            if m1 >= 1.8 * max(m0, 0.5) { threshold = (sorted[bestK - 1] + sorted[bestK]) / 2 }
        }
        threshold = max(threshold, Double(0.2 * xHeightPx), 1)
        var words: [CGRect] = []
        var start = segs[0].0
        for (i, g) in gaps.enumerated() where g >= threshold {
            words.append(pageRect(PixelBox(x0: t.x0 + start, y0: t.y0, x1: t.x0 + segs[i].1, y1: t.y1)))
            start = segs[i + 1].0
        }
        words.append(pageRect(PixelBox(x0: t.x0 + start, y0: t.y0, x1: t.x0 + segs[segs.count - 1].1, y1: t.y1)))
        return words
    }

    // MARK: tipos (heurísticas simples; erro de tipo é aceitável, de cobertura não)

    private func finish() -> [Block] {
        let xhs = leaves.flatMap { $0.lines.map(\.xHeight) }.filter { $0 > 0 }
        let ref = bodyXHeight ?? (xhs.isEmpty ? 0 : CGFloat(median(xhs.map(Double.init))))
        // densidade do corpo: linhas de parágrafo (folhas de ≥ 3 linhas) na altura-x do corpo
        let bodyDensities = leaves.filter { $0.lines.count >= 3 }.flatMap(\.lines)
            .filter { ref > 0 && abs($0.xHeight / ref - 1) <= 0.1 }.map(\.density)
        let bodyDensity = bodyDensities.isEmpty ? nil : median(bodyDensities)

        var out: [Block] = []
        for leaf in leaves {
            for part in splitLeadingHeading(leaf, ref: ref) {
                let type = classify(part, ref: ref, bodyDensity: bodyDensity)
                let lines = type == .figure ? [] : part.lines.map {
                    Line(rect: pageRect($0.box), baseline: $0.baseline, xHeightPt: $0.xHeight, words: $0.words)
                }
                out.append(Block(rect: pageRect(part.box), type: type, lines: lines, column: part.column))
            }
        }
        return out
    }

    /// Linhas iniciais bem maiores que o resto (título colado ao parágrafo) viram bloco próprio.
    private func splitLeadingHeading(_ leaf: Leaf, ref: CGFloat) -> [Leaf] {
        guard ref > 0, leaf.lines.count >= 2 else { return [leaf] }
        let k = leaf.lines.prefix { $0.xHeight >= 1.15 * ref }.count
        guard k >= 1, k < leaf.lines.count,
              leaf.lines[k...].allSatisfy({ $0.xHeight <= 1.08 * ref }) else { return [leaf] }
        func sub(_ ls: ArraySlice<LeafLine>) -> Leaf {
            var l = leaf
            l.lines = Array(ls)
            l.box = ls.dropFirst().reduce(ls.first!.box) { $0.union($1.box) }
            l.tableLike = false
            return l
        }
        return [sub(leaf.lines[..<k]), sub(leaf.lines[k...])]
    }

    private func classify(_ leaf: Leaf, ref: CGFloat, bodyDensity: Double?) -> BlockType {
        let rect = pageRect(leaf.box)
        let area = max(1e-6, rect.width * rect.height)
        let textIds = Array(Set(leaf.lines.flatMap(\.texts))).sorted()

        // figura: dominada por imagem, sem texto extraível numa página com texto,
        // ou com faixa de tinta alta (gráfico) e pouca área de texto
        if !isScan {
            var imageArea: CGFloat = 0
            for im in images {
                let c = im.intersection(rect)
                if !c.isNull { imageArea += c.width * c.height }
            }
            if imageArea >= 0.5 * area { return .figure }
        }
        if !texts.isEmpty && textIds.isEmpty { return .figure }
        var textArea: CGFloat = 0
        for i in textIds {
            let c = texts[i].rect.intersection(rect)
            if !c.isNull { textArea += c.width * c.height }
        }
        let tallest = CGFloat(leaf.lines.map(\.box.height).max() ?? 0)
        if tallest >= 6 * xhPx && textArea < 0.3 * area { return .figure }

        // tabela: vãos verticais alinhados (≥ 3 segmentos) sem passar como calha
        if leaf.lines.count >= 2 && (leaf.tableLike || alignedSegments(leaf.box) >= 3) { return .table }

        let firstText = leaf.lines.first?.texts.first.map { texts[$0].text } ?? ""
        if firstText.range(of: #"^(Fig(ure|ura)?\.?|FIGURE|Tab(le|ela)?\.?|TABLE|Quadro)\s*[0-9IVX]"#,
                           options: .regularExpression) != nil { return .caption }

        let marker = #"^([•◦▪‣∙·*–—-]|\(?[0-9]{1,2}[.)]|\(?[a-z][.)]|\(?[ivx]{1,4}[.)])\s"#
        let lineTexts = leaf.lines.compactMap { $0.texts.first.map { texts[$0].text } }
        let markers = lineTexts.filter { $0.range(of: marker, options: .regularExpression) != nil }.count
        if markers >= 2 && Double(markers) >= 0.3 * Double(leaf.lines.count) { return .list }

        let xhs = leaf.lines.map(\.xHeight).filter { $0 > 0 }
        let mx = xhs.isEmpty ? 0 : CGFloat(median(xhs.map(Double.init)))
        let W = Double(leaf.container.width)
        if ref > 0 && mx >= 1.15 * ref && leaf.lines.count <= 3 { return .heading }
        // Linha isolada curta em negrito; sem fonte, negrito pela densidade de tinta:
        // Times Bold 10 pt mediu 1,22× o corpo a 2 px/pt; linha comum fica em ±10%.
        if leaf.lines.count == 1, let bd = bodyDensity, Double(leaf.box.width) <= 0.75 * W,
           leaf.lines[0].density >= 1.15 * bd { return .heading }

        if isEquation(leaf, textIds: textIds) { return .equation }

        if ref > 0 && mx > 0 && mx < 0.9 * ref && leaf.box.midY >= Double(root.y0) + 0.6 * Double(root.height) { return .note }
        return .paragraph
    }

    /// Linha(s) centrada(s) e isolada(s), com ou sem número encostado à direita.
    private func isEquation(_ leaf: Leaf, textIds: [Int]) -> Bool {
        guard !leaf.lines.isEmpty, leaf.lines.count <= 4 else { return false }
        // texto corrido centrado (autor, título) não é fórmula
        let text = textIds.map { texts[$0].text }.joined(separator: " ")
        let letters = text.filter { $0.isLetter }.count
        let nonSpace = text.filter { !$0.isWhitespace }.count
        if letters >= 8 && Double(letters) >= 0.85 * Double(nonSpace) { return false }
        let c = leaf.container
        let W = Double(c.width)
        guard W > 0 else { return false }
        var main: PixelBox?
        for l in leaf.lines {
            var x1 = l.box.x1
            // número à direita: depois de um vão ≥ 2,5 altura-x, estreito e encostado na margem
            let gaps = zeroRuns(colProfile(l.box))
            if let g = gaps.last(where: { CGFloat($0.1 - $0.0) >= 2.5 * xhPx }) {
                let rightW = Double(l.box.width - g.1)
                if rightW <= 0.15 * W && Double(c.x1 - l.box.x1) <= 0.03 * W { x1 = l.box.x0 + g.0 }
            }
            let m = PixelBox(x0: l.box.x0, y0: l.box.y0, x1: x1, y1: l.box.y1)
            main = main.map { $0.union(m) } ?? m
        }
        guard let m = main else { return false }
        return abs(m.midX - c.midX) <= 0.06 * W && Double(m.width) <= 0.8 * W && Double(m.x0 - c.x0) >= 0.08 * W
    }

    /// Segmentos de tinta separados por vãos verticais largos que atravessam o bloco todo.
    private func alignedSegments(_ b: PixelBox) -> Int {
        let minGap = Int((max(1.5 * xhPx, 4 * s)).rounded())
        return zeroRuns(colProfile(b)).filter { $0.1 - $0.0 >= minGap }.count + 1
    }

    // MARK: perfis

    private func tight(_ b: PixelBox) -> PixelBox? {
        mask.bounds(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1).map { PixelBox(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1) }
    }

    private func rowProfile(_ b: PixelBox) -> [Float] {
        guard b.width > 0, b.height > 0 else { return [] }
        var out = [Float](repeating: 0, count: b.height)
        let w = mask.width, n = vDSP_Length(b.width)
        mask.values.withUnsafeBufferPointer { p in
            for y in b.y0..<b.y1 {
                var v: Float = 0
                vDSP_sve(p.baseAddress! + y * w + b.x0, 1, &v, n)
                out[y - b.y0] = v
            }
        }
        return out
    }

    private func colProfile(_ b: PixelBox) -> [Float] {
        guard b.width > 0, b.height > 0 else { return [] }
        var out = [Float](repeating: 0, count: b.width)
        let w = mask.width, n = vDSP_Length(b.width)
        mask.values.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for y in b.y0..<b.y1 {
                    vDSP_vadd(p.baseAddress! + y * w + b.x0, 1, o.baseAddress!, 1, o.baseAddress!, 1, n)
                }
            }
        }
        return out
    }

    /// Faixas de linha [a, b): faixa baixa (pingo do i, acento, til) entra na
    /// vizinha mais próxima. `ProfileLines.bands` junta com a primeira que vier,
    /// e o pingo de uma linha sem ascendentes colava na linha de cima. Baixa e
    /// perto em termos absolutos (≤ 0,6 e ≤ 1 altura-x): sem isso, uma linha de
    /// texto "baixa" ao lado de uma figura alta entrava nela em cascata.
    private func lineBands(_ rows: [Float]) -> [(Int, Int)] {
        var r = runs(rows)
        let maxH = Double(0.6 * xhPx), maxGap = Double(xhPx)
        var changed = true
        while changed && r.count >= 2 {
            changed = false
            for i in r.indices {
                let h = r[i].1 - r[i].0
                guard Double(h) <= maxH else { continue }
                var best: (j: Int, gap: Int)?
                for j in [i - 1, i + 1] where j >= 0 && j < r.count {
                    let gap = j < i ? r[i].0 - r[j].1 : r[j].0 - r[i].1
                    let hn = r[j].1 - r[j].0
                    guard Double(h) < 0.35 * Double(hn), Double(gap) <= min(maxGap, 0.5 * Double(hn)) else { continue }
                    if best == nil || gap < best!.gap { best = (j, gap) }
                }
                guard let b = best else { continue }
                let lo = min(i, b.j)
                r[lo] = (min(r[i].0, r[b.j].0), max(r[i].1, r[b.j].1))
                r.remove(at: lo + 1)
                changed = true
                break
            }
        }
        return r
    }

    /// Faixas [a, b) com tinta.
    private func runs(_ p: [Float]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int?
        for (i, v) in p.enumerated() {
            if v > 0 { if start == nil { start = i } } else if let st = start { out.append((st, i)); start = nil }
        }
        if let st = start { out.append((st, p.count)) }
        return out
    }

    /// Vãos internos [a, b) sem tinta (perfil de nó apertado: bordas têm tinta).
    private func zeroRuns(_ p: [Float]) -> [(Int, Int)] {
        let r = runs(p)
        return zip(r, r.dropFirst()).map { ($0.1, $1.0) }
    }

    /// Pixels → página, com meio pixel de folga pelo antialiasing (como a caixa de tinta).
    private func pageRect(_ b: PixelBox) -> CGRect {
        map.pageRect(pixelX: b.x0, y: b.y0, toX: b.x1, toY: b.y1).insetBy(dx: -0.5 / s, dy: -0.5 / s)
    }

    private func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
