import CoreGraphics

/// Altura-x medida na tinta.
enum XHeight {
    /// Posições contínuas (em linhas de pixel, a partir do topo do perfil) da
    /// linha média e da linha de base.
    ///
    /// Bordas pelo maior salto do perfil (entrada da faixa x por cima, saída
    /// pela base); posição subpixel pela fração de cobertura das linhas de
    /// transição, porque a 2 px/pt um pixel de erro já passa de 10%.
    static func measure(_ p: [Float]) -> (xLine: Double, baseline: Double)? {
        let n = p.count
        guard n >= 4, let peak = p.max(), peak > 0 else { return nil }
        func at(_ i: Int) -> Float { i >= 0 && i < n ? p[i] : 0 }
        // fronteira i = entre as linhas i-1 e i; janela de 2 linhas por causa do antialiasing
        var bi = -1
        var best: Float = 0
        for i in 1...n {
            let drop = at(i - 2) + at(i - 1) - at(i) - at(i + 1)
            if drop > best { best = drop; bi = i }
        }
        guard bi > 1 else { return nil }
        var xi = -1
        best = 0
        for j in 0...(bi - 2) {
            let rise = at(j) + at(j + 1) - at(j - 1) - at(j - 2)
            if rise > best { best = rise; xi = j }
        }
        guard xi >= 0, bi - xi >= 2 else { return nil }
        let inner = bi - xi > 2 ? Array(p[(xi + 1)..<(bi - 1)]) : Array(p[xi..<bi])
        let level = median(inner)
        let above = xi - 2 >= 0 ? median((max(0, xi - 4)...(xi - 2)).map(at)) : 0
        let below = bi + 1 < n ? median(((bi + 1)...min(n - 1, bi + 3)).map(at)) : 0
        guard level - above > 0.2 * level, level - below > 0.2 * level else { return nil }
        // Borda subpixel pela fração de cobertura das linhas de transição,
        // tendo como "cheia" a linha vizinha mais densa de dentro da faixa: o
        // traço horizontal no topo/base da faixa x é bem mais denso que a
        // mediana, e usá-la como referência empurraria a borda para fora.
        let halfTop = (above + level) / 2, halfBottom = (below + level) / 2
        func frac(_ v: Float, _ outside: Float, _ full: Float) -> Double {
            full > outside ? Double(min(1, max(0, (v - outside) / (full - outside)))) : 0
        }
        var xLine = Double(xi)
        for r in (xi - 1)...(xi + 2) where at(r) >= halfTop {
            let full = max(at(r), at(r + 1))
            xLine = Double(r + 1) - frac(at(r), above, full) - frac(at(r - 1), above, full)
            break
        }
        var base = Double(bi)
        for r in stride(from: bi, through: bi - 3, by: -1) where at(r) >= halfBottom {
            let full = max(at(r), at(r - 1))
            base = Double(r) + frac(at(r), below, full) + frac(at(r + 1), below, full)
            break
        }
        guard base - xLine >= 2 else { return nil }
        return (xLine, base)
    }

    static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

struct XHeightSample: Sendable, Equatable {
    var xHeight: CGFloat
    /// Comprimento da linha (pt): linhas longas pesam mais que títulos e rótulos.
    var weight: CGFloat
}

/// Histograma ponderado de altura-x → moda do corpo e menor moda relevante.
enum XHeightStats {
    static let bin: CGFloat = 0.1

    static func modes(_ samples: [XHeightSample]) -> (body: CGFloat, smallest: CGFloat)? {
        let valid = samples.filter { $0.xHeight >= 0.8 && $0.xHeight <= 120 && $0.weight > 0 }
        guard !valid.isEmpty else { return nil }
        let maxBin = Int((valid.map(\.xHeight).max()! / bin).rounded()) + 3
        var hist = [CGFloat](repeating: 0, count: maxBin + 1)
        for s in valid { hist[Int((s.xHeight / bin).rounded())] += s.weight }
        // suavização triangular de ±2 bins: ruído de medida ~0,2 pt
        let kernel: [CGFloat] = [1, 2, 3, 2, 1]
        var smooth = [CGFloat](repeating: 0, count: hist.count)
        for i in hist.indices {
            var acc: CGFloat = 0
            for (k, w) in kernel.enumerated() {
                let j = i + k - 2
                if j >= 0 && j < hist.count { acc += hist[j] * w }
            }
            smooth[i] = acc
        }
        guard let top = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
        let total = valid.reduce(0) { $0 + $1.weight }
        let body = refine(valid, around: CGFloat(top) * bin)
        // picos locais com peso relevante abaixo do corpo
        var smallest = body
        for i in 1..<(smooth.count - 1) where smooth[i] > 0 && smooth[i] >= smooth[i - 1] && smooth[i] > smooth[i + 1] {
            let center = CGFloat(i) * bin
            guard center < body - 3 * bin, smooth[i] >= 0.05 * smooth[top] else { continue }
            let mass = valid.filter { abs($0.xHeight - center) <= 3 * bin }.reduce(0) { $0 + $1.weight }
            guard mass >= 0.05 * total else { continue }
            smallest = min(smallest, refine(valid, around: center))
        }
        return (body, smallest)
    }

    private static func refine(_ s: [XHeightSample], around c: CGFloat) -> CGFloat {
        let near = s.filter { abs($0.xHeight - c) <= 3 * bin }
        let w = near.reduce(0) { $0 + $1.weight }
        guard w > 0 else { return c }
        return near.reduce(0) { $0 + $1.xHeight * $1.weight } / w
    }
}

/// Linhas pelo perfil horizontal da máscara, quando não há texto extraível.
enum ProfileLines {
    /// Faixas de linhas de pixel [y0, y1) com tinta, já juntando pingos e acentos.
    static func bands(rows: [Float], from y0: Int, to y1: Int, k: Float) -> [(Int, Int)] {
        var runs: [(Int, Int)] = []
        var start: Int?
        for y in y0..<y1 {
            if rows[y] >= k { if start == nil { start = y } } else if let s = start { runs.append((s, y)); start = nil }
        }
        if let s = start { runs.append((s, y1)) }
        // faixa muito baixa colada na seguinte (pingo do i, acento) entra nela
        var merged: [(Int, Int)] = []
        var i = 0
        while i < runs.count {
            var cur = runs[i]
            while i + 1 < runs.count {
                let next = runs[i + 1]
                let hc = cur.1 - cur.0, hn = next.1 - next.0, gap = next.0 - cur.1
                let small = min(hc, hn), large = max(hc, hn)
                guard Double(small) < 0.35 * Double(large), Double(gap) <= 0.5 * Double(large) else { break }
                cur = (cur.0, next.1)
                i += 1
            }
            merged.append(cur)
            i += 1
        }
        return merged
    }
}
