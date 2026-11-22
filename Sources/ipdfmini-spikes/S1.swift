import Foundation
import CoreGraphics
import PDFKit

/// S1 — Quartz como backend de colocações.
enum S1 {
    struct Source {
        let name: String
        let url: URL
        let pages: Int
        let kind: Gen.Kind
    }

    struct Row {
        var doc: String
        var variant: String
        var k: Int
        var outPages: Int
        var outSize: Int
        var ratio: Double
        var counts: ObjectCounts
        var selectableOK: Int
        var selectableTotal: Int
        var dupMax: Int
        var extractedTokens: Int
        var visibleTokens: Int
        var seconds: Double
        var passes: Bool { ratio <= 1.3 && selectableOK == selectableTotal }
    }

    static func run(dir: URL) throws -> SpikeResult {
        var sources: [Source] = []
        let textURL = dir.appendingPathComponent("s1-src-text20.pdf")
        try Gen.makeTextDocument(at: textURL, pages: 20)
        sources.append(Source(name: "texto 20 p.", url: textURL, pages: 20, kind: .text))
        let imgURL = dir.appendingPathComponent("s1-src-img5.pdf")
        try Gen.makeImageDocument(at: imgURL, pages: 5)
        sources.append(Source(name: "imagem 5 p.", url: imgURL, pages: 5, kind: .image))

        var md = Markdown()
        md.heading(2, "S1 — Quartz como backend de colocações")
        md.para("Cada página de origem vira k fatias horizontais (clip + translação via `drawPDFPage`). Variante **páginas**: k páginas de saída de A4/k de altura. Variante **mesma página**: as k fatias lado a lado numa única página de saída (largura k·A4). Entradas e saídas em `s1-*.pdf` no diretório de resultados.")

        var rows: [Row] = []
        var srcInfo: [[String]] = []
        for src in sources {
            let data = try Data(contentsOf: src.url, options: .mappedIfSafe)
            let c = ObjectCounts(data)
            srcInfo.append([src.name, fmtMB(data.count), "\(c.xobjects)", "\(c.forms)", "\(c.images)", "\(c.streams)", "\(c.objects)",
                            "\(c.dct)/\(c.flate)"])
            for k in 1...3 {
                for same in [false, true] {
                    let tag = same ? "same" : "pages"
                    let out = dir.appendingPathComponent("s1-out-\(src.kind == .text ? "text" : "img")-k\(k)-\(tag).pdf")
                    let t0 = now()
                    try slice(source: src.url, to: out, k: k, samePage: same)
                    let dt = now() - t0
                    rows.append(try measure(src: src, out: out, k: k, same: same, seconds: dt))
                }
            }
        }

        md.heading(3, "Origens")
        md.table(["doc", "tamanho", "/Type /XObject", "/Subtype /Form", "/Subtype /Image", "streams", "objetos", "DCT/Flate"], srcInfo)

        md.heading(3, "Saídas")
        md.table(["doc", "variante", "k", "págs. saída", "tamanho", "saída/origem", "XObject", "Form", "Image", "streams", "objetos",
                  "texto ok (págs.)", "dup. máx. de linha", "linhas extraídas / visíveis", "s"],
                 rows.map { r in
                    [r.doc, r.variant, "\(r.k)", "\(r.outPages)", fmtMB(r.outSize), fmt(r.ratio) + "×",
                     "\(r.counts.xobjects)", "\(r.counts.forms)", "\(r.counts.images)", "\(r.counts.streams)", "\(r.counts.objects)",
                     "\(r.selectableOK)/\(r.selectableTotal)", "\(r.dupMax)",
                     "\(r.extractedTokens) / \(r.visibleTokens) (\(fmt(Double(r.extractedTokens) / Double(max(r.visibleTokens, 1))))×)",
                     fmt(r.seconds, 1)]
                 })
        md.para("\"texto ok\": página de saída que contém os marcadores `PxxLyy` de todas as linhas visíveis na fatia. \"dup. máx.\": maior número de ocorrências de um mesmo marcador na extração de uma página de saída. \"extraídas / visíveis\": marcadores extraídos somados sobre os visíveis (clip respeitado); >1× indica que a extração do PDFKit ignora o clip.")

        // Custo marginal de uma fatia extra, em fração da origem.
        var marg: [String] = []
        for src in sources {
            for same in [false, true] {
                let v = same ? "mesma página" : "páginas"
                if let r1 = rows.first(where: { $0.doc == src.name && $0.variant == v && $0.k == 1 }),
                   let r3 = rows.first(where: { $0.doc == src.name && $0.variant == v && $0.k == 3 }) {
                    marg.append("\(src.name) / \(v): +\(fmt(Double(r3.outSize - r1.outSize) / 2 / Double(fileSize(src.url)), 3))× da origem por fatia extra")
                }
            }
        }
        md.para("Custo marginal por fatia extra ((k=3 − k=1) / 2): " + marg.joined(separator: "; ") + ". Linhas \"duplicadas\" na extração (extraídas − visíveis, k=3): " + rows.filter { $0.k == 3 }.map { "\($0.doc)/\($0.variant) = \($0.extractedTokens - $0.visibleTokens)" }.joined(separator: "; ") + " (linha cortada na fronteira entre fatias aparece nas duas).")

        // Veredito: k = 3, ambas as variantes e ambos os documentos.
        let k3 = rows.filter { $0.k == 3 }
        let allPass = k3.allSatisfy(\.passes)
        md.heading(3, "Veredito S1")
        md.table(["doc", "variante", "k=3 saída/origem", "≤ 1,3×", "texto selecionável", "resultado"],
                 k3.map { r in
                    [r.doc, r.variant, fmt(r.ratio) + "×", r.ratio <= 1.3 ? "sim" : "não",
                     r.selectableOK == r.selectableTotal ? "sim" : "não (\(r.selectableOK)/\(r.selectableTotal))",
                     r.passes ? "PASSA" : "REPROVA"]
                 })
        md.para(allPass
                ? "**S1 PASSA**: Quartz atende o critério (≤ 1,3× e texto selecionável com 3 fatias por página) em todos os casos medidos."
                : "**S1 REPROVA** em pelo menos um caso: pelo critério de aceite, qpdf é o padrão para o `PlacementWriter`.")

        var summary = ["S1 " + (allPass ? "PASSA" : "REPROVA")]
        for r in k3 { summary.append("  S1 \(r.doc) / \(r.variant) k=3: \(fmt(r.ratio))× | texto ok \(r.selectableOK)/\(r.selectableTotal) | dup máx \(r.dupMax)") }
        return SpikeResult(markdown: md.text, summary: summary)
    }

    // MARK: Geração

    static func slice(source: URL, to out: URL, k: Int, samePage: Bool) throws {
        guard let src = CGPDFDocument(source as CFURL) else { throw SpikeError("CGPDFDocument falhou: \(source.path)") }
        let aux = [kCGPDFContextCreator as String: "ipdfmini-spikes"] as CFDictionary
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, aux) else { throw SpikeError("CGContext falhou: \(out.path)") }

        func begin(_ size: CGSize) {
            let mb = CGRect(origin: .zero, size: size)
            let d = withUnsafeBytes(of: mb) { Data($0) }
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: d] as CFDictionary)
        }

        for i in 1...src.numberOfPages {
            guard let page = src.page(at: i) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let sh = box.height / CGFloat(k)
            if samePage { begin(CGSize(width: box.width * CGFloat(k), height: sh)) }
            for j in 0..<k {
                if !samePage { begin(CGSize(width: box.width, height: sh)) }
                let xOff = samePage ? CGFloat(j) * box.width : 0
                let y0 = box.height - CGFloat(j + 1) * sh     // base da fatia j na origem (topo primeiro)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: xOff, y: 0, width: box.width, height: sh))
                ctx.translateBy(x: xOff - box.minX, y: -y0 - box.minY)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
                if !samePage { ctx.endPDFPage() }
            }
            if samePage { ctx.endPDFPage() }
        }
        ctx.closePDF()
    }

    // MARK: Medição

    static func measure(src: Source, out: URL, k: Int, same: Bool, seconds: Double) throws -> Row {
        let data = try Data(contentsOf: out, options: .mappedIfSafe)
        let srcSize = fileSize(src.url)
        guard let doc = PDFDocument(data: data) else { throw SpikeError("PDFDocument não abriu \(out.path)") }
        let H = Gen.a4.height
        let ys = Gen.baselines(src.kind, pageHeight: H)
        let sh = H / CGFloat(k)

        var ok = 0, dupMax = 0, extracted = 0, visible = 0
        for p in 0..<doc.pageCount {
            let srcPage = same ? p : p / k
            let j = p % k
            var want: [String] = []
            for (l, y) in ys.enumerated() {
                let y0 = H - CGFloat(j + 1) * sh
                if same || (y >= y0 && y < y0 + sh) { want.append(Gen.token(srcPage, l)) }
            }
            let s = doc.page(at: p)?.string ?? ""
            let got = tokens(in: s)
            let set = Set(got)
            var freq: [String: Int] = [:]
            for t in got { freq[t, default: 0] += 1 }
            dupMax = max(dupMax, freq.values.max() ?? 0)
            extracted += got.count
            visible += want.count
            if want.allSatisfy(set.contains) { ok += 1 }   // fatia sem linhas visíveis: nada a exigir
        }
        return Row(doc: src.name, variant: same ? "mesma página" : "páginas", k: k, outPages: doc.pageCount,
                   outSize: data.count, ratio: Double(data.count) / Double(srcSize), counts: ObjectCounts(data),
                   selectableOK: ok, selectableTotal: doc.pageCount, dupMax: dupMax,
                   extractedTokens: extracted, visibleTokens: visible, seconds: seconds)
    }
}
