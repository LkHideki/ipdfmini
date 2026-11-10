import CoreGraphics
import MiniGeometry
import PDFAnalysis

// Fatiamento por programação dinâmica. PLAN.md §7 (E3–E5).
// Corta só nos vãos entre unidades; nunca dentro de linha ou bloco atômico.

/// Unidade cortável, em espaço de página.
struct SliceUnit: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Linha `line` de `count` do bloco `block` (índice em `page.blocks`; -1 sem blocos).
        case line(block: Int, line: Int, count: Int, heading: Bool)
        /// Bloco atômico inteiro, ou faixa de tinta sem linha (análise sem blocos).
        case atomic
        /// Seção de várias colunas inteira (E3/E4): fatiar a página de lado a lado
        /// mostraria pedaços das duas colunas na mesma tela e quebraria a ordem de leitura.
        case section(lines: Int)
    }

    var rect: CGRect
    var kind: Kind
    /// De bloco `.headerFooter` (cabeçalho, rodapé, fólio): nunca fica sozinho numa fatia.
    var furniture = false

    var textLines: Int {
        switch kind {
        case .line: 1
        case .atomic: 0
        case .section(let n): n
        }
    }

    var isAtomic: Bool { if case .atomic = kind { true } else { false } }
    var isHeading: Bool { if case .line(_, _, _, true) = kind { true } else { false } }
}

enum SliceUnits {
    static let eps: CGFloat = 1e-6

    /// Unidades de um bloco. Bloco de texto cujas linhas não cobrem o retângulo
    /// (contrato violado) vira atômico: melhor não cortar do que perder tinta.
    static func units(of block: Block, index: Int) -> [SliceUnit] {
        let furniture = block.type == .headerFooter
        if block.isAtomic || block.lines.isEmpty { return [SliceUnit(rect: block.rect, kind: .atomic, furniture: furniture)] }
        let hull = block.lines.dropFirst().reduce(block.lines[0].rect) { $0.union($1.rect) }
        guard hull.insetBy(dx: -eps, dy: -eps).contains(block.rect) else {
            return [SliceUnit(rect: block.rect.union(hull), kind: .atomic, furniture: furniture)]
        }
        let heading = block.type == .heading
        return block.lines.enumerated().map { k, l in
            SliceUnit(rect: l.rect, kind: .line(block: index, line: k, count: block.lines.count, heading: heading),
                      furniture: furniture)
        }
    }

    /// Análise sem blocos: cada linha vira faixa da largura da tinta (o que estiver
    /// ao lado dela entra junto) e cada faixa da tinta sem linha vira atômica.
    static func fallback(_ page: PageAnalysis) -> [SliceUnit] {
        guard let ink = page.usableInk else { return [] }
        let lines = page.lines.map(\.rect).filter { $0.intersects(ink) }.sorted { $0.maxY > $1.maxY }
        var out: [SliceUnit] = []
        var y = ink.maxY
        for l in lines {
            let band = CGRect(x: ink.minX, y: max(l.minY, ink.minY), width: ink.width,
                              height: min(l.maxY, ink.maxY) - max(l.minY, ink.minY))
            guard band.height > 0 else { continue }
            if band.maxY < y - eps {
                out.append(SliceUnit(rect: CGRect(x: ink.minX, y: band.maxY, width: ink.width, height: y - band.maxY),
                                     kind: .atomic))
            }
            out.append(SliceUnit(rect: band, kind: .line(block: -1, line: 0, count: 0, heading: false)))
            y = min(y, band.minY)
        }
        if y > ink.minY + eps {
            out.append(SliceUnit(rect: CGRect(x: ink.minX, y: ink.minY, width: ink.width, height: y - ink.minY),
                                 kind: .atomic))
        }
        return out
    }

    /// Unidades de E3/E4: seções de várias colunas inteiras; sem blocos, `fallback`.
    static func flow(_ page: PageAnalysis) -> [SliceUnit] {
        guard !page.blocks.isEmpty else { return fallback(page) }
        var out: [SliceUnit] = []
        let blocks = page.blocks
        var i = 0
        while i < blocks.count {
            guard blocks[i].column != nil else {
                out += units(of: blocks[i], index: i)
                i += 1
                continue
            }
            var j = i
            while j < blocks.count, blocks[j].column != nil { j += 1 }
            let run = blocks[i..<j]
            if Set(run.compactMap(\.column)).count >= 2 {
                let rect = run.dropFirst().reduce(run.first!.rect) { $0.union($1.rect) }
                let lines = run.reduce(0) { $0 + ($1.isAtomic ? 0 : $1.lines.count) }
                out.append(SliceUnit(rect: rect, kind: .section(lines: lines)))
            } else {
                for k in i..<j { out += units(of: blocks[k], index: k) }
            }
            i = j
        }
        return out
    }

    static func hull(_ units: ArraySlice<SliceUnit>) -> CGRect {
        units.dropFirst().reduce(units.first!.rect) { $0.union($1.rect) }
    }

    /// Grupos de unidades consecutivas entre os quais há candidato de corte: só se
    /// corta entre k e k+1 quando tudo antes está acima de tudo depois (vão ou
    /// encosto). Unidades que se sobrepõem na vertical ficam no mesmo grupo.
    static func groups(_ units: [SliceUnit]) -> [Range<Int>] {
        let n = units.count
        guard n > 0 else { return [] }
        var suffixTop = [CGFloat](repeating: -.infinity, count: n + 1)
        for k in stride(from: n - 1, through: 0, by: -1) { suffixTop[k] = max(suffixTop[k + 1], units[k].rect.maxY) }
        var out: [Range<Int>] = []
        var start = 0
        var prefixBottom = CGFloat.infinity
        for k in 0..<n {
            prefixBottom = min(prefixBottom, units[k].rect.minY)
            if k == n - 1 || prefixBottom >= suffixTop[k + 1] - eps {
                out.append(start..<(k + 1))
                start = k + 1
            }
        }
        return out
    }
}

extension SliceUnits {
    /// Cabeçalho/rodapé corrido nunca abre nem fecha uma fatia sozinho: o grupo inicial
    /// só de cabeçalho cola no seguinte e o final só de rodapé no anterior. Sem isto o DP
    /// mandava o rodapé para uma tela própria sempre que o corpo enchia as anteriores
    /// (INC-22). União mais alta que a tela segue o caminho de unidade alta (reduzida):
    /// encolher um pouco o vizinho custa menos que uma tela só com o fólio.
    static func glueFurniture(_ groups: [Range<Int>], _ units: [SliceUnit]) -> [Range<Int>] {
        var g = groups
        func onlyFurniture(_ r: Range<Int>) -> Bool { units[r].allSatisfy(\.furniture) }
        if g.count >= 2, onlyFurniture(g[0]), !onlyFurniture(g[1]) {
            g.replaceSubrange(0...1, with: [g[0].lowerBound..<g[1].upperBound])
        }
        if g.count >= 2, onlyFurniture(g[g.count - 1]), !onlyFurniture(g[g.count - 2]) {
            g.replaceSubrange((g.count - 2)..., with: [g[g.count - 2].lowerBound..<g[g.count - 1].upperBound])
        }
        return g
    }
}

/// Custos do DP. Página domina: penalidades só escolhem entre cortes com o
/// mesmo número de telas, salvo quando somam mais que uma tela inteira.
enum SliceCosts {
    static let page: Double = 1000
    /// 1ª linha de parágrafo sozinha no fim da fatia.
    static let orphan: Double = 150
    /// Última linha de parágrafo sozinha no início da fatia seguinte.
    static let widow: Double = 150
    static let headingAtEnd: Double = 300
    /// Última fatia com menos de `nearlyEmptyFraction` da altura útil.
    static let nearlyEmptyLast: Double = 100
    static let nearlyEmptyFraction: Double = 0.15
    /// Peso da folga ao quadrado nas fatias não finais: desempata a favor de fatias cheias.
    static let slack: Double = 10

    static func cut(after a: SliceUnit, before b: SliceUnit) -> Double {
        guard case .line(let ba, let la, let ca, let ha) = a.kind else { return 0 }
        if ha { return headingAtEnd }
        guard ba >= 0, case .line(let bb, _, _, _) = b.kind, ba == bb else { return 0 }
        let before = la + 1, after = ca - before
        return (before == 1 ? orphan : 0) + (after == 1 ? widow : 0)
    }
}

enum SliceDP {
    /// Melhor divisão dos grupos (topos/bases em espaço de página) em fatias de
    /// altura de saída ≤ `capacity`. `firstCapacity`: espaço que sobra na página
    /// corrente; a 1ª fatia vai para lá sem pagar página. `final`: nada se empilha
    /// depois (última fatia quase vazia é desperdício). `nil` se algo não cabe.
    static func solve(tops: [CGFloat], bottoms: [CGFloat], scale s: CGFloat, capacity: CGFloat,
                      firstCapacity: CGFloat?, cutPenalty: [Double], final: Bool) -> (slices: [Range<Int>], cost: Double)? {
        let n = tops.count
        guard n > 0 else { return ([], 0) }
        var best = [Double](repeating: .infinity, count: n + 1)
        var prev = [Int](repeating: -1, count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i].isFinite {
            let first = i == 0 && firstCapacity != nil
            let cap = first ? firstCapacity! : capacity
            let eps = 1e-9 * max(1, capacity)
            let pageCost = first ? 0 : SliceCosts.page
            var top = -CGFloat.infinity, bottom = CGFloat.infinity
            for j in (i + 1)...n {
                top = max(top, tops[j - 1])
                bottom = min(bottom, bottoms[j - 1])
                let h = (top - bottom) * s
                // Altura só cresce com j.
                if h > cap + eps { break }
                var c = best[i] + pageCost
                if j < n {
                    c += cutPenalty[j]
                    let slack = cap > 0 ? Double(max(0, cap - h) / cap) : 0
                    c += SliceCosts.slack * slack * slack
                } else if final, i > 0, Double(h) < SliceCosts.nearlyEmptyFraction * Double(cap) {
                    c += SliceCosts.nearlyEmptyLast
                }
                if c < best[j] {
                    best[j] = c
                    prev[j] = i
                }
            }
        }
        guard best[n].isFinite else { return nil }
        var slices: [Range<Int>] = []
        var j = n
        while j > 0 {
            let i = prev[j]
            slices.append(i..<j)
            j = i
        }
        return (slices.reversed(), best[n])
    }
}
