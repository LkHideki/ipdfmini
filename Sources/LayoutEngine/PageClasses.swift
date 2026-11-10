import CoreGraphics
import PDFAnalysis

// Classes de página para a escala travada. PLAN.md §6.1.1.

enum PageClassifier {
    /// Tolerância relativa para considerar dois tamanhos de página iguais
    /// (scans variam ~1%; 6×9 contra A4 ou retrato contra paisagem passam de 30%).
    static let sizeTolerance: CGFloat = 0.03
    /// Piso absoluto da tolerância, para páginas pequenas.
    static let sizeToleranceMinPt: CGFloat = 2

    /// Grupos de posições em `doc.pages`, na ordem da primeira aparição.
    /// `.oddEven` também separa por tamanho: uma prancha em paisagem num livro
    /// em retrato não pode virar referência das demais.
    static func classes(_ doc: DocumentAnalysis, mode: PageClassMode) -> [[Int]] {
        let groups = sizeGroups(doc.pages)
        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for pos in doc.pages.indices {
            let key: Int
            switch mode {
            case .all: key = 0
            case .bySize: key = groups[pos]
            // índice 0 = página 1 = ímpar
            case .oddEven: key = groups[pos] * 2 + (doc.pages[pos].index & 1)
            }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(pos)
        }
        return order.map { members[$0]! }
    }

    /// Id de grupo de tamanho (caixa em espaço de página) por posição.
    static func sizeGroups(_ pages: [PageAnalysis]) -> [Int] {
        var reps: [CGSize] = []
        return pages.map { p in
            let s = p.pageBox.size
            if let g = reps.firstIndex(where: { similar($0, s) }) { return g }
            reps.append(s)
            return reps.count - 1
        }
    }

    static func similar(_ a: CGSize, _ b: CGSize) -> Bool {
        func close(_ x: CGFloat, _ y: CGFloat) -> Bool {
            abs(x - y) <= max(sizeToleranceMinPt, sizeTolerance * max(abs(x), abs(y)))
        }
        return close(a.width, b.width) && close(a.height, b.height)
    }
}

enum Stats {
    /// Abaixo disto a classe não tem amostra para chamar uma página de outlier:
    /// vale o máximo. Com o posto inferior, numa classe de 2 páginas a menor
    /// mancha virava referência e a página cheia, exceção.
    static let minimumPercentileSample = 5

    /// Percentil pelo posto inferior (sem interpolação): com uma página larga
    /// entre 20, o p95 interpolado já encolheria as outras 19.
    static func lowerPercentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        if sorted.count < minimumPercentileSample { return sorted[sorted.count - 1] }
        let q = min(max(p, 0), 1)
        let i = Int((q * Double(sorted.count - 1)).rounded(.down))
        return sorted[i]
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        precondition(!values.isEmpty)
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

extension PageAnalysis {
    /// Caixa de tinta utilizável; `nil` para página vazia ou caixa degenerada.
    var usableInk: CGRect? {
        guard let r = inkBox?.standardized, !r.isNull, !r.isInfinite,
              r.width.isFinite, r.height.isFinite else { return nil }
        return r
    }

    /// Tinta do corpo (sem cabeçalho/rodapé) utilizável; `nil` se não houver.
    var usableBodyInk: CGRect? {
        guard let r = bodyInkBox?.standardized, !r.isNull, !r.isInfinite, !r.isEmpty,
              r.width.isFinite, r.height.isFinite else { return nil }
        return r
    }
}
