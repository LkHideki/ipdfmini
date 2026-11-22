import CoreGraphics
import Foundation
import Testing
import MiniGeometry
@testable import SyntheticCorpus

/// Forma específica de cada cenário: o que a verdade de referência precisa garantir.
@Suite struct ScenarioShapeTests {
    private func pages(_ s: Scenario) -> [PageTruth] { Fixtures.doc(s).truth.pages }

    @Test(arguments: Scenario.allCases)
    func lineAndColumnTruthLiesInsideInkBox(_ s: Scenario) {
        for (i, t) in pages(s).enumerated() {
            let tag = "\(s) página \(i + 1)"
            guard let ink = t.inkBox else {
                #expect(t.lines.isEmpty && t.columns.isEmpty && t.headerFooter.isEmpty, "\(tag)")
                continue
            }
            let loose = ink.insetBy(dx: -0.001, dy: -0.001)
            for r in t.lines + t.columns + t.headerFooter { #expect(loose.contains(r), "\(tag): \(r)") }
            // Cabeçalho/rodapé também é linha.
            for r in t.headerFooter { #expect(t.lines.contains(r), "\(tag)") }
            #expect(!t.ignorableInk.contains { $0 == ink }, "\(tag)")
        }
    }

    @Test func book6x9() {
        let ps = pages(.book6x9)
        #expect(ps.count >= 10)
        let blank = ps.indices.filter { ps[$0].inkBox == nil }
        #expect(blank == [3], "uma única página em branco")
        let short: Set<Int> = [2, 7, 11]  // última de cada capítulo
        let chapterStarts: Set<Int> = [0, 4, 8]
        var lefts: [Bool: [CGFloat]] = [:]
        for (i, t) in ps.enumerated() where t.inkBox != nil {
            let col = t.columns[0]
            if short.contains(i) {
                #expect(col.height < 0.5 * 518, "página \(i + 1) deveria ser curta: \(col.height)")
            } else {
                #expect(abs(col.width - 324) < 2.5, "largura da mancha p\(i + 1): \(col.width)")
                // Página de abertura de capítulo: o título ocupa linhas inteiras e a última linha
                // do corpo sobe até uma entrelinha (12,1 pt) acima do pé da mancha.
                let slack: CGFloat = chapterStarts.contains(i) ? 14 : 6
                #expect(col.height <= 518 + 6 && col.height > 518 - slack, "altura da mancha p\(i + 1): \(col.height)")
            }
            lefts[(i + 1) % 2 == 1, default: []].append(col.minX)
        }
        // Lombada: recto (ímpar) começa 12 pt mais à direita que verso (par).
        let recto = lefts[true]!.min()!, verso = lefts[false]!.max()!
        #expect(recto - verso > 8, "recto \(recto) × verso \(verso)")
        // Cabeçalho (mesma altura e mesma largura de texto) e folio em toda página com tinta.
        let headers = ps.filter { $0.inkBox != nil }.map { $0.headerFooter }
        #expect(headers.allSatisfy { $0.count == 2 })
        let widths = Set(headers.map { ($0[0].width * 100).rounded() })
        let ys = Set(headers.map { ($0[0].minY * 100).rounded() })
        #expect(widths.count == 1 && ys.count == 1, "cabeçalho idêntico em todas as páginas")
        #expect(ps.allSatisfy { $0.geometry.pageBox.size == CGSize(width: 432, height: 648) })
    }

    @Test func a4ReportHasOneInchMargins() {
        for (i, t) in pages(.a4Report).enumerated() {
            let col = t.columns[0]
            #expect(t.geometry.pageBox.size == CGSize(width: 595, height: 842))
            #expect(abs(col.minX - 72) < 2.5, "p\(i + 1) esquerda \(col.minX)")
            #expect(abs(col.maxX - (72 + 451)) < 2.5, "p\(i + 1) direita \(col.maxX)")
            #expect(abs(col.maxY - (842 - 72)) < 2.5, "p\(i + 1) topo \(col.maxY)")
            #expect(col.minY >= 72 - 0.01)
        }
        #expect(Fixtures.doc(.a4Report).truth.bodyXHeightPt > 5)  // Helvetica
    }

    @Test func latexArticleHasTextblock345x598() {
        let ps = pages(.latexArticleA4)
        for i in 1..<3 {
            let col = ps[i].columns[0]
            #expect(abs(col.width - 345) < 2.5, "largura \(col.width)")
            #expect(abs(col.height - 598) < 6, "altura \(col.height)")
        }
        // Página 1: título, resumo recuado (coluna própria) e corpo.
        #expect(ps[0].columns.count == 2)
        #expect(ps[0].columns[0].width < 345 - 40)
    }

    @Test func twoColumnArticleHasGutter() {
        let ps = pages(.twoColumnArticle)
        #expect(ps.allSatisfy { $0.geometry.pageBox.size == CGSize(width: 612, height: 792) })
        for (i, t) in ps.enumerated() {
            #expect(t.columns.count == 2, "p\(i + 1)")
            let (a, b) = (t.columns[0], t.columns[1])
            #expect(b.minX - a.maxX >= 12, "calha p\(i + 1): \(b.minX - a.maxX)")
            #expect(!a.intersects(b))
            #expect(abs(a.width - 245) < 2.5 && abs(b.width - 245) < 2.5 || i == 2)
        }
        // Página 1: linhas em largura total (título e resumo) acima das colunas.
        let p1 = ps[0]
        let top = p1.columns.map(\.maxY).max()!
        let wide = p1.lines.filter { $0.width > 400 && $0.minY > top }
        #expect(wide.count >= 4)
    }

    @Test func rotatedPagesCoverAllQuarterTurns() {
        let ps = pages(.rotatedPages)
        #expect(ps.map(\.geometry.rotation) == [0, 90, 180, 270])
        for t in ps {
            let g = t.geometry
            #expect(g.displaySize == (g.isQuarterTurn ? CGSize(width: 600, height: 400) : CGSize(width: 400, height: 600)))
            // Em espaço do usuário a tinta respeita as margens assimétricas de origem.
            let user = g.toUser(t.inkBox!)
            #expect(user.minX > 59 && user.maxX < 371 && user.maxY < 561 && user.minY > 49, "\(user)")
        }
    }

    @Test func offsetBoxesHaveNonZeroOriginAndSmallerCrop() {
        for t in pages(.offsetBoxes) {
            #expect(t.mediaBox.origin != .zero)
            let crop = t.cropBox!
            #expect(crop.width < t.mediaBox.width && crop.height < t.mediaBox.height)
            #expect(t.mediaBox.contains(crop))
            #expect(t.geometry.effectiveBox == crop)
            #expect(t.geometry.pageBox.origin == crop.origin, "a origem da caixa efetiva se mantém na rotação")
        }
        #expect(pages(.offsetBoxes).map(\.geometry.rotation) == [0, 0, 90, 270])
    }

    @Test func cropMarksSitOutsideTrimBox() {
        for (i, t) in pages(.cropMarks).enumerated() {
            let trim = t.trimBox!
            #expect(trim.width < t.mediaBox.width && trim.height < t.mediaBox.height)
            #expect(t.geometry.effectiveBox == trim)
            #expect(t.ignorableInk.count == 14, "8 marcas de corte + 2 alvos de 3 traços")
            for r in t.ignorableInk { #expect(!r.intersects(trim), "p\(i + 1): \(r) toca a TrimBox") }
            #expect(trim.contains(t.inkBox!))
        }
    }

    @Test func arxivStampOnlyOnFirstPageInLeftMargin() {
        let ps = pages(.arxivStamp)
        #expect(ps[0].ignorableInk.count == 1)
        let stamp = ps[0].ignorableInk[0]
        #expect(stamp.maxX < 72 && stamp.height > 300 && stamp.width < 30, "\(stamp)")
        #expect(ps[1].ignorableInk.isEmpty)
        #expect(ps[0].inkBox!.minX > 70)
    }

    @Test func scannedPagesAreRasterOnly() {
        let doc = Fixtures.doc(.scannedPage)
        #expect(doc.truth.pages.allSatisfy { $0.isScan && $0.inkBox != nil })
        #expect(doc.truth.words.isEmpty)
        #expect(doc.data.range(of: Data("/Subtype /Image".utf8)) != nil || doc.data.range(of: Data("/Subtype/Image".utf8)) != nil)
        #expect(doc.data.count > 500_000)
        #expect(!Scenario.allCases.filter { $0 != .scannedPage }.contains { Fixtures.doc($0).truth.pages.contains(where: \.isScan) })
    }

    @Test func mixedSizesHasLandscapePlateInTheMiddle() {
        let sizes = pages(.mixedSizes).map(\.geometry.pageBox.size)
        #expect(sizes.count == 7)
        #expect(sizes[3] == CGSize(width: 648, height: 432))
        #expect(sizes.enumerated().allSatisfy { $0.offset == 3 || $0.element == CGSize(width: 432, height: 648) })
    }

    @Test func wordsAreDeterministicPseudoText() {
        let words = Fixtures.doc(.book6x9).truth.words
        #expect(words.count > 2000)
        #expect(Set(words).count > 500, "vocabulário variado")
        #expect(words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII } })
    }
}
