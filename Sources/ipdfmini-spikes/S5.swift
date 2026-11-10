import Foundation
import CoreGraphics
import MiniGeometry
import QPDFKit

/// S5 — gerador para medir no iPad o tempo de render de páginas com muitas colocações
/// com clip (PLAN.md §17 M0, risco R2: granularidade do reflow vetorial).
///
/// Para N ∈ {2, 10, 50, 300}, um PDF de 10 páginas no tamanho de tela cheia do mini em
/// retrato. Cada página de saída mostra uma página A4 de texto inteira, montada por N
/// colocações (grade sobre a página de origem) do mesmo Form XObject, cada uma com o
/// próprio clip: o leitor redesenha a página toda N vezes, como no reflow por blocos.
/// Mesmo caminho do `PlacementWriter` (qpdf), sem o resto do pipeline.
enum S5 {
    static let counts = [2, 10, 50, 300]
    static let pages = 10

    /// Grade linhas × colunas com N células, mais alta que larga (fatias de linhas).
    static func grid(_ n: Int) -> (rows: Int, cols: Int) {
        switch n {
        case 2: (2, 1)
        case 10: (5, 2)
        case 50: (10, 5)
        default: (n / 10, 10)
        }
    }

    static func execute(dir path: String) throws {
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("s5-origem-a4-texto.pdf")
        try Gen.makeTextDocument(at: src, pages: pages)
        let size = MiniPage.fullPortrait
        for n in counts {
            let out = dir.appendingPathComponent(String(format: "s5-colocacoes-%03d.pdf", n))
            let doc = try QPDFDocument(contentsOf: src)
            let (rows, cols) = grid(n)
            for p in 0..<pages {
                let info = try doc.sourcePageInfo(at: p)
                let box = info.cropBox
                let s = min(Double(size.width) / box.width, Double(size.height) / box.height)
                let dx = (Double(size.width) - box.width * s) / 2 - box.llx * s
                let dy = (Double(size.height) - box.height * s) / 2 - box.lly * s
                let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: Double(size.width), ury: Double(size.height)))
                let cw = box.width / Double(cols), ch = box.height / Double(rows)
                for r in 0..<rows {
                    for c in 0..<cols {
                        let x0 = box.llx + Double(c) * cw, y0 = box.lly + Double(r) * ch
                        try doc.place(sourcePage: p, onto: page, clip: QPDFRect(llx: x0, lly: y0, urx: x0 + cw, ury: y0 + ch),
                                      matrix: QPDFMatrix(a: s, b: 0, c: 0, d: s, e: dx, f: dy))
                    }
                }
            }
            try doc.removeSourcePages()
            try doc.write(to: out)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print("\(out.lastPathComponent): \(pages) páginas × \(n) colocações (\(rows)×\(cols)), \(bytes) bytes")
        }
        print("Abrir cada arquivo no iPad mini e medir o tempo de render por página (§16: ≤ 150 ms).")
    }
}
