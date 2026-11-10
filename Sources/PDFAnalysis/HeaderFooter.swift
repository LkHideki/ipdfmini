import CoreGraphics
import Foundation

/// Cabeçalho/rodapé repetido e número de página. PLAN.md §5.4.
/// Só reclassifica blocos da segmentação como `.headerFooter`; a caixa de
/// tinta continua com eles (remover é a estratégia E2).
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
        // Linha corrida com fólio numa ponta ("10 | Chapter 1: Introduction", "Preface | xxix",
        // padrão O'Reilly): o título muda a cada capítulo, então a repetição do texto não a
        // pega; o que se repete é o formato e a posição.
        let folios = cands.filter { isOutermost($0, in: pages[$0.page]) && isFolioLine(pages[$0.page].lineTexts[$0.line]) }
        for c in folios {
            let pagesAtSpot = Set(folios.filter { $0.top == c.top && abs($0.distance - c.distance) <= positionTolerance }.map(\.page))
            if pagesAtSpot.count >= min(2, n) { marked.insert([c.page, c.line]) }
        }
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
            let rects = lines.indices.filter { marked.contains([pi, $0]) }.map { lines[$0].rect }
            guard !rects.isEmpty else { continue }
            pages[pi].analysis.blocks = mark(rects, in: pages[pi].analysis.blocks)
        }
    }

    /// Reclassifica como `.headerFooter` as linhas (coladas à tinta) dos blocos
    /// que casam com as linhas tipográficas marcadas. Bloco inteiro muda de tipo;
    /// linhas no começo ou no fim de um bloco maior viram bloco próprio, pela
    /// união das linhas: segue disjunto e cobrindo a mesma tinta. Linha no meio
    /// do bloco fica (na dúvida, não remove).
    static func mark(_ marked: [CGRect], in blocks: [Block]) -> [Block] {
        func hits(_ l: CGRect, _ m: CGRect) -> Bool {
            let v = min(l.maxY, m.maxY) - max(l.minY, m.minY)
            let h = min(l.maxX, m.maxX) - max(l.minX, m.minX)
            return h > 0 && v >= 0.5 * min(l.height, m.height)
        }
        var out: [Block] = []
        for b in blocks {
            guard b.type != .headerFooter else { out.append(b); continue }
            guard !b.lines.isEmpty else {
                // bloco atômico sem linhas: só muda de tipo se cabe na linha marcada
                if marked.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(b.rect) }) {
                    out.append(Block(rect: b.rect, type: .headerFooter, lines: [], column: nil))
                } else { out.append(b) }
                continue
            }
            let flags = b.lines.map { l in marked.contains { hits(l.rect, $0) } }
            guard flags.contains(true) else { out.append(b); continue }
            if !flags.contains(false) {
                // Bloco muito mais alto que as linhas marcadas (página de índice cujo bloco
                // da página inteira tem uma "linha" só, que cruza o fólio): não é rodapé.
                // Pela altura somada (não pela união): um "M" de índice no topo, que passa por
                // número romano, e o fólio no pé não fazem do bloco inteiro um rodapé.
                let hits = marked.filter { m in b.lines.contains { hits($0.rect, m) } }
                let slack = max(4, hits.map(\.height).max() ?? 0)
                if b.rect.height <= hits.reduce(0) { $0 + $1.height } + 2 * slack {
                    out.append(Block(rect: b.rect, type: .headerFooter, lines: b.lines, column: nil))
                } else {
                    out.append(b)
                }
                continue
            }
            let head = flags.prefix { $0 }.count, tail = flags.reversed().prefix { $0 }.count
            guard head > 0 || tail > 0 else { out.append(b); continue }
            func sub(_ r: Range<Int>, _ type: BlockType, _ column: Int?) -> Block {
                let ls = Array(b.lines[r])
                let rect = ls.dropFirst().reduce(ls[0].rect) { $0.union($1.rect) }
                return Block(rect: rect, type: type, lines: ls, column: column)
            }
            let n = b.lines.count
            if head > 0 { out.append(sub(0..<head, .headerFooter, nil)) }
            out.append(sub(head..<(n - tail), b.type, b.column))
            if tail > 0 { out.append(sub((n - tail)..<n, .headerFooter, nil)) }
        }
        // ordem de leitura: cabeçalho acima de tudo primeiro, rodapé abaixo de tudo por último
        // (o XY-cut pode tê-los posto numa coluna quando não atravessam a calha)
        let body = out.filter { $0.type != .headerFooter }
        guard let top = body.map(\.rect.maxY).max(), let bottom = body.map(\.rect.minY).min() else { return out }
        let heads = out.filter { $0.type == .headerFooter && $0.rect.minY >= top }
        let feet = out.filter { $0.type == .headerFooter && $0.rect.maxY <= bottom && $0.rect.minY < top }
        let middle = out.filter { b in !heads.contains(b) && !feet.contains(b) }
        return heads + middle + feet
    }

    /// Fólio (arábico ou romano) separado do título por barra ou ponto, no início ou no fim.
    static func isFolioLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count <= 120 else { return false }
        let folio = #"(\d{1,4}|[ivxlcdm]{1,7})"#, sep = #"\s*[|│•·]\s*"#
        return t.range(of: "^(?i)\(folio)\(sep)\\S", options: .regularExpression) != nil
            || t.range(of: "(?i)\\S\(sep)\(folio)$", options: .regularExpression) != nil
    }

    /// Nenhuma outra linha da página mais perto da borda: a primeira (topo) ou a última (base).
    static func isOutermost(_ c: Candidate, in p: PageWork) -> Bool {
        let lines = p.analysis.lines
        let r = lines[c.line].rect
        return !lines.indices.contains { i in
            i != c.line && (c.top ? lines[i].rect.midY > r.maxY : lines[i].rect.midY < r.minY)
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
