import Foundation
import CoreGraphics
import PDFKit
import AppKit
import MiniGeometry

/// S2 — PDFKit com caixas: alcance do `BoxWriter`.
enum S2 {
    // MARK: Inventário de um documento

    struct LinkInfo {
        var rect: CGRect
        var destPage: Int?
        var url: String?
    }

    struct PageInv {
        var text: String
        var links: [LinkInfo]
        var annotTypes: [String: Int]
        var contents: [String]
    }

    struct OutlineEntry {
        var level: Int
        var label: String
        var destPage: Int?
    }

    struct Inv {
        var pages: [PageInv]
        var outline: [OutlineEntry]
        var linkCount: Int { pages.reduce(0) { $0 + $1.links.count } }
        var internalLinks: Int { pages.reduce(0) { $0 + $1.links.filter { $0.destPage != nil }.count } }
        var externalLinks: Int { pages.reduce(0) { $0 + $1.links.filter { $0.url != nil }.count } }
        func annots(_ t: String) -> Int { pages.reduce(0) { $0 + ($1.annotTypes[t] ?? 0) } }
    }

    static func pageIndex(_ doc: PDFDocument, _ p: PDFPage?) -> Int? {
        guard let p else { return nil }
        let i = doc.index(for: p)
        return i == NSNotFound ? -1 : i
    }

    static func inventory(_ doc: PDFDocument) -> Inv {
        var pages: [PageInv] = []
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            var links: [LinkInfo] = []
            var types: [String: Int] = [:]
            var contents: [String] = []
            for a in p.annotations {
                let t = (a.type ?? "?").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                types[t, default: 0] += 1
                if t == "Link" {
                    let dest = a.destination ?? (a.action as? PDFActionGoTo)?.destination
                    let u = a.url ?? (a.action as? PDFActionURL)?.url
                    links.append(LinkInfo(rect: a.bounds, destPage: pageIndex(doc, dest?.page), url: u?.absoluteString))
                } else if t != "Popup", let c = a.contents {
                    contents.append("\(t):\(c)")
                }
            }
            links.sort { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            pages.append(PageInv(text: p.string ?? "", links: links, annotTypes: types, contents: contents.sorted()))
        }
        var outline: [OutlineEntry] = []
        func walk(_ o: PDFOutline, _ level: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                outline.append(OutlineEntry(level: level, label: c.label ?? "", destPage: pageIndex(doc, c.destination?.page)))
                walk(c, level + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, 0) }
        return Inv(pages: pages, outline: outline)
    }

    struct Comparison {
        var text = (ok: 0, total: 0)
        var links = (ok: 0, total: 0)          // páginas cuja lista de links bate
        var annots = (ok: 0, total: 0)
        var copyLinks = (ok: 0, total: 0)      // idem, só nas cópias (c > 0)
        var copyAnnots = (ok: 0, total: 0)
        var copyText = (ok: 0, total: 0)
        var outlineCount = (base: 0, out: 0)
        var outlineDest = (ok: 0, total: 0)
        var outlineLabels = 0
    }

    /// Como esperar cada página q da saída em relação à página q/k da base.
    struct CompareSpec {
        var k: Int
        var kind: Gen.Kind
        /// Translação que o PDFKit aplica ao espaço do usuário (origem da MediaBox → 0).
        var shift: (Int) -> CGPoint = { _ in .zero }
        /// Faixa y (coordenadas da origem) visível na página q; nil = página inteira.
        var region: (Int) -> ClosedRange<CGFloat>? = { _ in nil }
    }

    /// Marcadores esperados: núcleo (certamente visíveis) e folgado (inclui linhas cortadas na borda).
    static func expectedTokens(srcPage: Int, kind: Gen.Kind, range: ClosedRange<CGFloat>) -> (core: Set<String>, loose: Set<String>) {
        var core = Set<String>(), loose = Set<String>()
        for (l, y) in Gen.baselines(kind, pageHeight: Gen.a4.height).enumerated() {
            if y >= range.lowerBound + 4 && y <= range.upperBound - 10 { core.insert(Gen.token(srcPage, l)) }
            if y >= range.lowerBound - 12 && y <= range.upperBound + 4 { loose.insert(Gen.token(srcPage, l)) }
        }
        return (core, loose)
    }

    /// Cada página q da saída deve equivaler à página q/k da base; destinos são multiplicados por k.
    static func compare(base: Inv, out: Inv, spec: CompareSpec) -> Comparison {
        let k = spec.k
        var c = Comparison()
        for (q, op) in out.pages.enumerated() {
            guard q / k < base.pages.count else { continue }
            let bp = base.pages[q / k]
            let isCopy = q % k > 0
            let textOK: Bool
            if let range = spec.region(q) {
                let got = Set(tokens(in: op.text))
                let exp = expectedTokens(srcPage: q / k, kind: spec.kind, range: range)
                textOK = exp.core.isSubset(of: got) && got.isSubset(of: exp.loose)
            } else {
                textOK = op.text == bp.text
            }
            let t = spec.shift(q)
            let linksOK = op.links.count == bp.links.count && zip(op.links, bp.links).allSatisfy {
                close($0.rect, $1.rect.offsetBy(dx: t.x, dy: t.y)) && $0.url == $1.url && $0.destPage == $1.destPage.map { $0 * k }
            }
            let annotOK = op.annotTypes == bp.annotTypes && op.contents == bp.contents
            c.text.total += 1; c.links.total += 1; c.annots.total += 1
            if textOK { c.text.ok += 1 }
            if linksOK { c.links.ok += 1 }
            if annotOK { c.annots.ok += 1 }
            if isCopy {
                c.copyText.total += 1; c.copyLinks.total += 1; c.copyAnnots.total += 1
                if textOK { c.copyText.ok += 1 }
                if linksOK { c.copyLinks.ok += 1 }
                if annotOK { c.copyAnnots.ok += 1 }
            }
        }
        c.outlineCount = (base.outline.count, out.outline.count)
        for (b, o) in zip(base.outline, out.outline) {
            c.outlineDest.total += 1
            if o.destPage == b.destPage.map({ $0 * k }) { c.outlineDest.ok += 1 }
            if o.label == b.label && o.level == b.level { c.outlineLabels += 1 }
        }
        return c
    }

    static func frac(_ t: (ok: Int, total: Int)) -> String { "\(t.ok)/\(t.total)" }

    static func compareRow(_ name: String, _ c: Comparison, copies: Bool) -> [String] {
        var r = [name, frac(c.text), frac(c.links), frac(c.annots),
                 "\(c.outlineCount.out)/\(c.outlineCount.base)", frac(c.outlineDest)]
        if copies { r += [frac(c.copyText), frac(c.copyLinks), frac(c.copyAnnots)] }
        return r
    }

    // MARK: Documentos de entrada

    static func makeNavDocument(dir: URL) throws -> URL {
        let raw = dir.appendingPathComponent("s2-src-nav10-raw.pdf")
        try Gen.makeTextDocument(at: raw, pages: 10)
        guard let doc = PDFDocument(url: raw) else { throw SpikeError("S2: PDF base não abriu") }
        let baseline0 = Gen.baselines(.text, pageHeight: Gen.a4.height)

        // Sumário: 10 capítulos; os 3 primeiros com 2 subseções.
        let root = PDFOutline()
        var top = 0
        for i in 0..<10 {
            guard let p = doc.page(at: i) else { continue }
            let o = PDFOutline()
            o.label = "Capitulo \(i + 1)"
            o.destination = PDFDestination(page: p, at: CGPoint(x: 0, y: 800))
            if i < 3 {
                for s in 0..<2 {
                    let sub = PDFOutline()
                    sub.label = "Secao \(i + 1).\(s + 1)"
                    sub.destination = PDFDestination(page: p, at: CGPoint(x: 0, y: 600 - CGFloat(s) * 100))
                    o.insertChild(sub, at: s)
                }
            }
            root.insertChild(o, at: top)
            top += 1
        }
        doc.outlineRoot = root

        // Links internos (página i → i+1) e externos (páginas 0 e 1).
        for i in 0..<9 {
            guard let p = doc.page(at: i), let next = doc.page(at: i + 1) else { continue }
            let link = PDFAnnotation(bounds: CGRect(x: 56, y: baseline0[0] - 3, width: 200, height: 14), forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: next, at: CGPoint(x: 0, y: 800))
            let b = PDFBorder(); b.lineWidth = 0; link.border = b
            p.addAnnotation(link)
        }
        for i in 0..<2 {
            guard let p = doc.page(at: i) else { continue }
            let link = PDFAnnotation(bounds: CGRect(x: 56, y: baseline0[5] - 3, width: 200, height: 14), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.com/p\(i + 1)")
            let b = PDFBorder(); b.lineWidth = 0; link.border = b
            p.addAnnotation(link)
        }
        // Realce (página 2) e nota (página 3).
        if let p = doc.page(at: 1) {
            let r = CGRect(x: 56, y: baseline0[3] - 3, width: 300, height: 14)
            let hl = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil)
            hl.color = NSColor.yellow
            hl.contents = "realce de teste"
            hl.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: 14)), NSValue(point: NSPoint(x: 300, y: 14)),
                                      NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: 300, y: 0))]
            p.addAnnotation(hl)
        }
        if let p = doc.page(at: 2) {
            let note = PDFAnnotation(bounds: CGRect(x: 520, y: 760, width: 20, height: 20), forType: .text, withProperties: nil)
            note.contents = "nota de teste"
            p.addAnnotation(note)
        }
        let out = dir.appendingPathComponent("s2-src-nav10.pdf")
        guard doc.write(to: out) else { throw SpikeError("S2: não gravou \(out.path)") }
        return out
    }

    // MARK: Caixas

    static let W = Gen.a4.width, H = Gen.a4.height
    static var window: CGSize { MiniPage.fullPortrait }

    struct Scenario {
        var name: String
        var boxes: [String: CGRect]          // por chave: MediaBox, CropBox, TrimBox, BleedBox, ArtBox
        var media: CGRect { boxes["MediaBox"]! }
        var crop: CGRect { boxes["CropBox"]! }
        /// Translação esperada se o PDFKit levar a origem da MediaBox para (0,0).
        var shift: CGPoint { CGPoint(x: -media.minX, y: -media.minY) }
    }

    static func uniform(_ name: String, media: CGRect, box: CGRect) -> Scenario {
        Scenario(name: name, boxes: ["MediaBox": media, "CropBox": box, "TrimBox": box, "BleedBox": box, "ArtBox": box])
    }

    static func scenarios() -> [Scenario] {
        let w = window
        let o = CGPoint(x: 50, y: 100)
        return [
            uniform("A1 todas = janela, origem (0,0)", media: CGRect(origin: .zero, size: w), box: CGRect(origin: .zero, size: w)),
            uniform("A2 todas = janela, origem (50,100)", media: CGRect(origin: o, size: w), box: CGRect(origin: o, size: w)),
            uniform("A3 MediaBox maior (−50,−50, A4+100), demais = janela (50,100)",
                    media: CGRect(x: -50, y: -50, width: W + 100, height: H + 100), box: CGRect(origin: o, size: w)),
            Scenario(name: "A4 MediaBox = A4; Crop (50,100); Trim/Bleed/Art diferentes entre si",
                     boxes: ["MediaBox": CGRect(x: 0, y: 0, width: W, height: H),
                             "CropBox": CGRect(origin: o, size: w),
                             "TrimBox": CGRect(x: 60, y: 110, width: w.width - 20, height: w.height - 20),
                             "BleedBox": CGRect(x: 40, y: 90, width: w.width + 20, height: w.height + 20),
                             "ArtBox": CGRect(x: 70, y: 120, width: w.width - 40, height: w.height - 40)]),
        ]
    }

    static func setBoxes(_ page: PDFPage, _ sc: Scenario) {
        page.setBounds(sc.media, for: .mediaBox)
        for bx in boxNames where bx.key != "MediaBox" { page.setBounds(sc.boxes[bx.key]!, for: bx.pdfkit) }
    }

    static func setUniform(_ page: PDFPage, _ r: CGRect) {
        setBoxes(page, uniform("", media: r, box: r))
    }

    struct BoxCheck {
        var label: String
        var expected: CGRect
        var rebased: CGRect
        var raw0: CGRect?
        var cg0: CGRect
        var pk0: CGRect
        var rawOK = 0, cgOK = 0, pkOK = 0, n = 0
        var rawRB = 0, cgRB = 0, pkRB = 0
    }

    /// Reabre com CGPDF (cru e getBoxRect) e PDFKit e confere as 5 caixas de cada página.
    static func checkBoxes(_ url: URL, _ sc: Scenario) throws -> [BoxCheck] {
        guard let cg = CGPDFDocument(url as CFURL), let pk = PDFDocument(url: url) else { throw SpikeError("reabertura falhou: \(url.path)") }
        var out: [BoxCheck] = []
        for bx in boxNames {
            let exp = sc.boxes[bx.key]!
            let rb = exp.offsetBy(dx: sc.shift.x, dy: sc.shift.y)
            var c = BoxCheck(label: bx.label, expected: exp, rebased: rb, raw0: nil, cg0: .zero, pk0: .zero)
            for i in 0..<pk.pageCount {
                guard let cgp = cg.page(at: i + 1), let pkp = pk.page(at: i) else { continue }
                let raw = cgp.rawBox(bx.key), got = cgp.getBoxRect(bx.cg), pb = pkp.bounds(for: bx.pdfkit)
                if i == 0 { c.raw0 = raw; c.cg0 = got; c.pk0 = pb }
                c.n += 1
                if close(raw, exp) { c.rawOK += 1 }
                if close(got, exp) { c.cgOK += 1 }
                if close(pb, exp) { c.pkOK += 1 }
                if close(raw, rb) { c.rawRB += 1 }
                if close(got, rb) { c.cgRB += 1 }
                if close(pb, rb) { c.pkRB += 1 }
            }
            out.append(c)
        }
        return out
    }

    // MARK: Execução

    static func run(dir: URL) throws -> SpikeResult {
        let navURL = try makeNavDocument(dir: dir)
        let imgURL = dir.appendingPathComponent("s2-src-img5.pdf")
        try Gen.makeImageDocument(at: imgURL, pages: 5)
        let sources: [(name: String, url: URL, kind: Gen.Kind)] = [("nav10 (sumário, links, anotações)", navURL, .text), ("img5 (imagem grande)", imgURL, .image)]

        var md = Markdown()
        var summary: [String] = []
        md.heading(2, "S2 — PDFKit com caixas")

        // Origens
        guard let navDoc = PDFDocument(url: navURL) else { throw SpikeError("S2: nav não abriu") }
        let navInv = inventory(navDoc)
        md.heading(3, "Entradas")
        var srcRows: [[String]] = []
        for s in sources {
            let d = try Data(contentsOf: s.url, options: .mappedIfSafe)
            let c = ObjectCounts(d)
            srcRows.append([s.name, fmtMB(d.count), "\(PDFDocument(url: s.url)?.pageCount ?? 0)", "\(c.streams)", "\(c.images)", "\(c.dct)/\(c.flate)"])
        }
        md.table(["documento", "tamanho", "págs.", "streams", "imagens", "DCT/Flate"], srcRows)
        md.para("`nav10` relido do disco após gravar com PDFKit: sumário \(navInv.outline.count) entradas (nível 0: \(navInv.outline.filter { $0.level == 0 }.count)), links \(navInv.linkCount) (internos \(navInv.internalLinks), externos \(navInv.externalLinks)), realces \(navInv.annots("Highlight")), notas \(navInv.annots("Text")), popups \(navInv.annots("Popup")).")

        // Caso A
        md.heading(3, "Caso A — alterar as 5 caixas em lugar (`setBounds`) e gravar")
        var sizeRows: [[String]] = []
        var cmpRows: [[String]] = []
        var allBoxesOK = true, allRawOK = true, allRebasedOK = true
        var worstRatioA = 0.0
        var boxTables: [(String, [BoxCheck])] = []
        var allCmpOK = true
        for s in sources {
            let srcSize = fileSize(s.url)
            let baseInv = s.url == navURL ? navInv : inventory(PDFDocument(url: s.url)!)
            for (si, sc) in scenarios().enumerated() {
                guard let doc = PDFDocument(url: s.url) else { continue }
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { setBoxes(p, sc) } }
                let out = dir.appendingPathComponent("s2-A\(si + 1)-\(s.url == navURL ? "nav10" : "img5").pdf")
                let t0 = now()
                guard doc.write(to: out) else { throw SpikeError("write falhou \(out.path)") }
                let dt = now() - t0
                let rep = doc.dataRepresentation()?.count ?? 0
                let ratio = Double(fileSize(out)) / Double(srcSize)
                worstRatioA = max(worstRatioA, ratio)
                sizeRows.append([s.name, sc.name, fmtMB(srcSize), fmtMB(fileSize(out)), fmt(ratio, 3) + "×", fmtMB(rep), fmt(dt, 2)])
                let checks = try checkBoxes(out, sc)
                boxTables.append(("\(s.name) — \(sc.name)", checks))
                if !checks.allSatisfy({ $0.cgOK == $0.n && $0.pkOK == $0.n }) { allBoxesOK = false }
                if !checks.allSatisfy({ $0.rawOK == $0.n }) { allRawOK = false }
                if !checks.allSatisfy({ $0.cgRB == $0.n && $0.pkRB == $0.n }) { allRebasedOK = false }
                let outInv = inventory(PDFDocument(url: out)!)
                let spec = CompareSpec(k: 1, kind: s.kind, shift: { _ in sc.shift }, region: { _ in sc.crop.minY...sc.crop.maxY })
                let cmp = compare(base: baseInv, out: outInv, spec: spec)
                cmpRows.append(compareRow("\(s.name) — \(sc.name)", cmp, copies: false))
                if !(cmp.text.ok == cmp.text.total && cmp.links.ok == cmp.links.total && cmp.annots.ok == cmp.annots.total
                     && cmp.outlineCount.base == cmp.outlineCount.out && cmp.outlineDest.ok == cmp.outlineDest.total) { allCmpOK = false }
            }
        }
        md.para("Tamanho (arquivo gravado com `write(to:)` vs. origem; `dataRepresentation()` para conferir que dá o mesmo):")
        md.table(["documento", "cenário", "origem", "saída", "saída/origem", "dataRepresentation", "s"], sizeRows)
        md.para("Caixas reabertas. \"cru\" = valor no dicionário da página lido com CGPDF; \"CG\" = `CGPDFPageGetBoxRect`; \"PDFKit\" = `bounds(for:)`. Valores da página 1. \"cru\" ausente = chave não gravada (o leitor herda/usa o padrão). \"pedido rebaseado\" = pedido transladado de −origem da MediaBox pedida (hipótese: o PDFKit leva a origem da MediaBox para (0,0)). Contagens = páginas que batem (tol. 0,01 pt).")
        for (title, checks) in boxTables {
            md.para("**\(title)**")
            md.table(["caixa", "pedido", "pedido − origem da MediaBox", "cru (p.1)", "CG (p.1)", "PDFKit (p.1)", "= pedido: cru/CG/PDFKit", "= pedido rebaseado: cru/CG/PDFKit"],
                     checks.map { [$0.label, fmtRect($0.expected), fmtRect($0.rebased), fmtRect($0.raw0), fmtRect($0.cg0), fmtRect($0.pk0),
                                   "\($0.rawOK)/\($0.cgOK)/\($0.pkOK) de \($0.n)", "\($0.rawRB)/\($0.cgRB)/\($0.pkRB) de \($0.n)"] })
        }
        md.para("Preservação após a gravação (páginas cujo texto extraído = linhas da janela pedida [núcleo ⊆ extraído ⊆ núcleo + linhas de borda], páginas com links iguais — retângulo transladado como as caixas, destino e URL —, páginas com anotações iguais — tipos e conteúdo —, entradas do sumário saída/origem, destinos do sumário corretos):")
        md.table(["documento — cenário", "texto", "links", "anotações", "sumário (saída/origem)", "destinos do sumário"], cmpRows)

        // O content stream muda quando a origem da MediaBox muda?
        var contentRows: [[String]] = []
        var contentLens: [String: Int] = [:]
        for (label, url) in [("origem", navURL)] + (1...4).map({ ("A\($0)", dir.appendingPathComponent("s2-A\($0)-nav10.pdf")) }) {
            guard let pg = CGPDFDocument(url as CFURL)?.page(at: 1) else { continue }
            let d = pg.contentData()
            let head = String(decoding: d.prefix(60), as: UTF8.self).replacingOccurrences(of: "\n", with: " ⏎ ")
            contentLens[label] = d.count
            contentRows.append([label, "\(d.count)", "`\(cell(head))`"])
        }
        md.para("Content stream da página 1 (nav10) decodificado, antes e depois (o PDFKit toca no conteúdo ao mudar a origem da MediaBox?):")
        md.table(["arquivo", "bytes decodificados", "início"], contentRows)

        // Rotação
        let rot = try rotationTest(dir: dir)
        md.heading(3, "Caso A (rotação) — página com /Rotate 90")
        md.table(["passo", "valor"], rot.rows.map { [$0.0, $0.1] })
        md.para(rot.conclusion)

        // Caso B
        md.heading(3, "Caso B — páginas copiadas (`page.copy()`), k = 2 e 3, caixas diferentes (fatias horizontais)")
        var bSize: [[String]] = []
        var bCmp: [[String]] = []
        var bRatios: [(String, Int, Double)] = []
        for s in sources {
            let srcSize = fileSize(s.url)
            let srcData = try Data(contentsOf: s.url, options: .mappedIfSafe)
            let srcCounts = ObjectCounts(srcData)
            let baseInv = s.url == navURL ? navInv : inventory(PDFDocument(url: s.url)!)
            for k in [2, 3] {
                guard let doc = PDFDocument(url: s.url) else { continue }
                let n = doc.pageCount
                for i in stride(from: n - 1, through: 0, by: -1) {
                    guard let page = doc.page(at: i) else { continue }
                    var copies: [PDFPage] = [page]
                    for _ in 1..<k { if let c = page.copy() as? PDFPage { copies.append(c) } }
                    for c in 1..<k { doc.insert(copies[c], at: i + c) }
                    for c in 0..<k {
                        let h = H / CGFloat(k)
                        let r = CGRect(x: 0, y: H - CGFloat(c + 1) * h, width: W, height: h)
                        setUniform(copies[c], r)
                    }
                }
                let out = dir.appendingPathComponent("s2-B-\(s.url == navURL ? "nav10" : "img5")-k\(k).pdf")
                guard doc.write(to: out) else { throw SpikeError("write falhou \(out.path)") }
                let data = try Data(contentsOf: out, options: .mappedIfSafe)
                let c = ObjectCounts(data)
                let ratio = Double(data.count) / Double(srcSize)
                bRatios.append((s.name, k, ratio))
                bSize.append([s.name, "\(k)", "\(doc.pageCount)", fmtMB(srcSize), fmtMB(data.count), fmt(ratio, 2) + "×",
                              "\(c.streams) (origem \(srcCounts.streams))", "\(c.images) (origem \(srcCounts.images))", "\(c.objects) (origem \(srcCounts.objects))"])
                let outInv = inventory(PDFDocument(url: out)!)
                bCmp.append(compareRow("\(s.name) k=\(k)", compare(base: baseInv, out: outInv, spec: CompareSpec(
                    k: k, kind: s.kind,
                    shift: { q in CGPoint(x: 0, y: -(H - CGFloat(q % k + 1) * H / CGFloat(k))) },
                    region: { q in let h = H / CGFloat(k); let y0 = H - CGFloat(q % k + 1) * h; return y0...(y0 + h) })), copies: true))
            }
        }
        md.table(["documento", "k", "págs. saída", "origem", "saída", "saída/origem", "streams", "imagens", "objetos"], bSize)
        md.para("Comparação página a página (saída q ↔ origem q/k; destinos × k). Colunas \"cópias\" consideram só as páginas inseridas (c > 0).")
        md.table(["documento — k", "texto", "links", "anotações", "sumário (saída/origem)", "destinos do sumário", "texto (cópias)", "links (cópias)", "anotações (cópias)"], bCmp)

        // Caso C
        md.heading(3, "Caso C — opções de escrita do PDFKit")
        let cRows = try caseC(dir: dir, imgURL: imgURL, navURL: navURL, navInv: navInv)
        md.table(["documento", "opção", "gravou", "tamanho", "saída/origem", "imagens (largura px; px/pt com a imagem a 500 pt)", "DCT/Flate", "texto igual", "anotações (tipos)", "s"], cRows.rows)
        md.para(cRows.notes)

        // Veredito
        md.heading(3, "Veredito S2")
        let bNav = bRatios.filter { $0.0.hasPrefix("nav") }
        let bImg = bRatios.filter { $0.0.hasPrefix("img") }
        let dupImg = bImg.contains { $0.2 > 1.3 }
        md.bullets([
            "**Caso A (caminho do M1)**: 5 caixas por `setBounds` + `write(to:)` nos 4 cenários. Caixas gravadas exatamente como pedidas (CG e PDFKit, todas as páginas): \(allBoxesOK ? "SIM" : "NÃO"); valor cru presente e igual ao pedido: \(allRawOK ? "SIM" : "NÃO"); iguais ao pedido rebaseado pela origem da MediaBox: \(allRebasedOK ? "SIM" : "NÃO"). Texto da janela, links (com a mesma translação), anotações e sumário preservados: \(allCmpOK ? "SIM" : "NÃO, ver tabela"). Maior razão saída/origem: \(fmt(worstRatioA, 3))× (meta: ≤ 1,1× em vetor).",
            "**Origem da MediaBox**: o PDFKit grava a MediaBox sempre com origem (0,0) e translada junto as demais caixas, o conteúdo e as anotações (ver cenários A2/A3 e a tabela de preservação). O resultado visual confere (texto da janela e links com a mesma translação); por isso \"pedido\" ≠ \"gravado\" nas coordenadas, mas \"pedido rebaseado\" = gravado: \(allRebasedOK ? "SIM em todos os cenários" : "NÃO em algum cenário").",
            "**TrimBox/BleedBox/ArtBox**: nos cenários em que valem o mesmo que a CropBox/MediaBox (A1–A3) a chave não é gravada (\"cru\" ausente; leitores caem no padrão = CropBox); quando diferem (A4) são gravadas com o valor pedido.",
            "**Content stream**: não é preservado byte a byte. p.1 de nav10 decodificada: origem \(contentLens["origem"] ?? 0) B; A1 \(contentLens["A1"] ?? 0) B (só o retângulo do clip inicial muda para o tamanho da nova MediaBox); A2 \(contentLens["A2"] ?? 0) B e A3 \(contentLens["A3"] ?? 0) B (origem da MediaBox ≠ 0: o PDFKit envolve o conteúdo em `q 1 0 0 1 dx dy cm`); A4 \(contentLens["A4"] ?? 0) B (MediaBox intacta: idêntico). Só medido com PDFs gerados pelo Quartz; outros produtores não testados.",
            "**Caso B (cópias)**: razão saída/origem — " + (bNav + bImg).map { "\($0.0.prefix(5)) k=\($0.1): \(fmt($0.2, 2))×" }.joined(separator: "; ") + ". Duplicação do conteúdo (imagem grande > 1,3×): \(dupImg ? "SIM" : "NÃO").",
            "**Rotação**: " + rot.conclusion,
        ])
        summary.append("S2 caso A: caixas ok=\(allBoxesOK), preservação ok=\(allCmpOK), maior razão \(fmt(worstRatioA, 3))×")
        summary.append("  S2 caso B: " + (bNav + bImg).map { "\($0.0.prefix(5)) k=\($0.1) \(fmt($0.2, 2))×" }.joined(separator: "; "))
        summary.append("  S2 rotação: " + rot.conclusion)
        summary.append("  S2 caso C: " + cRows.rows.map { "\($0[1]) \($0[4])" }.joined(separator: "; "))
        return SpikeResult(markdown: md.text, summary: summary)
    }

    // MARK: Rotação

    static func rotationTest(dir: URL) throws -> (rows: [(String, String)], conclusion: String) {
        let base0 = dir.appendingPathComponent("s2-src-rot0.pdf")
        try Gen.makeTextDocument(at: base0, pages: 1)
        guard let d0 = PDFDocument(url: base0), let p0 = d0.page(at: 0) else { throw SpikeError("S2: rot base") }
        p0.rotation = 90
        let src = dir.appendingPathComponent("s2-src-rot90.pdf")
        guard d0.write(to: src) else { throw SpikeError("S2: rot write") }

        var rows: [(String, String)] = []
        let R = CGRect(x: 10, y: 20, width: 300, height: 400)
        guard let before = PDFDocument(url: src), let bp = before.page(at: 0), let bcg = CGPDFDocument(src as CFURL)?.page(at: 1) else { throw SpikeError("S2: rot reabrir") }
        rows.append(("origem: /Rotate cru; PDFKit rotation", "\(bcg.rawRotate.map(String.init) ?? "ausente"); \(bp.rotation)"))
        rows.append(("origem: MediaBox cru / PDFKit mediaBox / PDFKit cropBox", "\(fmtRect(bcg.rawBox("MediaBox"))) / \(fmtRect(bp.bounds(for: .mediaBox))) / \(fmtRect(bp.bounds(for: .cropBox)))"))

        // setBounds de R nas 5 caixas (sem trocar o MediaBox de lugar: R cabe dentro dele)
        bp.setBounds(R, for: .cropBox)
        rows.append(("após setBounds(R, .cropBox), antes de gravar: PDFKit cropBox", fmtRect(bp.bounds(for: .cropBox))))
        let out = dir.appendingPathComponent("s2-A-rot90.pdf")
        guard before.write(to: out) else { throw SpikeError("S2: rot write 2") }
        guard let cg = CGPDFDocument(out as CFURL)?.page(at: 1), let pk = PDFDocument(url: out)?.page(at: 0) else { throw SpikeError("S2: rot reabrir 2") }
        let raw = cg.rawBox("CropBox")
        rows.append(("R gravado (espaço pedido)", fmtRect(R)))
        rows.append(("depois de gravar: CropBox cru", fmtRect(raw)))
        rows.append(("depois de gravar: CGPDF getBoxRect(.cropBox)", fmtRect(cg.getBoxRect(.cropBox))))
        rows.append(("depois de gravar: PDFKit bounds(.cropBox)", fmtRect(pk.bounds(for: .cropBox))))
        rows.append(("depois de gravar: /Rotate cru; PDFKit rotation", "\(cg.rawRotate.map(String.init) ?? "ausente"); \(pk.rotation)"))

        // Se PDFKit trabalhasse no espaço rotacionado, o cru seria R levado ao espaço do usuário.
        let geo = PageGeometry(effectiveBox: CGRect(x: 0, y: 0, width: W, height: H), rotation: 90)
        let ifRotated = geo.toUser(R)
        rows.append(("cru esperado se o espaço fosse o rotacionado (PageGeometry)", fmtRect(ifRotated)))
        let conclusion: String
        if close(raw, R) {
            conclusion = "`setBounds` grava o retângulo como dado, no espaço do usuário (sem rotação): CropBox cru = R; o /Rotate 90 é preservado. O app deve converter do espaço de página para o do usuário (`PageGeometry.toUser`) antes de chamar `setBounds`."
        } else if close(raw, ifRotated) {
            conclusion = "`setBounds` trabalha no espaço rotacionado: o CropBox cru é R transformado pela rotação."
        } else {
            conclusion = "Resultado inesperado: CropBox cru = \(fmtRect(raw)), nem R nem R rotacionado."
        }
        return (rows, conclusion)
    }

    // MARK: Caso C

    static func caseC(dir: URL, imgURL: URL, navURL: URL, navInv: Inv) throws -> (rows: [[String]], notes: String) {
        typealias Opts = [PDFDocumentWriteOption: Any]
        let cases: [(String, URL, String, Opts)] = [
            ("img5", imgURL, "(sem opções)", [:]),
            ("img5", imgURL, "saveImagesAsJPEGOption", [.saveImagesAsJPEGOption: true]),
            ("img5", imgURL, "optimizeImagesForScreenOption", [.optimizeImagesForScreenOption: true]),
            ("img5", imgURL, "JPEG + optimizeForScreen", [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]),
            ("img5", imgURL, "burnInAnnotationsOption", [.burnInAnnotationsOption: true]),
            ("nav10", navURL, "(sem opções)", [:]),
            ("nav10", navURL, "burnInAnnotationsOption", [.burnInAnnotationsOption: true]),
        ]
        var rows: [[String]] = []
        var textBroken: [String] = []
        for (i, c) in cases.enumerated() {
            guard let doc = PDFDocument(url: c.1) else { continue }
            let srcSize = fileSize(c.1)
            let baseInv = c.1 == navURL ? navInv : inventory(PDFDocument(url: imgURL)!)
            let out = dir.appendingPathComponent("s2-C\(i + 1)-\(c.0).pdf")
            let t0 = now()
            let ok = doc.write(to: out, withOptions: c.3)
            let dt = now() - t0
            guard ok, let data = try? Data(contentsOf: out, options: .mappedIfSafe) else {
                rows.append([c.0, c.2, "NÃO", "-", "-", "-", "-", "-", "-", fmt(dt, 1)])
                continue
            }
            let counts = ObjectCounts(data)
            let inv = inventory(PDFDocument(url: out)!)
            let textOK = inv.pages.count == baseInv.pages.count && zip(inv.pages, baseInv.pages).allSatisfy { $0.text == $1.text }
            if !textOK { textBroken.append("\(c.0) \(c.2)") }
            let types = inv.pages.reduce(into: [String: Int]()) { acc, p in for (k, v) in p.annotTypes { acc[k, default: 0] += v } }
            let typeStr = types.isEmpty ? "nenhuma" : types.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            rows.append([c.0, c.2, "sim", fmtMB(data.count), fmt(Double(data.count) / Double(srcSize), 3) + "×",
                         c.0 == "img5" ? Array(Set(imageWidths(in: data))).sorted().map { "\($0) (\(fmt(Double($0) / 500, 1)) px/pt)" }.joined(separator: ", ") + " ×\(imageWidths(in: data).count)" : "-",
                         "\(counts.dct)/\(counts.flate)", textOK ? "sim" : "NÃO", typeStr, fmt(dt, 1)])
        }
        let notes = "Opções disponíveis no SDK: `saveImagesAsJPEGOption`, `optimizeImagesForScreenOption`, `burnInAnnotationsOption` (as três compilaram). `burnInAnnotationsOption` só registrada: a coluna de anotações mostra se os objetos de anotação sobrevivem ou foram achatados no conteúdo. Texto quebrado em: \(textBroken.isEmpty ? "nenhum caso" : textBroken.joined(separator: "; "))."
        return (rows, notes)
    }
}
