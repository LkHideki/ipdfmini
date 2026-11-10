import Foundation
import CoreGraphics
import PDFKit
import Testing
import MiniGeometry
import LayoutEngine
import SyntheticCorpus
@testable import PDFWriting

private func flatten(_ o: PDFOutline?) -> [PDFOutline] {
    guard let o else { return [] }
    return (0..<o.numberOfChildren).flatMap { i -> [PDFOutline] in
        guard let c = o.child(at: i) else { return [] }
        return [c] + flatten(c)
    }
}

private func clampPoint(_ p: CGPoint, _ r: CGRect) -> CGPoint {
    CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
}

private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
    let c = clampPoint(p, r)
    return hypot(p.x - c.x, p.y - c.y)
}

private func nearRect(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.maxX - b.maxX) < tol && abs(a.maxY - b.maxY) < tol
}

/// Pontos absolutos dos quadriláteros de uma anotação de marcação (PDFKit: relativos à origem).
private func quads(_ a: PDFAnnotation) -> [CGRect] {
    let pts = (a.quadrilateralPoints ?? []).map { CGPoint(x: $0.pointValue.x + a.bounds.minX, y: $0.pointValue.y + a.bounds.minY) }
    return stride(from: 0, to: pts.count - 3, by: 4).map { k in
        let q = pts[k..<(k + 4)]
        let xs = q.map(\.x), ys = q.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// Colocação simples: `rect` (espaço de página) escalado por `s`, canto inferior esquerdo em `at`.
private func place(_ page: Int, _ rect: CGRect, scale s: CGFloat, at: CGPoint = .zero, hidden: [CGRect] = [],
                   geometry: PageGeometry? = nil) -> Placement {
    let t = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        .concatenating(CGAffineTransform(scaleX: s, y: s))
        .concatenating(CGAffineTransform(translationX: at.x, y: at.y))
    return Placement(sourcePage: page, sourceRect: rect, transform: t, hidden: hidden, sourceGeometry: geometry)
}

private func plan(_ pages: [OutputPage], recipe: String = "receita-teste") -> LayoutPlan {
    LayoutPlan(profile: .booksPortrait, pages: pages, recipe: Recipe(id: recipe))
}

private struct Dir {
    let url = TestPDF.tempDir()
    var src: URL { url.appendingPathComponent("src.pdf") }
    var out: URL { url.appendingPathComponent("out.pdf") }
    func cleanup() {
        _ = chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }
    func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    @discardableResult
    func write(_ p: LayoutPlan, password: String? = nil, options: WriteOptions = WriteOptions()) throws -> PlacementWriteResult {
        try PlacementWriter().writeDetailed(p, source: SourceDocument(url: src, password: password), to: out, options: options)
    }
}

private func infoString(_ url: URL, _ key: String) -> String? {
    guard let doc = CGPDFDocument(url as CFURL), let info = doc.info else { return nil }
    var s: CGPDFStringRef?
    guard CGPDFDictionaryGetString(info, key, &s), let s else { return nil }
    return CGPDFStringCopyTextString(s) as String?
}

@Suite struct PlacementWriterTests {
    // MARK: Navegação (inv. 5)

    /// Sumário, links e realce do cenário `navigation`, sob o E4 real: cada destino cai na
    /// colocação que contém o ponto original (ou, se nenhuma contém, a mais próxima, com o
    /// ponto preso à borda), na página de saída dela; contagens preservadas.
    @Test func navigationRemapsOutlineLinksAndHighlight() throws {
        let c = try CaseSpec(scenario: .navigation, strategy: .portraitSlices).write()
        defer { c.cleanup() }
        let src = try #require(PDFDocument(url: c.src)), out = try #require(PDFDocument(url: c.out))
        let m = c.result.mapping
        let placements = c.plan.allPlacements

        func expected(_ s: Int, _ p: CGPoint) -> (out: Int, rect: CGRect) {
            let mine = placements.filter { $0.placement.sourcePage == s }
            let hit = mine.first { $0.placement.sourceRect.insetBy(dx: -0.001, dy: -0.001).contains(p) }
                ?? mine.min { distance(p, $0.placement.sourceRect) < distance(p, $1.placement.sourceRect) }!
            return (hit.out, hit.placement.sourceRect)
        }
        func checkDestination(_ sd: PDFDestination, _ od: PDFDestination?, _ what: String) throws {
            let od = try #require(od, "\(what): sem destino")
            let s = src.index(for: sd.page!), o = out.index(for: try #require(od.page))
            let p = c.analysis.pages[s].geometry.toPage(sd.point)
            let e = expected(s, p)
            #expect(o == e.out, "\(what): página de saída \(o), esperada \(e.out)")
            let back = try #require(m.unmap(point: od.point, onOutputPage: o), "\(what): destino fora das colocações")
            #expect(back.sourcePage == s)
            #expect(nearPoint(back.point, clampPoint(p, e.rect)), "\(what): \(back.point) ≠ \(clampPoint(p, e.rect))")
        }

        // Sumário.
        let so = flatten(src.outlineRoot), oo = flatten(out.outlineRoot)
        #expect(oo.count == c.doc.truth.outlineCount)
        #expect(so.map(\.label) == oo.map(\.label))
        for (a, b) in zip(so, oo) { try checkDestination(a.destination!, b.destination, "sumário '\(a.label ?? "")'") }
        #expect(c.result.remap.outlineItems == so.count)

        // Links: um por (link, colocação que ele toca); retângulo recortado e transformado.
        var expectedLinks = 0
        var sourceLinks: [(page: Int, rect: CGRect, a: PDFAnnotation)] = []
        for s in 0..<src.pageCount {
            let g = c.analysis.pages[s].geometry
            for a in src.page(at: s)!.annotations where a.type == "Link" {
                let r = g.toPage(a.bounds)
                sourceLinks.append((s, r, a))
                expectedLinks += placements.count { $0.placement.sourcePage == s && $0.placement.sourceRect.intersection(r).width > 0 && $0.placement.sourceRect.intersection(r).height > 0 }
            }
        }
        #expect(sourceLinks.count == c.doc.truth.linkCount)
        var outLinks = 0
        for o in 0..<out.pageCount {
            for a in out.page(at: o)!.annotations where a.type == "Link" {
                outLinks += 1
                let back = try #require(m.unmap(point: CGPoint(x: a.bounds.midX, y: a.bounds.midY), onOutputPage: o))
                let link = try #require(sourceLinks.first { $0.page == back.sourcePage && $0.rect.insetBy(dx: -0.01, dy: -0.01).contains(back.point) },
                                        "link da saída p\(o) sem link de origem em \(back.point)")
                let pl = try #require(placements.first { $0.out == o && $0.placement.sourceRect.contains(back.point) }).placement
                let want = link.rect.intersection(pl.sourceRect).applying(pl.transform).standardized
                #expect(nearRect(a.bounds, want), "link p\(o): \(a.bounds) ≠ \(want)")
                if let url = link.a.url {
                    #expect(a.url == url)
                } else {
                    try checkDestination(link.a.destination!, a.destination, "link p\(o)")
                }
            }
        }
        #expect(outLinks == expectedLinks)
        #expect(c.result.remap.outputLinks == expectedLinks && c.result.remap.droppedDestinations == 0)

        // Realce: os quadriláteros voltam ao realce de origem.
        let srcHighlights = (0..<src.pageCount).flatMap { s in
            src.page(at: s)!.annotations.filter { $0.type == "Highlight" }.map { (s, $0) }
        }
        #expect(srcHighlights.count == c.doc.truth.annotationCount)
        var outQuads: [(Int, CGRect)] = []
        for o in 0..<out.pageCount {
            for a in out.page(at: o)!.annotations where a.type == "Highlight" {
                for q in quads(a) {
                    let lo = try #require(m.unmap(point: CGPoint(x: q.minX, y: q.minY), onOutputPage: o))
                    let hi = try #require(m.unmap(point: CGPoint(x: q.maxX, y: q.maxY), onOutputPage: o))
                    outQuads.append((lo.sourcePage, CGRect(x: lo.point.x, y: lo.point.y, width: hi.point.x - lo.point.x, height: hi.point.y - lo.point.y)))
                }
            }
        }
        for (s, h) in srcHighlights {
            let g = c.analysis.pages[s].geometry
            let wantQuads = quads(h).map { g.toPage($0) }
            let got = outQuads.filter { $0.0 == s }.map(\.1)
            #expect(got.count == wantQuads.count)
            for (a, b) in zip(got, wantQuads) { #expect(nearRect(a, b), "realce \(a) ≠ \(b)") }
        }
    }

    /// Link, realce e traço que atravessam o corte entre duas colocações viram dois; a nota
    /// segue o canto; destino e sumário vão para a página de saída da origem de destino.
    @Test func annotationsCrossingACutAreSplitPerPlacement() throws {
        let d = Dir()
        defer { d.cleanup() }
        var p0 = TestPageSpec()
        p0.internalLink = TestLink(rect: CGRect(x: 50, y: 380, width: 200, height: 40), destinationPage: 1)
        p0.highlight = CGRect(x: 100, y: 390, width: 300, height: 20)
        p0.externalLink = (CGRect(x: 300, y: 100, width: 100, height: 20), URL(string: "https://example.org/x")!)
        try TestPDF.build(TestDocSpec(pages: [p0, TestPageSpec()], outline: [("Cap", 1, 0)]), to: d.src)
        // Nota e tinta pelo PDFKit (o gerador não tem).
        let doc = try #require(PDFDocument(url: d.src))
        let note = PDFAnnotation(bounds: CGRect(x: 400, y: 600, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "nota"
        doc.page(at: 0)!.addAnnotation(note)
        let ink = PDFAnnotation(bounds: CGRect(x: 90, y: 300, width: 30, height: 200), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 10, y: 10))
        path.line(to: CGPoint(x: 10, y: 190))
        ink.add(path)
        doc.page(at: 0)!.addAnnotation(ink)
        // O PDFKit não regrava sobre o arquivo que tem aberto.
        let annotated = d.url.appendingPathComponent("anotado.pdf")
        try #require(doc.write(to: annotated))
        _ = try FileManager.default.replaceItemAt(d.src, withItemAt: annotated)

        let top = place(0, CGRect(x: 0, y: 400, width: 600, height: 400), scale: 0.5)
        let bottom = place(0, CGRect(x: 0, y: 0, width: 600, height: 400), scale: 0.5)
        let whole = place(1, CGRect(x: 0, y: 0, width: 600, height: 800), scale: 0.5)
        let r = try d.write(plan([OutputPage(sizePt: CGSize(width: 300, height: 200), placements: [top]),
                                  OutputPage(sizePt: CGSize(width: 300, height: 200), placements: [bottom]),
                                  OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [whole])]))
        let out = try #require(PDFDocument(url: d.out))
        func annots(_ o: Int, _ t: String) -> [PDFAnnotation] { out.page(at: o)!.annotations.filter { $0.type == t } }

        // Link interno partido em dois; destino (10, 700) da p. 1 → saída 2, (5, 350).
        let l0 = annots(0, "Link").filter { $0.url == nil }, l1 = annots(1, "Link").filter { $0.url == nil }
        try #require(l0.count == 1 && l1.count == 1)
        #expect(nearRect(l0[0].bounds, CGRect(x: 25, y: 0, width: 100, height: 10)), "\(l0[0].bounds)")
        #expect(nearRect(l1[0].bounds, CGRect(x: 25, y: 190, width: 100, height: 10)), "\(l1[0].bounds)")
        for l in l0 + l1 {
            #expect(l.destination.map { out.index(for: $0.page!) } == 2)
            #expect(nearPoint(l.destination!.point, CGPoint(x: 5, y: 350)))
        }
        // Link externo só na metade de baixo.
        #expect(annots(1, "Link").compactMap(\.url) == [URL(string: "https://example.org/x")!])
        #expect(annots(0, "Link").allSatisfy { $0.url == nil })
        #expect(nearRect(annots(1, "Link").first { $0.url != nil }!.bounds, CGRect(x: 150, y: 50, width: 50, height: 10)))

        // Realce partido.
        let h0 = annots(0, "Highlight"), h1 = annots(1, "Highlight")
        try #require(h0.count == 1 && h1.count == 1)
        #expect(quads(h0[0]).count == 1 && nearRect(quads(h0[0])[0], CGRect(x: 50, y: 0, width: 150, height: 5)))
        #expect(quads(h1[0]).count == 1 && nearRect(quads(h1[0])[0], CGRect(x: 50, y: 195, width: 150, height: 5)))

        // Nota: canto superior esquerdo (400, 620) → (200, 110), tamanho do ícone mantido.
        let n = annots(0, "Text")
        try #require(n.count == 1 && annots(1, "Text").isEmpty)
        // O PDFKit lê ícone de nota com 24×24 (origem e saída); o que se mapeia é o canto.
        let srcNote = try #require(PDFDocument(url: d.src)?.page(at: 0)?.annotations.first { $0.type == "Text" })
        #expect(nearPoint(CGPoint(x: n[0].bounds.minX, y: n[0].bounds.maxY), CGPoint(x: 200, y: 110)), "\(n[0].bounds)")
        #expect(n[0].bounds.size == srcNote.bounds.size)
        #expect(n[0].contents == "nota")

        // Traço (100,310)→(100,490) cortado em y = 400.
        func strokes(_ a: PDFAnnotation) -> [[CGPoint]] {
            (a.paths ?? []).map { AnnotationRemap.points(of: $0).map { CGPoint(x: $0.x + a.bounds.minX, y: $0.y + a.bounds.minY) } }
        }
        let i0 = annots(0, "Ink"), i1 = annots(1, "Ink")
        try #require(i0.count == 1 && i1.count == 1)
        let s0 = strokes(i0[0]).flatMap { $0 }, s1 = strokes(i1[0]).flatMap { $0 }
        #expect(s0.count == 2 && nearPoint(s0[0], CGPoint(x: 50, y: 0)) && nearPoint(s0[1], CGPoint(x: 50, y: 45)), "\(s0)")
        #expect(s1.count == 2 && nearPoint(s1[0], CGPoint(x: 50, y: 155)) && nearPoint(s1[1], CGPoint(x: 50, y: 200)), "\(s1)")

        // Sumário: p. 1 (0, 700) → saída 2 (0, 350).
        let o = flatten(out.outlineRoot)
        #expect(o.map(\.label) == ["Cap"])
        #expect(o.first?.destination.map { out.index(for: $0.page!) } == 2)
        #expect(o.first.map { nearPoint($0.destination!.point, CGPoint(x: 0, y: 350)) } == true)

        #expect(r.remap.sourceLinks == 2 && r.remap.outputLinks == 3)
        #expect(r.remap.sourceAnnotations == 3 && r.remap.outputAnnotations == 5 && r.remap.droppedAnnotations == 0)
    }

    /// Páginas fora do plano: o sumário mantém a contagem (itens sem destino) e nada da
    /// navegação antiga sobra apontando para páginas removidas.
    @Test func destinationsOutsideThePlanAreDroppedNotDangling() throws {
        let doc = CorpusCache.doc(.navigation)
        let a = analysis(from: doc)
        let full = PortraitSlicesStrategy().plan(a, .booksPortrait, Recipe(id: "parcial"))
        let kept = full.pages.filter { [1, 2].contains($0.placements.first?.sourcePage ?? -1) }
        let d = Dir()
        defer { d.cleanup() }
        try doc.data.write(to: d.src)
        let r = try d.write(LayoutPlan(profile: full.profile, pages: kept, recipe: full.recipe))
        let out = try #require(PDFDocument(url: d.out))
        #expect(out.pageCount == kept.count)
        let items = flatten(out.outlineRoot)
        #expect(items.count == doc.truth.outlineCount)
        // Capítulo 1, 1.1 (p. 1) e 1.2 (p. 2) ficam; capítulos 2, 2.1 e 3 perdem o destino.
        #expect(items.filter { $0.destination != nil }.count == 3)
        #expect(items.compactMap(\.destination).allSatisfy { $0.page.map { out.index(for: $0) } != nil })
        #expect(r.remap.droppedDestinations == 3)
        // Só o link de URL da p. 3 (índice 2) está em página do plano.
        let links = (0..<out.pageCount).flatMap { out.page(at: $0)!.annotations.filter { $0.type == "Link" } }
        #expect(links.count == 1 && links[0].url != nil)
    }

    // MARK: Geometria

    /// `sourceGeometry` nil: o escritor lê Crop∩Media e /Rotate da origem (caixas com
    /// origem não nula); a colocação renderiza como a janela pelo CoreGraphics.
    @Test(arguments: [0, 90, 180, 270])
    func missingSourceGeometryIsReadFromThePage(_ rotate: Int) throws {
        let d = Dir()
        defer { d.cleanup() }
        let media = CGRect(x: 30, y: 40, width: 400, height: 600)
        let crop = CGRect(x: 50, y: 60, width: 360, height: 560)
        // Marcas assimétricas: um erro de rotação ou de origem desloca a tinta.
        let content = "0 g 100 200 50 80 re f 300 500 60 20 re f 0.5 g 60 70 30 30 re f"
        try TestPDF.rawPDF(media: media, crop: crop, rotate: rotate, content: content, to: d.src)
        let g = PageGeometry(effectiveBox: crop, rotation: rotate)
        let window = g.pageBox.insetBy(dx: 5, dy: 5)
        let p = place(0, window, scale: 0.8, at: CGPoint(x: 10, y: 10))
        let size = CGSize(width: window.width * 0.8 + 20, height: window.height * 0.8 + 20)
        let lp = plan([OutputPage(sizePt: size, placements: [p])])
        try d.write(lp)
        let diffs = comparePlacements(plan: lp, source: d.src, output: d.out, geometries: { _ in g })
        #expect(diffs.count == 1)
        #expect(diffs[0].referenceInk > 1000)
        #expect(diffs[0].ok, "rotação \(rotate): \(diffs[0].mismatched) px, máx Δ \(diffs[0].maxGrayDelta)")
    }

    /// A geometria do plano manda sobre a da página (análise pela TrimBox).
    @Test func planGeometryWinsOverPageGeometry() throws {
        let d = Dir()
        defer { d.cleanup() }
        let media = CGRect(x: 0, y: 0, width: 400, height: 600)
        try TestPDF.rawPDF(media: media, crop: nil, rotate: 90, content: "0 g 100 200 50 80 re f", to: d.src)
        // Caixa efetiva (ex. TrimBox) menor que a página: o espaço de página muda com ela.
        let trim = CGRect(x: 20, y: 30, width: 360, height: 540)
        let g = PageGeometry(effectiveBox: trim, rotation: 90)
        let window = g.toPage(CGRect(x: 90, y: 190, width: 70, height: 100))
        let lp = plan([OutputPage(sizePt: CGSize(width: 200, height: 140), placements: [place(0, window, scale: 1, geometry: g)])])
        let r = try d.write(lp)
        // A tinta (100,200)-(150,280) no usuário deve cair no centro da janela.
        let ink = g.toPage(CGRect(x: 100, y: 200, width: 50, height: 80))
        let expected = ink.applying(lp.pages[0].placements[0].transform)
        let img = Render.outputPage(CGPDFDocument(d.out as CFURL)!.page(at: 1)!, size: CGSize(width: 200, height: 140))
        let inside = Render.ink(img, in: expected.insetBy(dx: 1, dy: 1), pageHeight: 140)
        let total = img.inkCount
        #expect(inside > 0 && Double(inside) / Double(total) > 0.9, "\(inside) de \(total) px no lugar")
        #expect(nearPoint(r.mapping.map(point: CGPoint(x: ink.midX, y: ink.midY), fromSourcePage: 0)[0].point,
                          CGPoint(x: expected.midX, y: expected.midY)))
    }

    // MARK: Máscaras e sobreposições

    @Test func hiddenRegionsArePaintedWhite() throws {
        let d = Dir()
        defer { d.cleanup() }
        var spec = TestPageSpec()
        spec.drawText = false
        spec.marker = CGRect(x: 100, y: 100, width: 50, height: 50)
        try TestPDF.build(TestDocSpec(pages: [spec]), to: d.src)
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let marker = spec.marker!
        let lp = plan([
            OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(0, page, scale: 0.5, hidden: [marker.insetBy(dx: -2, dy: -2)])]),
            OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(0, page, scale: 0.5)]),
        ])
        try d.write(lp)
        let doc = CGPDFDocument(d.out as CFURL)!
        let at = marker.applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
        let masked = Render.outputPage(doc.page(at: 1)!, size: CGSize(width: 300, height: 400))
        let control = Render.outputPage(doc.page(at: 2)!, size: CGSize(width: 300, height: 400))
        #expect(Render.ink(control, in: at, pageHeight: 400) > 2000)
        #expect(Render.ink(masked, in: at.insetBy(dx: -2, dy: -2), pageHeight: 400) == 0)
        #expect(masked.inkCount == 0)
    }

    @Test func overlaysAreDrawn() throws {
        let d = Dir()
        defer { d.cleanup() }
        var spec = TestPageSpec()
        spec.drawText = false
        try TestPDF.build(TestDocSpec(pages: [spec]), to: d.src)
        let size = CGSize(width: 300, height: 400)
        let indicator = CGRect(x: 200, y: 2, width: 60, height: 7)
        let bar = CGRect(x: 20, y: 380, width: 100, height: 4)
        let lp = plan([OutputPage(sizePt: size, placements: [place(0, CGRect(x: 0, y: 0, width: 600, height: 800), scale: 0.5)],
                                  overlays: [.pageIndicator(text: "p. 7 · 1/3", rect: indicator),
                                             .progressBar(fraction: 0.5, rect: bar), .continuityMark(y: 100)])])
        try d.write(lp)
        let img = Render.outputPage(CGPDFDocument(d.out as CFURL)!.page(at: 1)!, size: size)
        #expect(Render.ink(img, in: indicator, pageHeight: 400) > 40)
        // Barra: metade escura (0,45), trilho claro (0,85, acima do limiar de tinta).
        let left = CGRect(x: bar.minX, y: bar.minY, width: bar.width / 2, height: bar.height).insetBy(dx: 1, dy: 0.5)
        let right = CGRect(x: bar.midX, y: bar.minY, width: bar.width / 2, height: bar.height).insetBy(dx: 1, dy: 0.5)
        #expect(Render.ink(img, in: left, pageHeight: 400) > Int(left.width * left.height * 4 * 0.9))
        #expect(Render.ink(img, in: right, pageHeight: 400) == 0)
        let trackPixel = img.pixels[Int((400 - bar.midY) * 2) * img.width + Int((bar.maxX - 5) * 2)]
        #expect(trackPixel < 240, "trilho não desenhado")
        // Marca de continuidade: fio tracejado em y = 100, fora dos quadrados de canto. Fio de
        // 0,5 pt cinza sobre a fronteira de pixel fica perto do limiar: conta qualquer traço (< 250).
        let R = lp.profile.cornerRadiusPt
        #expect(R > 2)
        #expect(Render.ink(img, in: CGRect(x: R, y: 99, width: size.width - 2 * R, height: 2), pageHeight: 400, below: 250) > 100)
        #expect(Render.ink(img, in: CGRect(x: 0, y: 99, width: R - 1, height: 2), pageHeight: 400, below: 250) == 0)
        // Texto do indicador é texto (WinAnsi, com o ponto médio).
        let text = PDFDocument(url: d.out)!.page(at: 0)!.string ?? ""
        #expect(text.contains("p. 7 · 1/3"), "\(text)")
        // Nada fora das sobreposições.
        #expect(img.inkCount == Render.ink(img, in: indicator.insetBy(dx: -1, dy: -1), pageHeight: 400)
                + Render.ink(img, in: bar.insetBy(dx: -1, dy: -1), pageHeight: 400)
                + Render.ink(img, in: CGRect(x: 0, y: 98, width: size.width, height: 4), pageHeight: 400))
        #expect(Render.ink(img, in: CGRect(x: 0, y: 10, width: size.width, height: 80), pageHeight: 400, below: 250) == 0)
    }

    // MARK: Escrita atômica e erros

    @Test func failedWriteLeavesDestinationIntact() throws {
        let d = Dir()
        defer { d.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: d.src)
        let sentinel = Data("SENTINELA".utf8)
        try sentinel.write(to: d.out)
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let before = d.listing()

        // Plano inválido (página inexistente).
        #expect(throws: WriteError.self) {
            try d.write(plan([OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(9, page, scale: 0.5)])]))
        }
        #expect(try Data(contentsOf: d.out) == sentinel)
        #expect(d.listing() == before)

        // Falha na gravação: diretório sem escrita (o temporário não pode nascer).
        #expect(chmod(d.url.path, 0o555) == 0)
        #expect(throws: WriteError.writeFailed(d.out)) {
            try d.write(plan([OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(0, page, scale: 0.5)])]))
        }
        #expect(chmod(d.url.path, 0o755) == 0)
        #expect(try Data(contentsOf: d.out) == sentinel)
        #expect(d.listing() == before)

        // Sucesso substitui o destino e não deixa temporário.
        try d.write(plan([OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(0, page, scale: 0.5)])]))
        #expect(PDFDocument(url: d.out)?.pageCount == 1)
        #expect(d.listing() == before)
    }

    @Test func corruptedSourceIsAnError() throws {
        let d = Dir()
        defer { d.cleanup() }
        try Data("%PDF-1.4\nisto não é um PDF\n".utf8).write(to: d.src)
        let lp = plan([OutputPage(sizePt: CGSize(width: 100, height: 100), placements: [place(0, CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)])])
        #expect(throws: WriteError.cannotOpen(d.src)) { try d.write(lp) }
        #expect(!FileManager.default.fileExists(atPath: d.out.path))
        #expect(d.listing() == ["src.pdf"])
        // Arquivo truncado no meio de um PDF válido.
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: d.src)
        let data = try Data(contentsOf: d.src)
        try data.prefix(data.count / 3).write(to: d.src)
        #expect(throws: WriteError.self) { try d.write(lp) }
        #expect(!FileManager.default.fileExists(atPath: d.out.path))
    }

    @Test func invalidPlansAreRejected() throws {
        let d = Dir()
        defer { d.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: d.src)
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(throws: WriteError.unsupportedPlan("plano sem páginas")) { try d.write(plan([])) }
        let singular = Placement(sourcePage: 0, sourceRect: r, transform: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0))
        #expect(throws: WriteError.self) { try d.write(plan([OutputPage(sizePt: r.size, placements: [singular])])) }
        let nan = Placement(sourcePage: 0, sourceRect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), transform: .identity)
        #expect(throws: WriteError.self) { try d.write(plan([OutputPage(sizePt: r.size, placements: [nan])])) }
    }

    @Test func encryptedSourceNeedsPasswordAndOutputIsPlain() throws {
        let d = Dir()
        defer { d.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: d.src, ownerPassword: "dono", userPassword: "leitor")
        let lp = plan([OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(0, CGRect(x: 0, y: 0, width: 600, height: 800), scale: 0.5)])])
        #expect(throws: WriteError.encryptedWithoutPassword(d.src)) { try d.write(lp) }
        #expect(throws: WriteError.wrongPassword(d.src)) { try d.write(lp, password: "errada") }
        try d.write(lp, password: "leitor")
        let out = try #require(CGPDFDocument(d.out as CFURL))
        #expect(!out.isEncrypted && out.isUnlocked)
        #expect((PDFDocument(url: d.out)?.page(at: 0)?.string ?? "").contains("p0l0"))
    }

    // MARK: Metadados

    @Test func metadataProducerAndPageLabels() throws {
        let d = Dir()
        defer { d.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec(), TestPageSpec()]), to: d.src)
        let page = CGRect(x: 0, y: 0, width: 600, height: 800)
        let half = CGSize(width: 300, height: 200)
        let lp = plan([OutputPage(sizePt: half, placements: [place(0, CGRect(x: 0, y: 400, width: 600, height: 400), scale: 0.5)]),
                       OutputPage(sizePt: half, placements: [place(0, CGRect(x: 0, y: 0, width: 600, height: 400), scale: 0.5)]),
                       OutputPage(sizePt: CGSize(width: 300, height: 400), placements: [place(1, page, scale: 0.5)])],
                      recipe: "r-42")
        // Padrão: título e autor da origem; Producer com a receita.
        try d.write(lp)
        #expect(infoString(d.out, "Producer") == "iPDFmini \(PDFWriting.version) recipe:r-42")
        #expect(infoString(d.out, "Title") == "Título de teste")
        #expect(infoString(d.out, "Author") == "Autora de teste")
        #expect(PDFDocument(url: d.out)?.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String
                == "iPDFmini \(PDFWriting.version) recipe:r-42")
        // PageLabels: o número da página de origem (as duas fatias da p. 1 mostram "1").
        let out = try #require(PDFDocument(url: d.out))
        #expect((0..<3).map { out.page(at: $0)?.label } == ["1", "1", "2"])

        // Opções: título/autor novos, limpeza do resto, receita sobrescrita.
        try d.write(lp, options: WriteOptions(recipeID: "outra", title: "Título novo", author: "Autor ç", clearMetadata: true))
        #expect(infoString(d.out, "Producer") == "iPDFmini \(PDFWriting.version) recipe:outra")
        #expect(infoString(d.out, "Title") == "Título novo")
        #expect(infoString(d.out, "Author") == "Autor ç")
        #expect(infoString(d.out, "Subject") == nil)
    }

    /// Por que o Producer vai pela C API e não pelo InfoPatch: a saída do qpdf usa xref
    /// stream (object streams), que o InfoPatch recusa sem tocar no arquivo.
    @Test func infoPatchRefusesTheQpdfOutputSoProducerGoesThroughTheCAPI() throws {
        let d = Dir()
        defer { d.cleanup() }
        try TestPDF.build(TestDocSpec(pages: [TestPageSpec()]), to: d.src)
        try d.write(plan([OutputPage(sizePt: CGSize(width: 300, height: 400),
                                     placements: [place(0, CGRect(x: 0, y: 0, width: 600, height: 800), scale: 0.5)])]))
        let before = try Data(contentsOf: d.out)
        #expect(!InfoPatch.setProducer("outro", in: d.out))
        #expect(try Data(contentsOf: d.out) == before)
        #expect(infoString(d.out, "Producer") == "iPDFmini \(PDFWriting.version) recipe:receita-teste")
    }
}

// MARK: - PlanMapping

@Suite struct PlanMappingTests {
    @Test func rotatedGeometryRoundTripsAndSplitsRects() {
        let g = PageGeometry(effectiveBox: CGRect(x: 30, y: 40, width: 400, height: 600), rotation: 90)
        let box = g.pageBox
        let top = CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2)
        let bottom = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height / 2)
        let lp = plan([OutputPage(sizePt: CGSize(width: 300, height: 150), placements: [place(0, top, scale: 0.5, geometry: g)]),
                       OutputPage(sizePt: CGSize(width: 300, height: 150), placements: [place(0, bottom, scale: 0.5, geometry: g)])])
        let m = PlanMapping(plan: lp)
        let p = CGPoint(x: box.midX + 13.37, y: box.midY + 50)
        let hits = m.map(point: p, fromSourcePage: 0)
        #expect(hits.count == 1 && hits[0].outputPage == 0)
        let back = m.unmap(point: hits[0].point, onOutputPage: 0)
        #expect(back?.sourcePage == 0 && back.map { nearPoint($0.point, p, 1e-9) } == true)
        // Ponto sobre o corte: nas duas colocações.
        #expect(m.map(point: CGPoint(x: box.midX, y: box.midY), fromSourcePage: 0).map(\.outputPage) == [0, 1])
        // Retângulo que atravessa o corte vira dois pedaços.
        let pieces = m.map(rect: CGRect(x: box.midX - 10, y: box.midY - 5, width: 20, height: 10), fromSourcePage: 0)
        #expect(pieces.map(\.outputPage) == [0, 1])
        #expect(pieces.allSatisfy { abs($0.rect.height - 2.5) < 1e-9 && abs($0.rect.width - 10) < 1e-9 })
        // Fora de toda colocação na saída.
        #expect(m.unmap(point: CGPoint(x: -5, y: 10), onOutputPage: 0) == nil)
        #expect(m.geometry(ofSourcePage: 0) == g)
    }

    @Test func destinationOutsideEveryPlacementGoesToTheNearestClamped() {
        let a = CGRect(x: 72, y: 500, width: 400, height: 200)
        let b = CGRect(x: 72, y: 100, width: 400, height: 300)
        let lp = plan([OutputPage(sizePt: CGSize(width: 200, height: 100), placements: [place(0, a, scale: 0.5)]),
                       OutputPage(sizePt: CGSize(width: 200, height: 150), placements: [place(0, b, scale: 0.5)])])
        let m = PlanMapping(plan: lp)
        // Topo da página (acima de a): presa à borda de cima de a.
        let d1 = m.destination(point: CGPoint(x: 72, y: 720), fromSourcePage: 0)
        #expect(d1?.outputPage == 0 && d1.map { nearPoint($0.point, CGPoint(x: 0, y: 100)) } == true)
        // No vão entre a e b, mais perto de b.
        let d2 = m.destination(point: CGPoint(x: 100, y: 420), fromSourcePage: 0)
        #expect(d2?.outputPage == 1 && d2.map { nearPoint($0.point, CGPoint(x: 14, y: 150)) } == true)
        #expect(m.destination(point: .zero, fromSourcePage: 3) == nil)
    }

    @Test func overlappingOutputPlacementsUnmapToTheTopmost() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        let lp = plan([OutputPage(sizePt: CGSize(width: 100, height: 100),
                                  placements: [place(0, r, scale: 1), place(1, r, scale: 1)])])
        let m = PlanMapping(plan: lp)
        #expect(m.unmap(point: CGPoint(x: 50, y: 50), onOutputPage: 0)?.sourcePage == 1)
    }

    /// Duas colocações da mesma página com geometrias diferentes (ex. Crop e Trim): o
    /// espaço de página é o da 1ª; a 2ª converte pelo espaço do usuário.
    @Test func placementsWithDifferentGeometriesAgreeInUserSpace() {
        let g1 = PageGeometry(effectiveBox: CGRect(x: 0, y: 0, width: 400, height: 600), rotation: 90)
        let g2 = PageGeometry(effectiveBox: CGRect(x: 20, y: 30, width: 360, height: 540), rotation: 90)
        let user = CGPoint(x: 120, y: 260)
        let lp = plan([OutputPage(sizePt: CGSize(width: 600, height: 400), placements: [place(0, g1.pageBox, scale: 1, geometry: g1)]),
                       OutputPage(sizePt: CGSize(width: 540, height: 360), placements: [place(0, g2.pageBox, scale: 1, geometry: g2)])])
        let m = PlanMapping(plan: lp)
        let hits = m.map(point: g1.toPage(user), fromSourcePage: 0)
        #expect(hits.map(\.outputPage) == [0, 1])
        let p1 = g1.toPage(user).applying(lp.pages[0].placements[0].transform)
        let p2 = g2.toPage(user).applying(lp.pages[1].placements[0].transform)
        #expect(nearPoint(hits[0].point, p1, 1e-9) && nearPoint(hits[1].point, p2, 1e-9))
        let back = m.unmap(point: p2, onOutputPage: 1)
        #expect(back.map { nearPoint($0.point, g1.toPage(user), 1e-9) } == true)
    }

    @Test func inkClipCutsStrokesAtTheBorder() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        let runs = AnnotationRemap.clip([CGPoint(x: -5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 5), CGPoint(x: 5, y: 8)], to: r)
        #expect(runs.count == 2)
        #expect(runs[0] == [CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 5)])
        #expect(runs[1].count == 2 && nearPoint(runs[1][0], CGPoint(x: 10, y: 6.5), 1e-9) && runs[1][1] == CGPoint(x: 5, y: 8))
        #expect(AnnotationRemap.clip([CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 30)], to: r).isEmpty)
    }
}
