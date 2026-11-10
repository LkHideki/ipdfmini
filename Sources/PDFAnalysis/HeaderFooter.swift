import CoreGraphics
import Foundation

/// Cabeçalho/rodapé repetido e número de página. PLAN.md §5.4.
/// Só registra como `Block(type: .headerFooter)`; a caixa de tinta continua
/// com eles (remover é a estratégia E2).
enum HeaderFooter {
    /// Faixa externa (fração da altura) onde se procuram candidatos.
    static let band: CGFloat = 0.15
    static let minFraction = 0.6
    /// Tolerância de posição entre páginas.
    static let positionTolerance: CGFloat = 6

    struct Candidate {
        var page: Int
        var line: Int
        var top: Bool
        var key: String
        /// Distância à borda correspondente da caixa de página.
        var distance: CGFloat
    }

    static func detect(_ pages: inout [PageWork]) {
        var cands: [Candidate] = []
        for (pi, p) in pages.enumerated() {
            let box = p.analysis.pageBox
            let lines = p.analysis.lines
            for (li, l) in lines.enumerated() {
                let text = p.lineTexts[li]
                guard !text.isEmpty else { continue }
                if l.rect.minY >= box.maxY - band * box.height {
                    cands.append(Candidate(page: pi, line: li, top: true, key: normalize(text), distance: box.maxY - l.rect.maxY))
                } else if l.rect.maxY <= box.minY + band * box.height {
                    cands.append(Candidate(page: pi, line: li, top: false, key: normalize(text), distance: l.rect.minY - box.minY))
                }
            }
        }
        let n = pages.count
        var marked = Set<[Int]>()
        let groups = Dictionary(grouping: cands) { "\($0.top)|\($0.key)" }
        for c in cands {
            // páginas (distintas) com o mesmo texto na mesma faixa
            let group = groups["\(c.top)|\(c.key)"] ?? []
            let hits = Set(group.filter { abs($0.distance - c.distance) <= positionTolerance }.map(\.page))
            // classes ímpar/par: livros alternam cabeçalhos entre as páginas
            let parity = c.page % 2
            let classSize = n >= 4 ? (parity == 0 ? (n + 1) / 2 : n / 2) : n
            let classHits = n >= 4 ? hits.filter { $0 % 2 == parity }.count : hits.count
            let repeated = hits.count >= 2 && (Double(hits.count) >= minFraction * Double(n)
                                               || Double(classHits) >= minFraction * Double(classSize))
            if repeated || isPageNumber(c, in: pages[c.page]) { marked.insert([c.page, c.line]) }
        }
        for pi in pages.indices {
            let lines = pages[pi].analysis.lines
            let blocks = lines.indices.filter { marked.contains([pi, $0]) }
                .map { Block(rect: lines[$0].rect, type: .headerFooter, lines: [lines[$0]]) }
            pages[pi].analysis.blocks.append(contentsOf: blocks)
        }
    }

    /// Texto módulo dígitos: "Página 12" e "Página 13" viram a mesma chave.
    static func normalize(_ s: String) -> String {
        let digitless = s.lowercased().map { $0.isNumber ? "#" : $0 }
        return String(digitless).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Linha curta numérica isolada: a primeira ou a última da página.
    static func isPageNumber(_ c: Candidate, in p: PageWork) -> Bool {
        let t = p.lineTexts[c.line].trimmingCharacters(in: .whitespaces)
        guard t.count <= 12, t.range(of: #"^(?i)(p(age|ágina|\.)?\s*)?[-–—\s]*(\d{1,4}|[ivxlcdm]{1,7})[-–—\s]*$"#,
                                      options: .regularExpression) != nil else { return false }
        return c.top ? c.line == 0 : c.line == p.analysis.lines.count - 1
    }
}
