import CoreGraphics
import MiniGeometry
import PDFAnalysis

// Escala travada por classe, encaixe e respiro.
// Tudo em espaço de página; a janela sempre tem a proporção exata do viewport.

enum CropMath {
    /// Escala de uma mancha `ink` no viewport com respiro `r` (espaço de origem)
    /// e quadrados de canto de lado `R` (espaço de saída) sem tinta.
    ///
    /// Cada canto fica livre se a folga lateral OU a de topo/base for ≥ R/s.
    /// Opção lateral: s·W + 2R ≤ Vw; opção vertical: s·H + 2R ≤ Vh. Fica a que
    /// rende maior escala; se nenhuma folga basta, o respiro daquela dimensão cresce.
    static func fit(ink: CGSize, viewport v: CGSize, margin r: CGFloat, corner R: CGFloat,
                    maxScale: CGFloat) -> (scale: CGFloat, cornersBySides: Bool) {
        func ratio(_ num: CGFloat, _ den: CGFloat) -> CGFloat { den > 0 ? num / den : .infinity }
        let w = max(ink.width, 0), h = max(ink.height, 0)
        let base = min(ratio(v.width, w + 2 * r), ratio(v.height, h + 2 * r))
        let sx = min(base, ratio(v.width - 2 * R, w))
        let sy = min(base, ratio(v.height - 2 * R, h))
        var s = max(sx, sy)
        // Viewport menor que dois raios: cantos impossíveis, fica o respiro simples.
        if !(s > 0) { s = base }
        s = min(s, maxScale)
        if !s.isFinite || !(s > 0) { s = maxScale.isFinite && maxScale > 0 ? maxScale : 1 }
        return (s, s <= sx * (1 + 1e-12))
    }

    /// Janela da passagem direta: caixa expandida (centrada) até a proporção do viewport.
    static func passthroughWindow(pageBox: CGRect, viewport v: CGSize, maxScale: CGFloat) -> (window: CGRect, scale: CGFloat) {
        var s = Fit.scale(content: pageBox.size, into: v)
        s = min(s, maxScale)
        if !(s > 0) || !s.isFinite { s = 1 }
        let size = CGSize(width: v.width / s, height: v.height / s)
        let origin = CGPoint(x: pageBox.midX - size.width / 2, y: pageBox.midY - size.height / 2)
        return (CGRect(origin: origin, size: size), s)
    }

    /// Translação até a origem da janela, depois escala uniforme.
    static func transform(window: CGRect, scale s: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -window.minX, y: -window.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
    }

    /// Posição numa dimensão: a desejada, limitada para não descobrir tinta
    /// (com folga `clear`) e, se der, para ficar dentro da caixa de página.
    static func axis(desired: CGFloat, length: CGFloat, ink: (min: CGFloat, max: CGFloat)?, clear: CGFloat,
                     page: (min: CGFloat, max: CGFloat)) -> CGFloat {
        var lo = -CGFloat.infinity, hi = CGFloat.infinity
        if let ink {
            lo = ink.max + clear - length
            hi = ink.min - clear
            if lo > hi { return (ink.min + ink.max - length) / 2 }
        }
        let pLo = page.min, pHi = page.max - length
        if pLo <= pHi, max(lo, pLo) <= min(hi, pHi) {
            lo = max(lo, pLo)
            hi = min(hi, pHi)
        }
        return min(max(desired, lo), hi)
    }
}

/// Moldura de recorte: escala, tamanho de janela e alinhamento de uma classe
/// (ou de uma página exceção).
struct CropFrame: Sendable {
    var scale: CGFloat
    var size: CGSize
    var cornersBySides: Bool
    /// Mancha de referência: borda esquerda e topo (maxY) medianos, tamanho no percentil.
    var anchorLeft: CGFloat
    var anchorTop: CGFloat
    var refInk: CGSize
    var gapLeft: CGFloat
    var gapTop: CGFloat
    /// Lado do quadrado de canto em espaço de origem.
    var cornerClear: CGFloat

    init(refInk: CGSize, anchorLeft: CGFloat, anchorTop: CGFloat, viewport v: CGSize,
         margin r: CGFloat, corner R: CGFloat, maxScale: CGFloat) {
        let f = CropMath.fit(ink: refInk, viewport: v, margin: r, corner: R, maxScale: maxScale)
        scale = f.scale
        cornersBySides = f.cornersBySides
        size = CGSize(width: v.width / f.scale, height: v.height / f.scale)
        self.anchorLeft = anchorLeft
        self.anchorTop = anchorTop
        self.refInk = refInk
        cornerClear = R / f.scale
        // Folga lateral repartida: mancha limitada pela altura não fica encostada à esquerda.
        gapLeft = (size.width - refInk.width) / 2
        // topo; se os cantos dependem do topo/base, o respiro do topo sobe até R/s.
        gapTop = f.cornersBySides ? r : max(r, R / f.scale)
    }

    /// Folgas mínimas (x, y) com que `ink` cabe na janela com cantos livres; `nil` se não cabe.
    func clearances(for ink: CGSize, minMargin m: CGFloat) -> (x: CGFloat, y: CGFloat)? {
        let eps = 1e-9 * max(size.width, size.height)
        let c = max(m, cornerClear)
        let sides = ink.width + 2 * c <= size.width + eps && ink.height + 2 * m <= size.height + eps
        let topBottom = ink.width + 2 * m <= size.width + eps && ink.height + 2 * c <= size.height + eps
        switch (sides, topBottom) {
        case (true, true): return cornersBySides ? (c, m) : (m, c)
        case (true, false): return (c, m)
        case (false, true): return (m, c)
        case (false, false): return nil
        }
    }

    /// Janela deslocada na vertical o mínimo possível para que nenhum bloco
    /// removido (E2) fique parcialmente dentro: inteiro fora ou, se a largura
    /// permitir com os cantos livres, inteiro dentro. `nil` se nenhuma posição
    /// mantém a tinta com o respiro mínimo. Cabeçalho cortado ao meio é pior que mantê-lo.
    func avoiding(_ blocks: [CGRect], window w: CGRect, ink: CGRect, minMargin m: CGFloat) -> CGRect? {
        let eps: CGFloat = 1e-6
        let H = w.height
        func partial(_ y: CGFloat) -> Bool {
            let win = CGRect(x: w.minX, y: y, width: w.width, height: H)
            return blocks.contains { b in
                let i = win.intersection(b)
                return !i.isNull && i.width > eps && i.height > eps && !win.insetBy(dx: -eps, dy: -eps).contains(b)
            }
        }
        guard partial(w.minY) else { return w }
        let cy = clearances(for: ink.size, minMargin: m)?.y ?? 0
        var feasible = Intervals([(ink.maxY + cy - H, ink.minY - cy)])
        if feasible.isEmpty { return nil }
        for b in blocks where b.maxX > w.minX + eps && b.minX < w.maxX - eps {
            var allowed = [(-CGFloat.infinity, b.minY - H), (b.maxY, CGFloat.infinity)]
            if b.minX >= w.minX + cornerClear && b.maxX <= w.maxX - cornerClear { allowed.append((b.maxY - H, b.minY)) }
            feasible = feasible.intersecting(Intervals(allowed))
            if feasible.isEmpty { return nil }
        }
        guard let y = feasible.closest(to: w.minY), !partial(y) else { return nil }
        return CGRect(x: w.minX, y: y, width: w.width, height: H)
    }

    /// Janela da página; `nil` quando a tinta (com respiro mínimo e cantos) não cabe.
    /// Horizontal: corrige pela tinta só quando ela sai da faixa de referência
    /// além de `threshold` (scan torto); abaixo disso fica a margem mediana.
    func window(for ink: CGRect?, pageBox: CGRect, minMargin m: CGFloat, threshold: CGFloat,
                forced: Bool = false) -> CGRect? {
        var clear: (x: CGFloat, y: CGFloat) = (0, 0)
        var dx: CGFloat = 0
        if let ink {
            if let c = clearances(for: ink.size, minMargin: m) {
                clear = c
            } else if !forced {
                return nil
            }
            // Gatilho pelo que sai da faixa (título centrado não conta); correção pela margem esquerda.
            let overflow = max(0, ink.maxX - (anchorLeft + refInk.width)) - max(0, anchorLeft - ink.minX)
            if abs(overflow) > threshold { dx = ink.minX - anchorLeft }
        }
        let x = CropMath.axis(desired: anchorLeft - gapLeft + dx, length: size.width,
                              ink: ink.map { ($0.minX, $0.maxX) }, clear: clear.x,
                              page: (pageBox.minX, pageBox.maxX))
        let y = CropMath.axis(desired: anchorTop + gapTop - size.height, length: size.height,
                              ink: ink.map { ($0.minY, $0.maxY) }, clear: clear.y,
                              page: (pageBox.minY, pageBox.maxY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// União de intervalos fechados [a, b] na reta.
struct Intervals {
    var parts: [(CGFloat, CGFloat)]

    init(_ parts: [(CGFloat, CGFloat)]) { self.parts = parts.filter { $0.0 <= $0.1 } }

    var isEmpty: Bool { parts.isEmpty }

    func intersecting(_ o: Intervals) -> Intervals {
        var out: [(CGFloat, CGFloat)] = []
        for a in parts { for b in o.parts { out.append((max(a.0, b.0), min(a.1, b.1))) } }
        return Intervals(out)
    }

    func closest(to x: CGFloat) -> CGFloat? {
        parts.map { min(max(x, $0.0), $0.1) }.min { abs($0 - x) < abs($1 - x) }
    }
}

enum WindowKind: Sendable, Equatable { case regular, exception, empty }

struct PageWindow: Sendable {
    var position: Int
    var window: CGRect
    var scale: CGFloat
    var kind: WindowKind
    var classIndex: Int
}

struct CropLayout: Sendable {
    /// `nil` para classe só com páginas vazias.
    var frames: [CropFrame?]
    var classes: [[Int]]
    var windows: [PageWindow]

    /// Escala da classe com mais páginas com tinta.
    var dominantScale: CGFloat? {
        var best: (count: Int, scale: CGFloat)?
        for (i, f) in frames.enumerated() {
            guard let f else { continue }
            let n = inkCounts[i]
            if best == nil || n > best!.count { best = (n, f.scale) }
        }
        return best?.scale
    }

    var inkCounts: [Int] = []
    var exceptionCount: Int { windows.count { $0.kind == .exception } }
}

enum CropLayoutEngine {
    /// Respiro mínimo. Tinta além da mancha de referência pode consumir o
    /// respiro até aqui antes de virar exceção, para não multiplicar escalas por 1 pt.
    static let minimumMarginMM: CGFloat = 1
    /// Desvio horizontal além da faixa de referência que pede correção por página.
    static let realignThresholdMM: CGFloat = 3

    /// `removeHeaderFooter` = E2: classes, escala e janelas pela tinta do corpo
    /// (`bodyInkBox ?? inkBox`), e os blocos removidos nunca parcialmente dentro.
    static func compute(_ doc: DocumentAnalysis, _ profile: ViewportProfile, _ recipe: Recipe,
                        removeHeaderFooter: Bool = false) -> CropLayout {
        let v = profile.sizePt
        let r = Units.mmToPt(CGFloat(max(0, recipe.marginMM)))
        let m = min(r, Units.mmToPt(minimumMarginMM))
        let R = max(0, profile.cornerRadiusPt)
        let threshold = Units.mmToPt(realignThresholdMM)
        let classes = PageClassifier.classes(doc, mode: recipe.classMode)
        func ink(_ p: PageAnalysis) -> CGRect? { removeHeaderFooter ? (p.usableBodyInk ?? p.usableInk) : p.usableInk }

        var frames: [CropFrame?] = []
        var counts: [Int] = []
        var windows: [PageWindow] = []
        windows.reserveCapacity(doc.pages.count)

        for (ci, members) in classes.enumerated() {
            let inks = members.compactMap { ink(doc.pages[$0]) }
            counts.append(inks.count)
            let frame: CropFrame? = inks.isEmpty ? nil : CropFrame(
                refInk: CGSize(width: Stats.lowerPercentile(inks.map(\.width), recipe.referencePercentile),
                               height: Stats.lowerPercentile(inks.map(\.height), recipe.referencePercentile)),
                anchorLeft: Stats.median(inks.map(\.minX)),
                anchorTop: Stats.median(inks.map(\.maxY)),
                viewport: v, margin: r, corner: R, maxScale: recipe.maxScale)
            frames.append(frame)

            for pos in members {
                let page = doc.pages[pos]
                let box = page.pageBox
                guard let frame else {
                    let p = CropMath.passthroughWindow(pageBox: box, viewport: v, maxScale: recipe.maxScale)
                    windows.append(PageWindow(position: pos, window: p.window, scale: p.scale, kind: .empty, classIndex: ci))
                    continue
                }
                guard let pageInk = ink(page) else {
                    let w = frame.window(for: nil, pageBox: box, minMargin: m, threshold: threshold)!
                    windows.append(PageWindow(position: pos, window: w, scale: frame.scale, kind: .empty, classIndex: ci))
                    continue
                }
                let removed = removeHeaderFooter && page.usableBodyInk != nil ? page.removedHeaderFooter : []
                // Ordem: janela da classe; com bloco removido impossível de deixar inteiro
                // fora, a da classe com a tinta completa (o bloco entra inteiro); só então
                // escala própria, primeiro sem os blocos, depois com tudo.
                func classWindow(_ ink: CGRect, _ blocks: [CGRect]) -> PageWindow? {
                    guard let w = frame.window(for: ink, pageBox: box, minMargin: m, threshold: threshold),
                          let a = frame.avoiding(blocks, window: w, ink: ink, minMargin: m) else { return nil }
                    return PageWindow(position: pos, window: a, scale: frame.scale, kind: .regular, classIndex: ci)
                }
                func ownWindow(_ ink: CGRect, _ blocks: [CGRect]) -> PageWindow? {
                    let own = CropFrame(refInk: ink.size, anchorLeft: ink.minX, anchorTop: ink.maxY,
                                        viewport: v, margin: r, corner: R, maxScale: recipe.maxScale)
                    let w = own.window(for: ink, pageBox: box, minMargin: m, threshold: threshold)
                        ?? own.window(for: ink, pageBox: box, minMargin: 0, threshold: threshold, forced: true)!
                    guard let a = own.avoiding(blocks, window: w, ink: ink, minMargin: m) else { return nil }
                    return PageWindow(position: pos, window: a, scale: own.scale, kind: .exception, classIndex: ci)
                }
                let full = page.usableInk ?? pageInk
                let placed = classWindow(pageInk, removed)
                    ?? (removed.isEmpty ? nil : classWindow(full, []))
                    ?? ownWindow(pageInk, removed)
                    ?? ownWindow(full, [])!
                windows.append(placed)
            }
        }
        windows.sort { $0.position < $1.position }
        var layout = CropLayout(frames: frames, classes: classes, windows: windows)
        layout.inkCounts = counts
        return layout
    }
}
