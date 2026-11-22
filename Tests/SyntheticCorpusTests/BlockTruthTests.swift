import CoreGraphics
import Foundation
import PDFKit
import Testing
import MiniGeometry
@testable import SyntheticCorpus

/// Cenários do M3: verdade de blocos, colunas e ordem de leitura.
let blockScenarios: [Scenario] = [.arxivTwoColumn, .reportWithFigures, .tallFigure]

/// Limiar de "pixel de tinta" no raster a 2 px/pt, o mesmo de `rasterInkBox`.
private let darkThreshold: UInt8 = 200
/// Tolerância espacial raster × verdade, em pt: o antialiasing espalha a borda de glifo e de
/// traço por ≤ 1 px (0,5 pt) e a grade de 2 px/pt quantiza outro 0,5 pt; o mesmo ±1 pt de
/// `inkTruthMatchesRaster`.
private let rasterTol: CGFloat = 1.0

private func blocks(_ s: Scenario) -> [[BlockTruth]] { Fixtures.doc(s).truth.pages.map(\.blocks) }

private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

/// Pixels escuros de uma página como retângulos de pixel (em espaço de página) por linha varrida.
private func darkPixels(_ data: Data, page index: Int) throws -> (rects: [CGRect], mapping: RasterMapping) {
    let cg = try #require(cgDocument(data))
    let p = try #require(cg.page(at: index + 1))
    let (pixels, mapping) = rasterPixels(of: p)
    var out: [CGRect] = []
    for y in 0..<mapping.height {
        for x in 0..<mapping.width where pixels[y * mapping.width + x] < darkThreshold {
            out.append(mapping.pageRect(pixelX: x, y: y, toX: x + 1, toY: y + 1))
        }
    }
    return (out, mapping)
}

@Suite struct BlockTruthTests {
    @Test(arguments: blockScenarios)
    func blocksAreDisjoint(_ s: Scenario) {
        for (i, bs) in blocks(s).enumerated() {
            #expect(!bs.isEmpty, "\(s) p\(i + 1): sem blocos")
            for a in bs.indices {
                for b in bs.indices where b > a {
                    let inter = bs[a].rect.intersection(bs[b].rect)
                    #expect(area(inter) < 1e-6, "\(s) p\(i + 1): \(bs[a].type)#\(a) × \(bs[b].type)#\(b): \(inter)")
                }
            }
        }
    }

    @Test(arguments: blockScenarios)
    func blocksUnionIsInkBox(_ s: Scenario) throws {
        for (i, t) in Fixtures.doc(s).truth.pages.enumerated() {
            let u = try #require(union(t.blocks.map(\.rect)))
            let ink = try #require(t.inkBox)
            #expect(close(u, ink, tol: 1.0), "\(s) p\(i + 1): blocos \(u) × inkBox \(ink)")
            #expect(t.ignorableInk.isEmpty)
        }
    }

    /// Todo pixel escuro do raster cai dentro de algum bloco (± `rasterTol`).
    @Test(arguments: blockScenarios)
    func blocksCoverRasterInk(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        for (i, t) in doc.truth.pages.enumerated() {
            let (rects, _) = try darkPixels(doc.data, page: i)
            #expect(!rects.isEmpty)
            let grown = t.blocks.map { $0.rect.insetBy(dx: -rasterTol, dy: -rasterTol) }
            var outside = 0
            var first: CGRect?
            for r in rects where !grown.contains(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) }) {
                outside += 1
                first = first ?? r
            }
            #expect(outside == 0, "\(s) p\(i + 1): \(outside) pixels escuros fora de qualquer bloco, ex. \(String(describing: first))")
        }
    }

    /// Blocos colados à tinta: a caixa dos pixels escuros dentro de cada bloco bate com o retângulo.
    @Test(arguments: blockScenarios)
    func blocksAreTightToRasterInk(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        for (i, t) in doc.truth.pages.enumerated() {
            let (rects, _) = try darkPixels(doc.data, page: i)
            for (k, b) in t.blocks.enumerated() {
                let zone = b.rect.insetBy(dx: -rasterTol, dy: -rasterTol)
                let inside = rects.filter { zone.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                guard let box = union(inside) else {
                    Issue.record("\(s) p\(i + 1) bloco \(k) \(b.type): sem tinta no raster")
                    continue
                }
                #expect(close(box, b.rect, tol: rasterTol), "\(s) p\(i + 1) bloco \(k) \(b.type): raster \(box) × verdade \(b.rect)")
            }
        }
    }

    @Test(arguments: blockScenarios)
    func linesAreInsideTheirBlocks(_ s: Scenario) {
        let textTypes: Set<String> = ["paragraph", "heading", "caption", "note", "list", "headerFooter"]
        for (i, t) in Fixtures.doc(s).truth.pages.enumerated() {
            for (k, b) in t.blocks.enumerated() {
                let tag = "\(s) p\(i + 1) bloco \(k) \(b.type)"
                let loose = b.rect.insetBy(dx: -0.001, dy: -0.001)
                for l in b.lines { #expect(loose.contains(l), "\(tag): linha \(l) fora de \(b.rect)") }
                if textTypes.contains(b.type) {
                    #expect(!b.lines.isEmpty, "\(tag): bloco de texto sem linhas")
                    // De cima para baixo; mesma linha pode repetir a base só se houver empate.
                    #expect(zip(b.lines, b.lines.dropFirst()).allSatisfy { $0.midY > $1.midY }, "\(tag): linhas fora de ordem")
                    // Fora a nota (o fio acima do texto não é linha), a tinta do bloco é só de linhas.
                    if b.type != "note", let u = union(b.lines) {
                        #expect(close(u, b.rect, tol: 0.5), "\(tag): união das linhas \(u) × bloco \(b.rect)")
                    }
                } else {
                    #expect(b.lines.isEmpty, "\(tag): bloco atômico não leva linhas")
                }
                // Toda linha de bloco está também em `PageTruth.lines` (só texto de corpo e cabeçalho/rodapé).
                for l in b.lines { #expect(t.lines.contains(l), "\(tag): \(l) ausente de PageTruth.lines") }
            }
        }
    }

    @Test(arguments: blockScenarios)
    func readingOrderIsPermutation(_ s: Scenario) {
        for (i, bs) in blocks(s).enumerated() {
            #expect(bs.map(\.readingOrder) == Array(0..<bs.count), "\(s) p\(i + 1)")
            #expect(Set(bs.map(\.readingOrder)) == Set(0..<bs.count))
        }
    }

    /// Ordem de referência: largura total de cima para baixo, intercalada nas posições
    /// certas; dentro de uma seção de colunas, esquerda inteira antes da direita, cada uma de cima
    /// para baixo. Espaço de página: y para cima.
    @Test(arguments: blockScenarios)
    func readingOrderFollowsReference(_ s: Scenario) {
        let eps: CGFloat = 0.001
        for (i, bs) in blocks(s).enumerated() {
            for (k, b) in bs.enumerated() where b.column == nil {
                for (j, o) in bs.enumerated() {
                    if j < k { #expect(o.rect.minY >= b.rect.maxY - eps, "\(s) p\(i + 1): #\(j) \(o.type) devia estar acima de #\(k) \(b.type)") }
                    if j > k { #expect(o.rect.maxY <= b.rect.minY + eps, "\(s) p\(i + 1): #\(j) \(o.type) devia estar abaixo de #\(k) \(b.type)") }
                }
            }
            // Corridas de blocos em coluna entre blocos de largura total.
            var run: [BlockTruth] = []
            func check() {
                for (a, b) in zip(run, run.dropFirst()) {
                    #expect(a.column! <= b.column!, "\(s) p\(i + 1): coluna \(b.column!) antes da \(a.column!)")
                    if a.column == b.column { #expect(b.rect.maxY <= a.rect.minY + eps, "\(s) p\(i + 1): dentro da coluna fora de ordem") }
                }
                run = []
            }
            for b in bs { if b.column == nil { check() } else { run.append(b) } }
            check()
        }
    }

    @Test func expectedTypesPerScenario() {
        func types(_ s: Scenario, page: Int? = nil) -> Set<String> {
            Set(blocks(s).enumerated().filter { page == nil || $0.offset == page }.flatMap { $0.element.map(\.type) })
        }
        let all: Set<String> = ["paragraph", "heading", "equation", "figure", "table", "caption", "note", "list", "headerFooter"]
        #expect(types(.arxivTwoColumn).isSuperset(of: all.subtracting(["list"])), "\(types(.arxivTwoColumn))")
        #expect(types(.reportWithFigures).isSuperset(of: ["paragraph", "heading", "figure", "table", "caption", "list", "headerFooter"]))
        #expect(types(.tallFigure).isSuperset(of: ["paragraph", "heading", "figure", "caption", "headerFooter"]))
        #expect(types(.arxivTwoColumn, page: 0).isSuperset(of: ["note", "figure", "caption", "heading", "paragraph"]))
        #expect(types(.arxivTwoColumn, page: 2).contains("table"))
        #expect(all.isSuperset(of: types(.arxivTwoColumn).union(types(.reportWithFigures)).union(types(.tallFigure))))
    }

    @Test func legacyScenariosHaveNoBlocks() {
        for s in Scenario.allCases where !blockScenarios.contains(s) {
            #expect(Fixtures.doc(s).truth.pages.allSatisfy { $0.blocks.isEmpty }, "\(s)")
        }
    }

    @Test func arxivTwoColumnShape() {
        let ps = Fixtures.doc(.arxivTwoColumn).truth.pages
        #expect(ps.count >= 4)
        #expect(ps.allSatisfy { $0.geometry.pageBox.size == CGSize(width: 612, height: 792) })
        for (i, t) in ps.enumerated() {
            let c0 = t.blocks.filter { $0.column == 0 }, c1 = t.blocks.filter { $0.column == 1 }
            #expect(!c0.isEmpty && !c1.isEmpty, "p\(i + 1)")
            // Calha de ~18 pt e colunas de ~252 pt.
            let gutter = c1.map(\.rect.minX).min()! - c0.map(\.rect.maxX).max()!
            #expect(abs(gutter - 18) < 2.5, "p\(i + 1) calha \(gutter)")
            #expect(c0.map(\.rect.width).max()! <= 252 + 1 && c0.map(\.rect.width).max()! > 245, "p\(i + 1) col 0")
            #expect(c1.map(\.rect.width).max()! <= 252 + 1 && c1.map(\.rect.width).max()! > 245, "p\(i + 1) col 1")
            #expect(t.columns.count >= 2)
        }
        let p1 = ps[0].blocks
        // Título, autores, "Abstract" e resumo em largura total acima das colunas.
        #expect(p1.prefix(4).allSatisfy { $0.column == nil })
        #expect(p1[0].type == "heading" && p1[1].type == "paragraph" && p1[3].type == "paragraph")
        #expect(p1[3].lines.count == 7)
        #expect(p1.contains { $0.type == "note" && $0.column == 0 })
        let note = p1.first { $0.type == "note" }!
        let body = p1.first { $0.type == "paragraph" && $0.column == 0 }!
        #expect(note.lines.count == 3)
        #expect(note.rect.minY < body.rect.minY, "nota no pé da coluna")
        #expect(p1.contains { $0.type == "figure" && $0.column == 1 }, "figura em coluna")
        // Página 2: figura de largura total no topo, com legenda.
        let p2 = ps[1].blocks
        #expect(p2[0].type == "figure" && p2[0].column == nil && p2[1].type == "caption" && p2[1].column == nil)
        #expect(p2[0].rect.width > 400)
        let eq = p2.first { $0.type == "equation" }!
        #expect(eq.column == 0 && eq.rect.width > 150, "equação centrada com número à direita: \(eq.rect)")
        // Página 3: tabela de largura total entre seções de colunas.
        let p3 = ps[2].blocks
        let ti = p3.firstIndex { $0.type == "table" }!
        #expect(p3[ti].column == nil && p3[ti - 1].type == "caption")
        #expect(p3[..<ti].contains { $0.column == 1 } && p3[(ti + 1)...].contains { $0.column == 0 })
        // Última página: colunas de alturas diferentes.
        let last = ps[ps.count - 1].blocks
        let h0 = union(last.filter { $0.column == 0 }.map(\.rect))!.height
        let h1 = union(last.filter { $0.column == 1 }.map(\.rect))!.height
        #expect(h0 - h1 > 100, "colunas \(h0) × \(h1)")
    }

    /// A tabela é o contraexemplo da calha: vãos verticais entre colunas de células e entre a
    /// borda e o texto, todos mais estreitos que 8 pt, e vários.
    @Test func tableGapsAreNarrowerThanAGutter() throws {
        let doc = Fixtures.doc(.arxivTwoColumn)
        let table = try #require(doc.truth.pages[2].blocks.first { $0.type == "table" })
        let (rects, mapping) = try darkPixels(doc.data, page: 2)
        let zone = table.rect.insetBy(dx: -rasterTol, dy: -rasterTol)
        let inside = rects.filter { zone.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let columns = Set(inside.map { Int(((($0.midX - mapping.pageBox.minX) * 2)).rounded(.down)) })
        let xs = columns.sorted()
        var runs: [CGFloat] = []
        for (a, b) in zip(xs, xs.dropFirst()) where b - a > 1 { runs.append(CGFloat(b - a - 1) / 2) }
        #expect(runs.count >= 5, "vãos: \(runs)")
        #expect(runs.max()! < 8, "vão ≥ 8 pt seria calha: \(runs)")
        #expect(runs.filter { $0 >= 4 }.count >= 5, "vãos entre colunas de células: \(runs)")
    }

    @Test func reportWithFiguresShape() {
        let ps = Fixtures.doc(.reportWithFigures).truth.pages
        #expect(ps.allSatisfy { $0.geometry.pageBox.size == CGSize(width: 595, height: 842) })
        // Coluna única: nenhum bloco tem coluna; mancha 451 × 698.
        #expect(ps.allSatisfy { $0.blocks.allSatisfy { $0.column == nil } })
        let widest = ps.flatMap(\.blocks).filter { $0.type == "paragraph" }.map(\.rect.width).max()!
        #expect(abs(widest - 451) < 2.5, "largura da mancha \(widest)")
        // Figura mais alta que a altura útil de uma tela em paisagem na escala de fatia
        // (largura da mancha nos 500,47 pt do lado maior; altura da tela 328,64 pt).
        let usable = 328.64 / (500.47 / 451)
        let fig = ps.flatMap(\.blocks).first { $0.type == "figure" }!
        #expect(fig.rect.height > usable, "figura \(fig.rect.height) × altura útil \(usable)")
        let list = ps.flatMap(\.blocks).first { $0.type == "list" }!
        #expect(list.lines.count == 9)
        #expect(ps.flatMap(\.blocks).filter { $0.type == "table" }.count == 1)
    }

    @Test func tallFigureDoesNotFitAnyReadableScale() {
        let ps = Fixtures.doc(.tallFigure).truth.pages
        let fig = ps.flatMap(\.blocks).first { $0.type == "figure" }!
        // Tela do mini em retrato: 500,47 pt. Corpo de 10 pt precisa de escala ≥ 0,9 para ficar em ≥ 9 pt.
        #expect(fig.rect.height * 0.9 > 500.47, "figura \(fig.rect.height)")
        #expect(ps[1].blocks.first { $0.type == "figure" } != nil)
        #expect(ps[1].blocks.filter { $0.type == "figure" }.count == 1)
    }

    @Test func blockTruthRoundTripsAndOldJSONDecodes() throws {
        let t = Fixtures.doc(.arxivTwoColumn).truth.pages[0]
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(PageTruth.self, from: data).blocks == t.blocks)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["blocks"] = nil
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(PageTruth.self, from: old).blocks.isEmpty)
    }

    @Test(arguments: blockScenarios)
    func generationIsFastAndDeterministic(_ s: Scenario) throws {
        let clock = ContinuousClock()
        var doc: SyntheticDocument?
        let elapsed = clock.measure { doc = Corpus.make(s) }
        #expect(elapsed < .seconds(10), "\(s): \(elapsed)")
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        #expect(try enc.encode(doc!.truth) == enc.encode(Fixtures.doc(s).truth))
    }

    @Test(arguments: blockScenarios)
    func opensInPDFKitAndWordsAreExtractable(_ s: Scenario) throws {
        let doc = Fixtures.doc(s)
        let pdf = try #require(PDFDocument(data: doc.data))
        #expect(pdf.pageCount == doc.truth.pages.count)
        let got = wordCounts(extractedWords(doc.data)), want = wordCounts(doc.truth.words)
        #expect(want.count > 100)
        let missing = want.filter { got[$0.key, default: 0] < $0.value }
        #expect(missing.isEmpty, "\(s): faltam \(missing.prefix(10))")
        // Palavras dos elementos especiais.
        for w in ["(1)", "Figure", "Table"] where s == .arxivTwoColumn { #expect(got[w, default: 0] >= 1, "\(w)") }
    }
}
