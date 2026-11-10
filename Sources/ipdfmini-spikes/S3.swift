import Foundation
import CoreGraphics
import CoreText
import PDFKit
import AppKit

/// S3 — Fonte da altura-x em PDF digital (PLAN.md §5.5).
enum S3 {
    struct FontCase { let name: String; let tag: String }

    /// Classes de glifo da linha de teste.
    enum GlyphClass: String, CaseIterable {
        case xheight = "sem ascendente/descendente (xzaenos)"
        case ascender = "com ascendente (bdfhklt)"
        case descender = "com descendente (gjpqy)"
        case caps = "maiúsculas (AHEZ)"
        case digit = "dígitos (0123)"
        case label = "rótulo (ex. TNR08)"
    }

    /// Geometria conhecida de um caractere.
    struct Truth {
        var ch: Character
        var utf16Index: Int          // posição dentro da linha
        var ink: CGRect              // caixa de tinta (contorno do glifo)
        var typo: CGRect             // avanço × (ascent + descent)
        var fontBox: CGRect          // avanço × caixa do bbox da fonte
        var cls: GlyphClass
    }

    struct LineTruth {
        var tag: String              // rótulo único, ex. "TNR08"
        var text: String
        var fontName: String         // nome PostScript real
        var size: CGFloat
        var origin: CGPoint
        var chars: [Truth]
        var inkUnion: CGRect
        var typoLine: CGRect
        var xHeightMetric: CGFloat   // CTFontGetXHeight
        var xInk: CGFloat            // altura de tinta do glifo "x"
        var glyphCountMatches: Bool
    }

    struct Stat {
        var errs: [CGFloat] = []      // erro médio das 4 bordas por caractere
        var maxEdge: CGFloat = 0
        var edgeSum: [CGFloat] = [0, 0, 0, 0]   // esq, dir, base, topo
        var signed: [CGFloat] = [0, 0, 0, 0]    // a − b, com sinal
        var n = 0
        mutating func add(_ a: CGRect, _ b: CGRect) {
            let d = [abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)]
            errs.append(d.reduce(0, +) / 4)
            maxEdge = max(maxEdge, d.max() ?? 0)
            for i in 0..<4 { edgeSum[i] += d[i] }
            let sg = [a.minX - b.minX, a.maxX - b.maxX, a.minY - b.minY, a.maxY - b.maxY]
            for i in 0..<4 { signed[i] += sg[i] }
            n += 1
        }
        var mean: CGFloat { errs.isEmpty ? 0 : errs.reduce(0, +) / CGFloat(errs.count) }
        func edge(_ i: Int) -> CGFloat { n == 0 ? 0 : edgeSum[i] / CGFloat(n) }
        func sedge(_ i: Int) -> CGFloat { n == 0 ? 0 : signed[i] / CGFloat(n) }
    }

    static let sample = "xzaenos bdfhklt gjpqy AHEZ 0123"

    static func classify(_ ch: Character, inLabel: Bool) -> GlyphClass {
        if inLabel { return .label }
        if "xzaenos".contains(ch) { return .xheight }
        if "bdfhklt".contains(ch) { return .ascender }
        if "gjpqy".contains(ch) { return .descender }
        if "AHEZ".contains(ch) { return .caps }
        return .digit
    }

    static func run(dir: URL) throws -> SpikeResult {
        let fonts = [FontCase(name: "Times New Roman", tag: "TNR"), FontCase(name: "Helvetica", tag: "HEL"), FontCase(name: "Menlo", tag: "MEN")]
        let sizes: [CGFloat] = [8, 10, 14]
        let pageSize = CGSize(width: 400, height: 420)
        let url = dir.appendingPathComponent("s3-fonts.pdf")

        // 1) Desenho + geometria conhecida
        var lines: [LineTruth] = []
        var y: CGFloat = pageSize.height - 40
        var plan: [(FontCase, CGFloat, CGFloat)] = []
        for f in fonts { for s in sizes { plan.append((f, s, y)); y -= 38 } }

        try Gen.writePDF(at: url, pages: 1, size: pageSize) { ctx, _ in
            for (f, s, yy) in plan {
                let font = CTFontCreateWithName(f.name as CFString, s, nil)
                let text = "\(f.tag)\(String(format: "%02d", Int(s))) \(sample)"
                Gen.drawLine(ctx, text, font: font, x: 40, y: yy)
                lines.append(truth(text: text, tag: "\(f.tag)\(String(format: "%02d", Int(s)))", font: font, size: s, origin: CGPoint(x: 40, y: yy)))
            }
        }

        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { throw SpikeError("S3: PDF não abriu") }
        let nsText = (page.string ?? "") as NSString
        let attr = page.attributedString
        let attrText = (attr?.string ?? "") as NSString

        var inkStat = Stat(), typoStat = Stat(), boxStat = Stat(), rawStat = Stat(), selChar = Stat()
        var perFont: [String: (ink: Stat, typo: Stat)] = [:]
        var heightByClass: [GlyphClass: [CGFloat]] = [:]
        var missing: [String] = []
        var charCount = 0
        var worst: (err: CGFloat, who: String) = (0, "-")
        var cbXHeight: [String: CGFloat] = [:]

        for ln in lines {
            let r = nsText.range(of: ln.text)
            guard r.location != NSNotFound else { missing.append(ln.tag); continue }
            for t in ln.chars where t.ch != " " {
                let idx = r.location + t.utf16Index
                // characterBounds não conta as quebras de linha da string: índice ajustado
                let nl = nsText.substring(to: idx).filter { $0 == "\n" }.count
                rawStat.add(page.characterBounds(at: idx), t.ink)
                if let sel = page.selection(for: NSRange(location: idx, length: 1)) { selChar.add(sel.bounds(for: page), t.ink) }
                let cb = page.characterBounds(at: idx - nl)
                inkStat.add(cb, t.ink)
                typoStat.add(cb, t.typo)
                boxStat.add(cb, t.fontBox)
                var pf = perFont[ln.fontName] ?? (Stat(), Stat())
                pf.ink.add(cb, t.ink); pf.typo.add(cb, t.typo)
                perFont[ln.fontName] = pf
                heightByClass[t.cls, default: []].append(cb.height / ln.size)
                charCount += 1
                let worstEdge = [abs(cb.minX - t.ink.minX), abs(cb.maxX - t.ink.maxX), abs(cb.minY - t.ink.minY), abs(cb.maxY - t.ink.maxY)].max() ?? 0
                if worstEdge > worst.err { worst = (worstEdge, "\(ln.tag) '\(t.ch)'") }
                if t.cls == .xheight, t.ch == "x" || t.ch == "z" { cbXHeight[ln.tag + String(t.ch), default: 0] = cb.height }
            }
        }

        // 2) selectionsByLine
        var selInk = Stat(), selTypo = Stat()
        var selFound = 0
        var selLines: [String] = []
        if let whole = page.selection(for: page.bounds(for: .mediaBox)) {
            let sels = whole.selectionsByLine()
            selLines = sels.compactMap { $0.string }
            for ln in lines {
                guard let s = sels.first(where: { ($0.string ?? "").contains(ln.tag) }) else { continue }
                let b = s.bounds(for: page)
                selInk.add(b, ln.inkUnion)
                selTypo.add(b, ln.typoLine)
                selFound += 1
            }
        }

        // 3) attributedString: fonte e tamanho
        struct AttrRow { var tag: String; var psTrue: String; var attrName: String; var attrSize: CGFloat; var size: CGFloat
            var derived: CGFloat; var nsXH: CGFloat; var metric: CGFloat; var ink: CGFloat }
        var attrRows: [AttrRow] = []
        if attr != nil {
            for ln in lines {
                let r = attrText.range(of: ln.text)
                guard r.location != NSNotFound else { continue }
                // posição do primeiro "x" da amostra (após o rótulo e o espaço)
                let loc = r.location + ln.tag.utf16.count + 1
                var eff = NSRange()
                guard let nsfont = attr?.attribute(.font, at: loc, effectiveRange: &eff) as? NSFont else { continue }
                let ctf = CTFontCreateWithName(nsfont.fontName as CFString, nsfont.pointSize, nil)
                attrRows.append(AttrRow(tag: ln.tag, psTrue: ln.fontName, attrName: nsfont.fontName, attrSize: nsfont.pointSize,
                                        size: ln.size, derived: CTFontGetXHeight(ctf), nsXH: nsfont.xHeight,
                                        metric: ln.xHeightMetric, ink: ln.xInk))
            }
        }

        // 4) Relatório
        var md = Markdown()
        md.heading(2, "S3 — Fonte da altura-x em PDF digital")
        md.para("Página \(Int(pageSize.width))×\(Int(pageSize.height)) pt, 9 linhas (3 fontes × 8/10/14 pt), amostra `\(sample)` precedida de rótulo único. Caractere a caractere: `PDFPage.characterBounds(at:)` contra (i) tinta exata do glifo (`CTFontGetBoundingRectsForGlyphs` + posição da linha + posição do glifo), (ii) caixa tipográfica (avanço × (ascent+descent) de `CTFont`), (iii) avanço × bbox global da fonte. Caracteres comparados: \(charCount) (espaços ignorados). Linhas não localizadas na extração: \(missing.isEmpty ? "nenhuma" : missing.joined(separator: ", ")). Glifos == caracteres (sem ligaduras) em todas as linhas: \(lines.allSatisfy(\.glyphCountMatches) ? "sim" : "não").")

        md.heading(3, "characterBounds contra a geometria conhecida (pt)")
        func row(_ name: String, _ s: Stat) -> [String] {
            [name, fmt(s.mean, 3), fmt(s.maxEdge, 3), fmt(s.edge(0), 3), fmt(s.edge(1), 3), fmt(s.edge(2), 3), fmt(s.edge(3), 3)]
        }
        md.table(["referência", "erro médio (4 bordas)", "erro máx. (uma borda)", "esq.", "dir.", "base", "topo"],
                 [row("tinta do glifo", inkStat), row("caixa tipográfica (asc/desc/avanço)", typoStat), row("avanço × bbox da fonte", boxStat)])

        md.table(["erro com sinal (characterBounds − referência), média", "esq.", "dir.", "base", "topo"],
                 [["tinta do glifo", fmt(inkStat.sedge(0), 3), fmt(inkStat.sedge(1), 3), fmt(inkStat.sedge(2), 3), fmt(inkStat.sedge(3), 3)],
                  ["caixa tipográfica", fmt(typoStat.sedge(0), 3), fmt(typoStat.sedge(1), 3), fmt(typoStat.sedge(2), 3), fmt(typoStat.sedge(3), 3)]])
        md.para("Pior caso contra a tinta: \(fmt(worst.err, 3)) pt em \(worst.who).")
        md.para("**Índice**: `characterBounds(at:)` não conta os `\\n` que `page.string` insere entre linhas (índice = índice da string − nº de quebras anteriores). Sem esse ajuste, erro médio contra a tinta: \(fmt(rawStat.mean, 3)) pt (máx. \(fmt(rawStat.maxEdge, 3)) pt). Os números da tabela acima usam o índice ajustado. Alternativa por índice da string: `page.selection(for: NSRange(loc, 1)).bounds(for:)` contra a tinta: erro médio \(fmt(selChar.mean, 3)) pt, máx. \(fmt(selChar.maxEdge, 3)) pt (\(selChar.n) caracteres).")

        md.heading(3, "Por fonte (erro médio, pt)")
        md.table(["fonte (PS)", "vs tinta", "vs tipográfica"],
                 perFont.keys.sorted().map { [$0, fmt(perFont[$0]!.ink.mean, 3), fmt(perFont[$0]!.typo.mean, 3)] })

        md.heading(3, "Altura de characterBounds por classe de glifo (altura / corpo, média)")
        md.table(["classe", "n", "altura/corpo médio", "mín.", "máx."],
                 GlyphClass.allCases.compactMap { c in
                    guard let v = heightByClass[c], !v.isEmpty else { return nil }
                    return [c.rawValue, "\(v.count)", fmt(v.reduce(0, +) / CGFloat(v.count), 3), fmt(v.min() ?? 0, 3), fmt(v.max() ?? 0, 3)]
                 })
        let spread = (heightByClass[.xheight]?.first ?? 0) - (heightByClass[.descender]?.first ?? 0)
        md.para("Se `characterBounds` fosse tinta, a altura mudaria por classe (x < ascendente < descendente). Diferença entre a primeira amostra de \"xheight\" e de \"descender\": \(fmt(spread, 4)) (× corpo).")

        md.heading(3, "selectionsByLine")
        md.para("Linhas devolvidas: \(selLines.count) (esperadas 9). Casadas com o rótulo: \(selFound)/9.")
        md.table(["referência", "erro médio (4 bordas)", "erro máx. (uma borda)", "esq.", "dir.", "base", "topo"],
                 [row("união da tinta da linha", selInk), row("caixa tipográfica da linha", selTypo)])

        md.heading(3, "attributedString: atributo .font")
        let nameOK = attrRows.filter { $0.attrName.contains($0.psTrue) || $0.psTrue.contains($0.attrName) }.count
        let sizeOK = attrRows.filter { abs($0.attrSize - $0.size) < 0.01 }.count
        md.para("Linhas com atributo `.font`: \(attrRows.count)/9. Tamanho correto: \(sizeOK)/\(attrRows.count). Nome PostScript igual ao desenhado: \(nameOK)/\(attrRows.count). `NSAttributedString` tem \(attr == nil ? "—" : "\(attr!.length)") caracteres; `string` igual a `attributedString.string`: \((page.string ?? "") == (attr?.string ?? "") ? "sim" : "não").")
        md.table(["linha", "fonte desenhada", "fonte no atributo", "corpo desenhado", "corpo no atributo", "altura-x métrica (CTFont)", "altura-x derivada (atributo → CTFont)", "NSFont.xHeight", "altura-x da tinta de \"x\""],
                 attrRows.map { [$0.tag, $0.psTrue, $0.attrName, fmt($0.size, 1), fmt($0.attrSize, 2), fmt($0.metric, 3), fmt($0.derived, 3), fmt($0.nsXH, 3), fmt($0.ink, 3)] })
        let derivedErr = attrRows.map { abs($0.derived - $0.ink) }
        let derivedMean = derivedErr.isEmpty ? 0 : derivedErr.reduce(0, +) / CGFloat(derivedErr.count)
        let derivedMax = derivedErr.max() ?? 0
        let metricVsInk = attrRows.map { abs($0.metric - $0.ink) }.max() ?? 0
        md.para("Altura-x derivada pela API (corpo do atributo × xHeight da fonte nomeada no atributo) contra a tinta do \"x\": erro médio \(fmt(derivedMean, 3)) pt, máximo \(fmt(derivedMax, 3)) pt. Diferença máxima entre `CTFontGetXHeight` e a tinta do \"x\": \(fmt(metricVsInk, 3)) pt (a altura-x métrica da fonte é um valor de projeto; a tinta do \"x\" pode diferir por overshoot/serifa).")

        md.heading(3, "Altura-x lida de characterBounds (altura da caixa de \"x\" e de \"z\")")
        md.table(["linha", "xHeight métrica (CTFont)", "characterBounds(\"x\").height", "characterBounds(\"z\").height", "erro de \"x\"", "erro de \"z\""],
                 attrRows.map { r in
                    let x = cbXHeight[r.tag + "x"] ?? 0, z = cbXHeight[r.tag + "z"] ?? 0
                    return [r.tag, fmt(r.metric, 3), fmt(x, 3), fmt(z, 3), fmt(x - r.metric, 3), fmt(z - r.metric, 3)]
                 })
        let cbXErr = attrRows.map { abs((cbXHeight[$0.tag + "x"] ?? 0) - $0.metric) }
        let cbXErrMax = cbXErr.max() ?? 0
        let cbXErrMean = cbXErr.isEmpty ? 0 : cbXErr.reduce(0, +) / CGFloat(cbXErr.count)

        // 5) Conclusão
        let best = [("tinta", inkStat.mean), ("caixa tipográfica", typoStat.mean), ("avanço × bbox da fonte", boxStat.mean)].min { $0.1 < $1.1 }!
        md.heading(3, "Conclusão S3")
        let apiOK = !attrRows.isEmpty && sizeOK == attrRows.count && nameOK == attrRows.count && derivedMax < 0.15
        md.bullets([
            "`characterBounds(at:)` devolve **\(best.0)** (menor erro médio: \(fmt(best.1, 3)) pt; contra a tinta: \(fmt(inkStat.mean, 3)) pt médio, \(fmt(inkStat.maxEdge, 3)) pt máx.; contra a caixa tipográfica: \(fmt(typoStat.mean, 3)) pt médio, \(fmt(typoStat.maxEdge, 3)) pt máx.).",
            "Detalhe: bordas verticais da `characterBounds` = tinta (erro base \(fmt(inkStat.edge(2), 3)) pt, topo \(fmt(inkStat.edge(3), 3)) pt); bordas horizontais alargadas (esq. \(fmt(inkStat.sedge(0), 3)) pt, dir. \(fmt(inkStat.sedge(1), 3)) pt em média, sinal contra a tinta), ou seja, nem tinta nem avanço exatos.",
            "Altura-x pela caixa do caractere \"x\": erro médio \(fmt(cbXErrMean, 3)) pt, máx. \(fmt(cbXErrMax, 3)) pt contra `CTFontGetXHeight`.",
            "`selectionsByLine()` bate melhor com \(selInk.mean < selTypo.mean ? "a tinta da linha" : "a caixa tipográfica da linha") (erro médio \(fmt(min(selInk.mean, selTypo.mean), 3)) pt).",
            apiOK
                ? "Altura-x de PDF digital **por API**: tamanho e fonte do `attributedString` estão corretos nas \(attrRows.count) linhas; corpo × `xHeight` da fonte reproduz a tinta do \"x\" com erro máx. \(fmt(derivedMax, 3)) pt. Ressalva: depende de a fonte do atributo ser resolvida pelo nome."
                : "Altura-x por API **não é confiável** nestes dados (tamanho \(sizeOK)/\(attrRows.count), nome \(nameOK)/\(attrRows.count), erro máx. \(fmt(derivedMax, 3)) pt): medir na tinta.",
            "Fontes embutidas sem nome resolvível (subconjunto sem a fonte no sistema, Type 3) não foram testadas aqui; o fallback é medir a tinta, como no §5.5.",
        ])

        var summary = ["S3 characterBounds ≈ \(best.0): erro médio vs tinta \(fmt(inkStat.mean, 3)) pt (máx \(fmt(inkStat.maxEdge, 3))), vs tipográfica \(fmt(typoStat.mean, 3)) pt (máx \(fmt(typoStat.maxEdge, 3)))"]
        summary.append("  S3 selectionsByLine: vs tinta \(fmt(selInk.mean, 3)) pt, vs tipográfica \(fmt(selTypo.mean, 3)) pt; linhas \(selLines.count)")
        summary.append("  S3 attributedString: tamanho \(sizeOK)/\(attrRows.count), nome \(nameOK)/\(attrRows.count), altura-x derivada vs tinta erro máx \(fmt(derivedMax, 3)) pt → \(apiOK ? "API serve" : "medir tinta")")
        return SpikeResult(markdown: md.text, summary: summary)
    }

    // MARK: Geometria conhecida

    static func truth(text: String, tag: String, font: CTFont, size: CGFloat, origin: CGPoint) -> LineTruth {
        let attrs = [kCTFontAttributeName as String: font] as CFDictionary
        let astr = CFAttributedStringCreate(nil, text as CFString, attrs)!
        let line = CTLineCreateWithAttributedString(astr)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        let fbox = CTFontGetBoundingBox(font)
        var chars: [Truth] = []
        let utf16 = Array(text.utf16)
        let labelLen = tag.utf16.count
        var glyphTotal = 0

        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            glyphTotal += n
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            var adv = [CGSize](repeating: .zero, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
            var rects = [CGRect](repeating: .zero, count: n)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &rects, n)
            for i in 0..<n {
                let o = CGPoint(x: origin.x + pos[i].x, y: origin.y + pos[i].y)
                let ci = idx[i]
                let ch = Character(UnicodeScalar(utf16[ci]) ?? " ")
                let ink = rects[i].isEmpty ? CGRect(x: o.x, y: o.y, width: 0, height: 0) : rects[i].offsetBy(dx: o.x, dy: o.y)
                chars.append(Truth(ch: ch, utf16Index: ci, ink: ink,
                                   typo: CGRect(x: o.x, y: o.y - desc, width: adv[i].width, height: asc + desc),
                                   fontBox: CGRect(x: o.x, y: o.y + fbox.minY, width: adv[i].width, height: fbox.height),
                                   cls: classify(ch, inLabel: ci < labelLen)))
            }
        }
        let inked = chars.filter { $0.ch != " " && !$0.ink.isEmpty }
        let union = inked.map(\.ink).reduce(CGRect.null) { $0.union($1) }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let xg = glyph(for: "x", font: font)
        var xr = CGRect.zero
        var g = xg
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &xr, 1)
        return LineTruth(tag: tag, text: text, fontName: CTFontCopyPostScriptName(font) as String, size: size, origin: origin,
                         chars: chars, inkUnion: union,
                         typoLine: CGRect(x: origin.x, y: origin.y - desc, width: CGFloat(width), height: asc + desc),
                         xHeightMetric: CTFontGetXHeight(font), xInk: xr.maxY, glyphCountMatches: glyphTotal == utf16.count)
    }

    static func glyph(for ch: Character, font: CTFont) -> CGGlyph {
        var u = Array(String(ch).utf16)
        var g = [CGGlyph](repeating: 0, count: u.count)
        CTFontGetGlyphsForCharacters(font, &u, &g, u.count)
        return g[0]
    }
}
