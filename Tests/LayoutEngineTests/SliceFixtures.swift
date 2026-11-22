import CoreGraphics
import Testing
import MiniGeometry
import PDFAnalysis
@testable import LayoutEngine

// Páginas com blocos e linhas fabricadas, para E3–E5.

/// Gerador determinístico (semente fixa) para os testes de propriedade.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Gen {
    static let letter = CGSize(width: 612, height: 792)
    /// Corpo de 10 pt: tinta da linha (ascendente a descendente) e entrelinha.
    static let lineInk: CGFloat = 7.2
    static let descent: CGFloat = 2.2
    static let leading: CGFloat = 12

    /// Bloco de texto com `n` linhas coladas à tinta, a partir do topo `top`.
    static func text(left: CGFloat, top: CGFloat, width: CGFloat, lines n: Int, type: BlockType = .paragraph,
                     column: Int? = nil, leading: CGFloat = leading, ink: CGFloat = lineInk) -> Block {
        let lines = (0..<n).map { k -> Line in
            let y = top - CGFloat(k) * leading - ink
            let w = k == n - 1 && n > 1 ? width * 0.6 : width
            return Line(rect: CGRect(x: left, y: y, width: w, height: ink), baseline: y + descent, xHeightPt: 4.7)
        }
        let hull = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
        return Block(rect: hull, type: type, lines: lines, column: column)
    }

    static func atomic(_ rect: CGRect, type: BlockType = .figure, column: Int? = nil) -> Block {
        Block(rect: rect, type: type, lines: [], column: column)
    }

    /// Altura que um bloco de `n` linhas ocupa.
    static func height(lines n: Int, leading: CGFloat = leading, ink: CGFloat = lineInk) -> CGFloat {
        CGFloat(n - 1) * leading + ink
    }

    static func page(_ index: Int, size: CGSize = Fx.a4, blocks: [Block], body: CGFloat = Fx.bodyX10) -> PageAnalysis {
        var p = Fx.page(index, size: size, ink: blocks.isEmpty ? nil : hull(blocks.map(\.rect)), body: body)
        p.blocks = blocks
        p.lines = blocks.flatMap(\.lines)
        return p
    }

    static func hull(_ rects: [CGRect]) -> CGRect { rects.dropFirst().reduce(rects[0]) { $0.union($1) } }

    /// Preenche uma coluna de cima para baixo com títulos, parágrafos e blocos atômicos.
    static func fill(_ rng: inout SplitMix64, left: CGFloat, width: CGFloat, top: CGFloat, bottom: CGFloat,
                     column: Int?) -> [Block] {
        var out: [Block] = []
        var y = top
        while y - bottom > lineInk {
            let roll = Int.random(in: 0..<100, using: &rng)
            if roll < 12 {
                let n = Int.random(in: 1...2, using: &rng)
                guard y - height(lines: n, leading: 16, ink: 10) >= bottom else { break }
                let b = text(left: left, top: y, width: width * 0.7, lines: n, type: .heading, column: column,
                             leading: 16, ink: 10)
                out.append(b)
                y = b.rect.minY - 6
            } else if roll < 27 {
                // Até 400 pt: a mais alta passa da tela do E3 (≈ 285 pt de origem), mas
                // nunca encolhe abaixo de metade (sobreposição fica fora deste gerador).
                let h = min(CGFloat.random(in: 20...400, using: &rng), y - bottom)
                guard h >= 20 else { break }
                let w = width * CGFloat.random(in: 0.5...1, using: &rng)
                let type: BlockType = [.figure, .table, .equation][Int.random(in: 0..<3, using: &rng)]
                out.append(atomic(CGRect(x: left + (width - w) / 2, y: y - h, width: w, height: h), type: type,
                                  column: column))
                y -= h + 8
            } else {
                let room = Int(((y - bottom - lineInk) / leading).rounded(.down)) + 1
                guard room >= 1 else { break }
                let n = min(Int.random(in: 1...14, using: &rng), room)
                let b = text(left: left, top: y, width: width, lines: n, column: column)
                out.append(b)
                y = b.rect.minY - 6
            }
        }
        return out
    }

    /// Página A4 aleatória: uma coluna, ou duas com título e figura de largura total.
    static func randomPage(_ index: Int, _ rng: inout SplitMix64) -> PageAnalysis {
        let left: CGFloat = 72, width: CGFloat = 451, top: CGFloat = 770, bottom: CGFloat = 72
        var blocks: [Block] = []
        if Bool.random(using: &rng) {
            blocks = fill(&rng, left: left, width: width, top: top, bottom: bottom, column: nil)
        } else {
            var y = top
            if Bool.random(using: &rng) {
                let t = text(left: left + 40, top: y, width: width - 80, lines: 2, type: .heading, leading: 16, ink: 10)
                blocks.append(t)
                y = t.rect.minY - 12
            }
            let gutter: CGFloat = 15, cw = (width - gutter) / 2
            // Uma ou duas seções de colunas, separadas por figura larga.
            let split = Bool.random(using: &rng)
            let mid = split ? y - (y - bottom) * 0.45 : bottom
            blocks += fill(&rng, left: left, width: cw, top: y, bottom: mid, column: 0)
            blocks += fill(&rng, left: left + cw + gutter, width: cw, top: y, bottom: mid, column: 1)
            if split {
                let fig = atomic(CGRect(x: left, y: mid - 120, width: width, height: 110))
                blocks.append(fig)
                let y2 = fig.rect.minY - 10
                blocks += fill(&rng, left: left, width: cw, top: y2, bottom: bottom, column: 0)
                blocks += fill(&rng, left: left + cw + gutter, width: cw, top: y2, bottom: bottom, column: 1)
            }
        }
        return page(index, blocks: blocks)
    }

    /// Artigo em 2 colunas: Letter, colunas de 252 pt e 665 pt de altura, corpo de 10 pt.
    static func twoColumnArticle(pages: Int = 4, title: Bool = false) -> DocumentAnalysis {
        let cw: CGFloat = 252, gutter: CGFloat = 14, left: CGFloat = 47
        let colTop: CGFloat = 727, colHeight: CGFloat = 665
        let doc = (0..<pages).map { i -> PageAnalysis in
            var blocks: [Block] = []
            var top = colTop
            if title && i == 0 {
                blocks.append(text(left: left + 60, top: 760, width: 2 * cw + gutter - 120, lines: 2, type: .heading,
                                   leading: 18, ink: 12))
                top = blocks[0].rect.minY - 14
            }
            let n = Int(((top - (colTop - colHeight) - lineInk) / leading).rounded(.down)) + 1
            // Entrelinha ajustada para a coluna medir exatamente o que sobra (665 pt sem título).
            let lead = (top - (colTop - colHeight) - lineInk) / CGFloat(n - 1)
            for (c, x) in [left, left + cw + gutter].enumerated() {
                var y = top, k = 0
                for len in [9, 12, 7, 11, 10, 8, 13, 6, 10] where k < n {
                    let m = min(len, n - k)
                    let b = text(left: x, top: y, width: cw, lines: m, column: c, leading: lead)
                    blocks.append(b)
                    y -= CGFloat(m) * lead
                    k += m
                }
            }
            return page(i, size: letter, blocks: blocks)
        }
        return Fx.doc(doc)
    }
}

/// Unidades indivisíveis de uma página, na ordem de leitura.
func inkUnits(_ page: PageAnalysis) -> [CGRect] {
    guard !page.blocks.isEmpty else { return page.lines.map(\.rect) }
    return page.blocks.flatMap { b in b.isAtomic || b.lines.isEmpty ? [b.rect] : b.lines.map(\.rect) }
}

func overlaps(_ a: CGRect, _ b: CGRect, eps: CGFloat = 1e-6) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > eps && i.height > eps
}

/// Invariantes de um plano fatiado. `allowOverlap`: aceita blocos
/// atômicos repetidos em fatias com marca de continuidade.
func checkSlicePlan(_ doc: DocumentAnalysis, _ plan: LayoutPlan, allowOverlap: Bool = false,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    let v = plan.profile.sizePt
    let R = plan.profile.cornerRadiusPt
    let pageRect = CGRect(origin: .zero, size: v)
    let corners = pageRect.cornerSquares(radius: R)
    var seq: [(page: Int, rect: CGRect, index: Int)] = []
    for out in plan.pages {
        #expect(abs((out.sizePt.height / out.sizePt.width) / plan.profile.aspect - 1) < 0.001, sourceLocation: sourceLocation)
        #expect(out.sizePt == v, sourceLocation: sourceLocation)
        if !allowOverlap {
            #expect(!out.overlays.contains { if case .continuityMark = $0 { true } else { false } },
                    "sobreposição inesperada", sourceLocation: sourceLocation)
        }
        var outRects: [CGRect] = []
        for p in out.placements {
            let t = p.transform
            #expect(abs(t.b) < 1e-12 && abs(t.c) < 1e-12 && abs(t.a - t.d) < 1e-12 && t.a > 0, sourceLocation: sourceLocation)
            #expect(p.sourceGeometry != nil, sourceLocation: sourceLocation)
            let o = p.sourceRect.applying(t)
            #expect(pageRect.containsApprox(o, eps: 1e-6), "colocação fora da página: \(o)", sourceLocation: sourceLocation)
            let hasInk = doc.pages[p.sourcePage].usableInk != nil
            // Página sem tinta vai inteira (como no E0): não há tinta para o canto nem para o indicador evitar.
            if hasInk {
                #expect(!corners.contains { overlaps($0, o) }, "conteúdo no canto: \(o)", sourceLocation: sourceLocation)
                outRects.append(o)
            }
            seq.append((p.sourcePage, p.sourceRect, seq.count))
        }
        let indicators = out.overlays.compactMap { if case .pageIndicator(let s, let r) = $0 { (s, r) } else { nil } }
        #expect(indicators.count == 1, sourceLocation: sourceLocation)
        if let (_, r) = indicators.first {
            #expect(pageRect.containsApprox(r), sourceLocation: sourceLocation)
            #expect(!corners.contains { overlaps($0, r) }, "indicador no canto", sourceLocation: sourceLocation)
            #expect(!outRects.contains { overlaps($0, r) }, "indicador sobre a tinta", sourceLocation: sourceLocation)
        }
    }
    for page in doc.pages {
        let mine = seq.filter { $0.page == page.index }
        var last = -1
        for u in inkUnits(page) {
            let inside = mine.filter { $0.rect.containsApprox(u) }
            let touching = mine.filter { overlaps($0.rect, u) }
            // Bloco fatiado com sobreposição (último recurso) aparece em pedaços.
            if allowOverlap && touching.count > 1 { continue }
            #expect(inside.count == 1, "unidade \(u) da página \(page.index) em \(inside.count) colocações",
                    sourceLocation: sourceLocation)
            #expect(touching.count == inside.count, "unidade \(u) cortada", sourceLocation: sourceLocation)
            guard let first = inside.first else { continue }
            #expect(first.index >= last, "ordem de leitura na página \(page.index)", sourceLocation: sourceLocation)
            last = first.index
        }
    }
}

extension LayoutPlan {
    /// Placements com índice da página de saída.
    var indexedPlacements: [(out: Int, placement: Placement)] {
        pages.enumerated().flatMap { i, o in o.placements.map { (i, $0) } }
    }
}
