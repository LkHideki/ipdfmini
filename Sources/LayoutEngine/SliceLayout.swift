import CoreGraphics
import MiniGeometry
import PDFAnalysis

// Unidades → segmentos → fatias → páginas de saída. Comum a E3, E4 e E5.
// Respiro em espaço de saída: aqui a escala varia por segmento, e o que importa
// é a margem no vidro.

struct SliceGeometry: Sendable {
    var size: CGSize
    /// Respiro `r` em cada lado (saída).
    var margin: CGFloat
    /// Lado `R` do quadrado de canto (saída).
    var corner: CGFloat

    static let indicatorFontPt: CGFloat = 6
    static let indicatorHeightPt: CGFloat = 7
    static let indicatorInsetPt: CGFloat = 2

    init(_ profile: ViewportProfile, _ recipe: Recipe) {
        size = profile.sizePt
        margin = Units.mmToPt(CGFloat(max(0, recipe.marginMM)))
        corner = max(0, profile.cornerRadiusPt)
    }

    /// Faixa da base reservada ao indicador de página: fica fora da tinta sem procurar vaga.
    var band: CGFloat { Self.indicatorInsetPt + Self.indicatorHeightPt }
    /// Respiro entre colocações empilhadas; ≥ R − r para que a de baixo nunca suba ao canto.
    var gap: CGFloat { max(2 * margin, corner - margin) }
    var usableWidth: CGFloat { max(1, size.width - 2 * margin) }

    /// Segmento sem folga lateral ≥ R precisa da folga no topo e na base (cantos).
    func padTop(_ sidesFree: Bool) -> CGFloat { sidesFree ? margin : max(margin, corner) }
    func padBottom(_ sidesFree: Bool) -> CGFloat { max(padTop(sidesFree), band) }
    func capacity(_ sidesFree: Bool) -> CGFloat { max(1, size.height - padTop(sidesFree) - padBottom(sidesFree)) }
}

/// Sequência de unidades com uma escala e um mapeamento horizontal.
struct SliceSegment: Sendable {
    var units: [SliceUnit]
    var scale: CGFloat
    /// Escala travada; `scale` menor = tinta larga demais (exceção).
    var nominal: CGFloat
    var srcLeft: CGFloat
    var outLeft: CGFloat
    var sidesFree: Bool
    /// Fluxo principal (corpo): entra no aviso de legibilidade e na exceção de escala.
    var isBody: Bool
    /// Só rodapé corrido no fim da página (E5, um segmento por bloco): leva junto o
    /// último fragmento quando não cabe embaixo dele, para não ficar sozinho numa tela.
    var trailingFurniture = false

    var isException: Bool { scale < nominal * (1 - 1e-9) }

    func outX(_ x: CGFloat) -> CGFloat { outLeft + (x - srcLeft) * scale }

    /// `anchor`: borda esquerda de referência e largura de referência (escala
    /// travada: a mesma x de origem cai na mesma x de saída em todas as páginas);
    /// sem âncora, centrado.
    init(units: [SliceUnit], nominal: CGFloat, anchor: (left: CGFloat, width: CGFloat)?, isBody: Bool,
         geometry g: SliceGeometry) {
        self.units = units
        self.nominal = nominal
        self.isBody = isBody
        let minX = units.map(\.rect.minX).min() ?? 0
        let maxX = units.map(\.rect.maxX).max() ?? 0
        let w = max(0, maxX - minX)
        var s = nominal
        if w > 0, w * s > g.usableWidth { s = g.usableWidth / w }
        scale = s
        srcLeft = minX
        let desired: CGFloat
        if let a = anchor, s == nominal {
            desired = (g.size.width - a.width * s) / 2 + (minX - a.left) * s
        } else {
            desired = (g.size.width - w * s) / 2
        }
        outLeft = min(max(desired, g.margin), max(g.margin, g.size.width - g.margin - w * s))
        let eps: CGFloat = 1e-6
        sidesFree = outLeft >= g.corner - eps && outLeft + w * s <= g.size.width - g.corner + eps
    }
}

/// O que cada colocação mostra, para a estimativa.
struct SliceRecord: Sendable {
    var scale: CGFloat
    var textLines: Int
    var hasAtomic: Bool
    var isBody: Bool
    var reduced: Bool
    /// Tem linha de texto do tamanho do corpo (`BodyText.band`), mesmo fora do fluxo
    /// principal: resumo de largura total reduzido no E5 também é corpo para o aviso.
    var bodySized: Bool = false
}

/// Texto do tamanho do corpo: altura-x da linha / altura-x do corpo dentro da faixa.
/// Títulos ficam acima, notas abaixo. O validador (inv. 2) usa a mesma faixa.
public enum BodyText {
    public static let band: ClosedRange<CGFloat> = 0.85...1.15

    /// Altura-x desconhecida (≤ 0) conta como corpo: melhor avisar demais.
    public static func isBodySized(_ lineXHeight: CGFloat, body: CGFloat?) -> Bool {
        guard let body, body > 0, lineXHeight > 0 else { return true }
        return band.contains(lineXHeight / body)
    }
}

struct SliceResult: Sendable {
    var pages: [OutputPage] = []
    var warnings: [PlanWarning] = []
    var records: [SliceRecord] = []
    var overlapPages = 0
    var reducedSections = 0
}

enum SliceLayoutEngine {
    /// Unidade alta demais reduzida abaixo desta fração da escala do segmento:
    /// bloco atômico passa a ser fatiado com sobreposição (último recurso).
    static let minReducedFraction: CGFloat = 0.5
    static let overlapFraction: CGFloat = 0.10

    /// `segments(page)` devolve os segmentos da página na ordem de leitura.
    static func layout(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ g: SliceGeometry,
                       segments: (Int) -> [SliceSegment]) -> SliceResult {
        var result = SliceResult()
        for (pos, page) in doc.pages.enumerated() {
            let segs = segments(pos).filter { !$0.units.isEmpty }
            var composer = PageComposer(page: page, geometry: g, bodyXHeight: EstimateMath.bodyXHeightPt(doc))
            for (k, seg) in segs.enumerated() { composer.add(seg, final: k == segs.count - 1) }
            composer.flush()
            var outs = composer.done
            if outs.isEmpty {
                // Página sem tinta: inteira, como no E0, para não sumir da sequência.
                result.warnings.append(.emptyPage(page: page.index))
                let w = CropMath.passthroughWindow(pageBox: page.pageBox, viewport: g.size, maxScale: .infinity)
                outs = [([Placement(sourcePage: page.index, sourceRect: w.window,
                                    transform: CropMath.transform(window: w.window, scale: w.scale),
                                    sourceGeometry: page.geometry)], [])]
            }
            for (k, out) in outs.enumerated() {
                let text = "p. \(page.index + 1) · \(k + 1)/\(outs.count)"
                result.pages.append(OutputPage(sizePt: g.size, placements: out.placements,
                                               overlays: out.overlays + [.pageIndicator(text: text, rect: indicatorRect(text, g))]))
            }
            result.warnings += composer.warnings
            result.records += composer.records
            result.overlapPages += composer.overlapPages
            result.reducedSections += composer.reducedSections
        }
        return result
    }

    /// Canto inferior direito, dentro da faixa reservada e fora do quadrado de canto.
    static func indicatorRect(_ text: String, _ g: SliceGeometry) -> CGRect {
        let w = CGFloat(text.count) * SliceGeometry.indicatorFontPt * 0.55
        return CGRect(x: g.size.width - max(g.corner, g.margin) - w, y: SliceGeometry.indicatorInsetPt,
                      width: w, height: SliceGeometry.indicatorHeightPt)
    }
}

/// Monta as páginas de saída de uma página de origem, empilhando fragmentos.
struct PageComposer {
    let page: PageAnalysis
    let g: SliceGeometry
    let bodyXHeight: CGFloat?
    var done: [(placements: [Placement], overlays: [Overlay])] = []
    var cur: [Placement] = []
    var curOverlays: [Overlay] = []
    /// Base (y de saída) do último fragmento da página corrente; `nil` = página vazia.
    var cursor: CGFloat?
    var lastEndsWithHeading = false
    var warnings: [PlanWarning] = []
    var records: [SliceRecord] = []
    var overlapPages = 0
    var reducedSections = 0

    init(page: PageAnalysis, geometry: SliceGeometry, bodyXHeight: CGFloat? = nil) {
        self.page = page
        g = geometry
        self.bodyXHeight = bodyXHeight
    }

    func isBodySized(_ u: SliceUnit) -> Bool {
        switch u.kind {
        case .atomic: return false
        case .section: return true
        case let .line(b, l, _, _):
            guard page.blocks.indices.contains(b), page.blocks[b].lines.indices.contains(l) else { return true }
            return BodyText.isBodySized(page.blocks[b].lines[l].xHeightPt, body: bodyXHeight)
        }
    }

    mutating func flush() {
        if !cur.isEmpty { done.append((cur, curOverlays)) }
        cur = []
        curOverlays = []
        cursor = nil
    }

    mutating func put(_ src: CGRect, scale s: CGFloat, outX: CGFloat, top: CGFloat, units: ArraySlice<SliceUnit>,
                      isBody: Bool, reduced: Bool = false) {
        let t = CGAffineTransform(translationX: -src.minX, y: -src.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: outX, y: top - src.height * s))
        cur.append(Placement(sourcePage: page.index, sourceRect: src, transform: t, sourceGeometry: page.geometry))
        cursor = top - src.height * s
        records.append(SliceRecord(scale: s, textLines: units.reduce(0) { $0 + $1.textLines },
                                   hasAtomic: units.contains { $0.isAtomic }, isBody: isBody, reduced: reduced,
                                   bodySized: units.contains(where: isBodySized)))
    }

    mutating func add(_ seg: SliceSegment, final: Bool) {
        if seg.isBody, seg.isException {
            warnings.append(.scaleException(page: page.index, classScale: seg.nominal, pageScale: seg.scale))
        }
        let cap = g.capacity(seg.sidesFree)
        if seg.trailingFurniture, let c = cursor, cur.count >= 2,
           SliceUnits.hull(seg.units[...]).height * seg.scale > c - g.gap - g.padBottom(seg.sidesFree) {
            carryLastToFreshPage()
        }
        let groups = SliceUnits.glueFurniture(SliceUnits.groups(seg.units), seg.units)
        var run: [Range<Int>] = []
        for gr in groups {
            let r = SliceUnits.hull(seg.units[gr])
            if r.height * seg.scale > cap * (1 + 1e-9) {
                place(run, seg, final: false)
                run = []
                oversize(gr, seg)
            } else {
                run.append(gr)
            }
        }
        place(run, seg, final: final)
    }

    /// Fecha a página corrente sem o último fragmento e o põe no topo de uma nova.
    /// Topo pelo respiro dos cantos: vale para qualquer folga lateral.
    mutating func carryLastToFreshPage() {
        let p = cur.removeLast()
        flush()
        let s = p.scale, t = p.transform
        let top = g.size.height - g.padTop(false)
        let bottom = top - p.sourceRect.height * s
        var moved = p
        moved.transform = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: bottom - p.sourceRect.minY * s)
        cur = [moved]
        cursor = bottom
    }

    /// Fatia uma sequência de grupos que cabem na tela, por DP.
    mutating func place(_ groups: [Range<Int>], _ seg: SliceSegment, final: Bool) {
        guard !groups.isEmpty else { return }
        let units = seg.units
        let rects = groups.map { SliceUnits.hull(units[$0]) }
        var penalty = [Double](repeating: 0, count: groups.count)
        for j in 1..<max(1, groups.count) {
            penalty[j] = SliceCosts.cut(after: units[groups[j - 1].upperBound - 1], before: units[groups[j].lowerBound])
        }
        let cap = g.capacity(seg.sidesFree)
        func solve(_ first: CGFloat?) -> (slices: [Range<Int>], cost: Double)? {
            SliceDP.solve(tops: rects.map(\.maxY), bottoms: rects.map(\.minY), scale: seg.scale, capacity: cap,
                          firstCapacity: first, cutPenalty: penalty, final: final)
        }
        var stacked: (slices: [Range<Int>], cost: Double)?
        if let c = cursor {
            let room = c - g.gap - g.padBottom(seg.sidesFree)
            if room > 0 { stacked = solve(room) }
        }
        // Todo grupo cabe na altura útil (os maiores foram separados antes).
        var fresh = solve(nil)!
        if cursor != nil, lastEndsWithHeading { fresh.cost += SliceCosts.headingAtEnd }
        let useStacked = stacked.map { $0.cost <= fresh.cost } ?? false
        let slices = useStacked ? stacked!.slices : fresh.slices
        for (k, sl) in slices.enumerated() {
            if k > 0 || !useStacked { flush() }
            let top = cursor.map { $0 - g.gap } ?? g.size.height - g.padTop(seg.sidesFree)
            let ur = groups[sl.lowerBound].lowerBound..<groups[sl.upperBound - 1].upperBound
            let src = SliceUnits.hull(units[ur])
            put(src, scale: seg.scale, outX: seg.outX(src.minX), top: top, units: units[ur], isBody: seg.isBody)
            lastEndsWithHeading = units[ur.upperBound - 1].isHeading
        }
    }

    /// Unidade mais alta que a tela: página própria reduzida; bloco atômico que
    /// encolheria demais é fatiado com sobreposição e marca de continuidade.
    mutating func oversize(_ gr: Range<Int>, _ seg: SliceSegment) {
        flush()
        let units = seg.units[gr]
        let src = SliceUnits.hull(units)
        let padT = max(g.margin, g.corner), padB = max(padT, g.band)
        let room = max(1, g.size.height - padT - padB)
        var s = min(seg.scale, room / src.height)
        if src.width > 0 { s = min(s, g.usableWidth / src.width) }
        if units.allSatisfy(\.isAtomic), s < SliceLayoutEngine.minReducedFraction * seg.scale {
            overlap(src, units, seg)
        } else {
            if units.contains(where: { if case .section = $0.kind { true } else { false } }) { reducedSections += 1 }
            put(src, scale: s, outX: (g.size.width - src.width * s) / 2, top: g.size.height - padT, units: units,
                isBody: seg.isBody, reduced: true)
            warnings.append(.scaleException(page: page.index, classScale: seg.scale, pageScale: s))
            flush()
        }
        lastEndsWithHeading = false
    }

    mutating func overlap(_ src: CGRect, _ units: ArraySlice<SliceUnit>, _ seg: SliceSegment) {
        let s = seg.scale
        let cap = g.capacity(seg.sidesFree)
        let h = cap / s
        let step = h * (1 - SliceLayoutEngine.overlapFraction)
        let top = g.size.height - g.padTop(seg.sidesFree)
        var sliceTop = src.maxY
        var k = 0
        while true {
            let bottom = max(src.minY, sliceTop - h)
            let r = CGRect(x: src.minX, y: bottom, width: src.width, height: sliceTop - bottom)
            put(r, scale: s, outX: seg.outX(src.minX), top: top, units: units, isBody: seg.isBody)
            // Onde a tela anterior terminou.
            if k > 0 { curOverlays.append(.continuityMark(y: top - (h - step) * s)) }
            overlapPages += 1
            flush()
            if bottom <= src.minY + 1e-9 { break }
            sliceTop -= step
            k += 1
        }
    }
}
