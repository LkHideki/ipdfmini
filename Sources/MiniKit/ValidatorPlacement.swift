import CoreGraphics
import Foundation
import LayoutEngine
import MiniGeometry
import PDFAnalysis
import PDFKit
import PDFWriting

// Invariantes 4, 5 e 7 para saídas do PlacementWriter (E3+). PLAN.md §15.2.

/// Multiconjunto de palavras.
struct WordBag: Equatable, Sendable {
    var counts: [String: Int] = [:]

    init(_ items: [String] = []) { for w in items { counts[w, default: 0] += 1 } }

    init(_ s: String?) { self.init((s ?? "").split(whereSeparator: \.isWhitespace).map(String.init)) }

    var total: Int { counts.values.reduce(0, +) }
    var isEmpty: Bool { counts.isEmpty }

    mutating func add(_ o: WordBag) { for (w, n) in o.counts { counts[w, default: 0] += n } }

    /// `self − o`, só a parte positiva.
    func minus(_ o: WordBag) -> WordBag {
        var r = WordBag()
        for (w, n) in counts where n - (o.counts[w] ?? 0) > 0 { r.counts[w] = n - (o.counts[w] ?? 0) }
        return r
    }

    var sample: String {
        let s = counts.sorted { $0.key < $1.key }.prefix(6).map { $0.value > 1 ? "\($0.key)×\($0.value)" : $0.key }
        return s.joined(separator: " ") + (counts.count > 6 ? " …" : "")
    }
}

extension Validator {
    /// Palavras dos indicadores de página da página de saída (Helvetica, desenhados pelo escritor).
    static func indicatorWords(_ page: OutputPage) -> WordBag {
        var b = WordBag()
        for case .pageIndicator(let t, _) in page.overlays { b.add(WordBag(t)) }
        return b
    }

    // MARK: - Inv. 4

    /// Texto, colocação a colocação: as palavras na área de cada colocação na saída
    /// (`selection(for:)`, geométrico) são as da janela de origem; somadas, cobrem o
    /// texto da origem; o único excesso aceito vem de colocações que se sobrepõem na
    /// origem (fatia de bloco atômico com marca de continuidade).
    ///
    /// `page.string` não serve: cada colocação desenha o Form XObject da página
    /// inteira e o clip só esconde. O PDFKit extrai parte do texto escondido, que cai
    /// fora da área da própria colocação e pode cair dentro da área de outra na mesma
    /// página (E5 empilha fatias). Por isso página com várias colocações é conferida
    /// num arquivo "explodido", gravado pelo mesmo escritor com uma colocação por
    /// página (mesmas matrizes e clips; muda só a vizinhança). Na saída gravada, a
    /// área de uma colocação empilhada tem também texto escondido das vizinhas, e o
    /// PDFKit funde palavras das duas camadas (medido: falsos "faltando" em E5); lá,
    /// desenho faltando ou fora do lugar é pego pelo inv. 1b, pixel a pixel.
    func text(analysis: DocumentAnalysis, plan: LayoutPlan, source: SourceDocument, srcData: Data, outData: Data,
              outURL: URL) throws -> InvariantResult {
        let title = "Texto"
        let src = try Self.open(srcData, password: source.password, url: source.url, isSource: true)
        let out = try Self.open(outData, password: nil, url: outURL, isSource: false)
        let all: [(out: Int, k: Int)] = plan.pages.enumerated().flatMap { o, page in page.placements.indices.map { (o, $0) } }

        var exploded: PDFDocument?
        if plan.pages.contains(where: { $0.placements.count > 1 }) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipdfmini-validate-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("exploded.pdf")
            let xplan = LayoutPlan(profile: plan.profile, pages: all.map {
                OutputPage(sizePt: plan.pages[$0.out].sizePt, placements: [plan.pages[$0.out].placements[$0.k]])
            }, recipe: plan.recipe)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try PlacementWriter(writesPageLabels: false).writeDetailed(xplan, source: source, to: url,
                                                                               options: WriteOptions())
                exploded = PDFDocument(data: try Data(contentsOf: url))
            } catch {
                return InvariantResult(id: "4", title: title, status: .failed,
                                       detail: "não foi possível gravar a cópia explodida para conferir o texto: \(error)")
            }
        }

        var problems: [String] = []
        var bad = Set<Int>()
        var expected = WordBag(), visible = WordBag(), excused = WordBag()
        for (n, (o, k)) in all.enumerated() {
            let p = plan.pages[o].placements[k]
            guard let a = analysis.pages.first(where: { $0.index == p.sourcePage }), let sp = src.page(at: p.sourcePage) else {
                bad.insert(o); problems.append("saída p. \(o + 1): origem p. \(p.sourcePage + 1) ausente"); continue
            }
            let g = p.sourceGeometry ?? a.geometry
            var hidden = WordBag()
            for h in p.hidden {
                let x = h.standardized.intersection(p.sourceRect)
                guard !x.isNull, x.width > 0, x.height > 0 else { continue }
                hidden.add(WordBag(sp.selection(for: g.toUser(x))?.string))
            }
            let want = WordBag(sp.selection(for: g.toUser(p.sourceRect))?.string).minus(hidden)
            let alone = plan.pages[o].placements.count == 1
            guard let page = alone ? out.page(at: o) : exploded?.page(at: n) else {
                bad.insert(o); problems.append("saída p. \(o + 1): página ausente"); continue
            }
            let outRect = p.sourceRect.applying(p.transform).standardized
            let got = WordBag(page.selection(for: outRect)?.string).minus(hidden)
            let missing = want.minus(got), extra = got.minus(want).minus(Self.indicatorWords(plan.pages[o]))
            if !missing.isEmpty || !extra.isEmpty {
                bad.insert(o)
                let tag = alone ? "" : " colocação \(k + 1)"
                problems.append("saída p. \(o + 1)\(tag): faltam \(missing.total) [\(missing.sample)], sobram \(extra.total) [\(extra.sample)]")
            }
            expected.add(want)
            visible.add(got)
            excused.add(hidden)
        }

        // Cobertura: o texto visível da origem (fora das regiões ignoradas) está em alguma colocação.
        var sourceWords = WordBag(), allowed = WordBag()
        for a in analysis.pages {
            guard let sp = src.page(at: a.index) else { continue }
            let g = a.geometry
            var page = WordBag(sp.selection(for: g.toUser(a.pageBox))?.string)
            for w in a.warnings {
                // Marcas de corte ficam fora da caixa de página, já excluídas acima.
                guard case let .ignoredRegion(region, reason) = w, reason != "cropMarks" else { continue }
                page = page.minus(WordBag(sp.selection(for: g.toUser(region))?.string))
            }
            sourceWords.add(page)
            let rects = plan.pages.flatMap { $0.placements.filter { $0.sourcePage == a.index }.map(\.sourceRect) }
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let x = rects[i].intersection(rects[j])
                    guard !x.isNull, x.width > 0, x.height > 0 else { continue }
                    allowed.add(WordBag(sp.selection(for: g.toUser(x))?.string))
                }
            }
        }
        let missing = sourceWords.minus(expected).minus(excused)
        let repeated = expected.minus(sourceWords)
        let unexplained = repeated.minus(allowed)
        if !missing.isEmpty { problems.append("\(missing.total) palavras da origem fora de toda colocação [\(missing.sample)]") }
        if !unexplained.isEmpty { problems.append("\(unexplained.total) palavras repetidas fora das sobreposições [\(unexplained.sample)]") }

        // Informativo: texto escondido pelo clip que o PDFKit extrai da página inteira.
        var outAll = WordBag(), indicators = WordBag()
        for j in 0..<out.pageCount { outAll.add(WordBag(out.page(at: j)?.string)) }
        for p in plan.pages { indicators.add(Self.indicatorWords(p)) }
        let leaked = outAll.minus(visible).minus(indicators)

        let metrics = [Metric("palavras da origem", Double(sourceWords.total)),
                       Metric("palavras nas colocações", Double(visible.total)),
                       Metric("palavras fora das colocações", Double(missing.total)),
                       Metric("repetidas em sobreposições", Double(repeated.total - unexplained.total)),
                       Metric("texto escondido extraído pelo PDFKit", Double(leaked.total))]
        let ok = problems.isEmpty
        return InvariantResult(id: "4", title: title, status: ok ? .passed : .failed,
                               detail: ok ? "palavras de cada colocação iguais às da janela de origem; todo texto da origem coberto"
                                          : problems.prefix(8).joined(separator: "; "),
                               metrics: metrics, outputPages: bad.sorted())
    }

    // MARK: - Inv. 5

    /// Destino esperado na saída: `PlanMapping.destination` (1ª colocação que contém o
    /// ponto, senão a mais próxima com o ponto preso à borda). Coordenada livre vira o
    /// topo/esquerda da página de origem.
    static func expectedDestination(_ d: PDFDestination?, src: PDFDocument,
                                    mapping: PlanMapping) -> (sourcePage: Int, out: Int, point: CGPoint)?? {
        guard let d else { return .some(nil) }
        guard let page = d.page else { return nil }
        let s = src.index(for: page)
        guard s != NSNotFound, let g = mapping.geometry(ofSourcePage: s) else { return nil }
        let free = kPDFDestinationUnspecifiedValue / 2
        let raw = d.point
        var p = g.toPage(CGPoint(x: abs(raw.x) < free ? raw.x : g.effectiveBox.minX,
                                 y: abs(raw.y) < free ? raw.y : g.effectiveBox.maxY))
        if abs(raw.x) >= free || abs(raw.y) >= free {
            let b = g.pageBox
            p = CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
        }
        guard let (o, q) = mapping.destination(point: p, fromSourcePage: s) else { return nil }
        return .some((s, o, q))
    }

    /// Navegação com várias colocações: sumário (contagem, rótulos, destinos), links
    /// (um pedaço por colocação que o retângulo toca, mesmo URL/destino) e anotações
    /// de marcação, notas e tinta (contagem por página de saída).
    func placementNavigation(plan: LayoutPlan, srcData: Data, password: String?, srcURL: URL, outData: Data,
                             outURL: URL) throws -> InvariantResult {
        let src = try Self.open(srcData, password: password, url: srcURL, isSource: true)
        let out = try Self.open(outData, password: nil, url: outURL, isSource: false)
        let mapping = PlanMapping(plan: plan)
        let tol = destinationTolerancePt
        var problems: [String] = []
        var badOut = Set<Int>()

        func check(_ sd: PDFDestination?, _ od: PDFDestination?, what: String) {
            guard let want = Self.expectedDestination(sd, src: src, mapping: mapping) else {
                problems.append("\(what): destino da origem fora do plano"); return
            }
            guard let want else {
                if od != nil { problems.append("\(what): destino surgiu na saída") }
                return
            }
            guard let od, let op = od.page else { problems.append("\(what): destino perdido"); return }
            let o = out.index(for: op)
            guard o == want.out else {
                if o != NSNotFound { badOut.insert(o) }
                problems.append("\(what): aponta para a saída p. \(o + 1), esperado p. \(want.out + 1)")
                return
            }
            let q = od.point
            if abs(q.x - want.point.x) > tol || abs(q.y - want.point.y) > tol {
                badOut.insert(o)
                problems.append("\(what): ponto \(Describe.point(q)), esperado \(Describe.point(want.point))")
            }
        }

        let so = Self.outline(src), oo = Self.outline(out)
        var srcItems: [PDFOutline] = [], outItems: [PDFOutline] = []
        func walk(_ o: PDFOutline, into list: inout [PDFOutline]) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                list.append(c)
                walk(c, into: &list)
            }
        }
        if let r = src.outlineRoot { walk(r, into: &srcItems) }
        if let r = out.outlineRoot { walk(r, into: &outItems) }
        if so.count != oo.count { problems.append("sumário: \(oo.count) itens, origem \(so.count)") }
        for (i, (s, o)) in zip(srcItems, outItems).enumerated() {
            if (s.label ?? "") != (o.label ?? "") { problems.append("sumário item \(i + 1): rótulo mudou") }
            check(s.destination ?? (s.action as? PDFActionGoTo)?.destination,
                  o.destination ?? (o.action as? PDFActionGoTo)?.destination, what: "sumário \"\(s.label ?? "")\"")
        }

        // Links esperados por página de saída.
        struct Expected { var rect: CGRect; var link: PDFAnnotation; var sourcePage: Int }
        var wantLinks: [Int: [Expected]] = [:]
        // Anotações esperadas por página de saída e subtipo: (mínimo, máximo).
        var wantAnnots: [Int: [String: (Int, Int)]] = [:]
        var srcLinks = 0, srcAnnots = 0, unsupported = 0
        // Colocação (índice na página) que contém um ponto da saída.
        func placementIndex(_ o: Int, _ r: CGRect) -> Int? {
            let c = CGPoint(x: r.midX, y: r.midY)
            return plan.pages[o].placements.firstIndex { $0.sourceRect.applying($0.transform).standardized.contains(c) }
        }
        for s in mapping.sourcePages {
            guard let page = src.page(at: s), let g = mapping.geometry(ofSourcePage: s) else { continue }
            for a in page.annotations {
                guard let type = a.type, type != "Popup" else { continue }
                if type == "Link" {
                    srcLinks += 1
                    for (o, r) in mapping.map(rect: g.toPage(a.bounds), fromSourcePage: s) {
                        wantLinks[o, default: []].append(Expected(rect: r, link: a, sourcePage: s))
                    }
                    continue
                }
                srcAnnots += 1
                var touched = Set<[Int]>()
                switch type {
                case "Highlight", "Underline", "StrikeOut", "Squiggly":
                    let origin = a.bounds.origin
                    var quads: [CGRect] = []
                    if let pts = a.quadrilateralPoints?.map(\.pointValue), pts.count >= 4 {
                        for k in stride(from: 0, to: pts.count - 3, by: 4) {
                            let q = pts[k..<(k + 4)].map { g.toPage(CGPoint(x: $0.x + origin.x, y: $0.y + origin.y)) }
                            let xs = q.map(\.x), ys = q.map(\.y)
                            quads.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
                        }
                    } else {
                        quads = [g.toPage(a.bounds)]
                    }
                    for q in quads {
                        for (o, r) in mapping.map(rect: q, fromSourcePage: s) { touched.insert([o, placementIndex(o, r) ?? -1]) }
                    }
                    for t in touched { wantAnnots[t[0], default: [:]][type, default: (0, 0)].0 += 1; wantAnnots[t[0]]![type]!.1 += 1 }
                case "Text":
                    let anchor = g.toPage(CGPoint(x: a.bounds.minX, y: a.bounds.maxY))
                    if let (o, _) = mapping.destination(point: anchor, fromSourcePage: s) {
                        wantAnnots[o, default: [:]][type, default: (0, 0)].0 += 1
                        wantAnnots[o]![type]!.1 += 1
                    }
                case "Ink":
                    // Traço pode cruzar a caixa de uma colocação sem entrar nela: a caixa dá o máximo.
                    let pieces = mapping.map(rect: g.toPage(a.bounds), fromSourcePage: s)
                    for (o, r) in pieces { touched.insert([o, placementIndex(o, r) ?? -1]) }
                    for t in touched { wantAnnots[t[0], default: [:]][type, default: (0, 0)].1 += 1 }
                default:
                    // Formulário, carimbo, figuras: fora do escopo do PlacementWriter (§9.2).
                    unsupported += 1
                }
            }
        }

        var outLinks = 0, outAnnots = 0, internalChecked = 0
        for j in 0..<min(out.pageCount, plan.pages.count) {
            guard let page = out.page(at: j) else { continue }
            var links = Self.links(page)
            outLinks += links.count
            var want = wantLinks[j] ?? []
            if links.count != want.count { badOut.insert(j); problems.append("saída p. \(j + 1): \(links.count) links, esperados \(want.count)") }
            // Pareia pelo retângulo.
            while let e = want.first {
                want.removeFirst()
                guard let i = links.firstIndex(where: { l in
                    abs(l.bounds.minX - e.rect.minX) <= tol && abs(l.bounds.minY - e.rect.minY) <= tol
                        && abs(l.bounds.maxX - e.rect.maxX) <= tol && abs(l.bounds.maxY - e.rect.maxY) <= tol
                }) else {
                    badOut.insert(j)
                    problems.append("saída p. \(j + 1): link esperado em \(Describe.rect(e.rect)) ausente")
                    continue
                }
                let o = links.remove(at: i)
                let su = e.link.url ?? (e.link.action as? PDFActionURL)?.url
                let ou = o.url ?? (o.action as? PDFActionURL)?.url
                if su != ou { badOut.insert(j); problems.append("saída p. \(j + 1) link em \(Describe.rect(e.rect)): URL mudou") }
                let sd = e.link.destination ?? (e.link.action as? PDFActionGoTo)?.destination
                let od = o.destination ?? (o.action as? PDFActionGoTo)?.destination
                if sd != nil || od != nil {
                    internalChecked += 1
                    check(sd, od, what: "saída p. \(j + 1) link em \(Describe.rect(e.rect))")
                }
            }
            for l in links { badOut.insert(j); problems.append("saída p. \(j + 1): link a mais em \(Describe.rect(l.bounds))") }

            var got: [String: Int] = [:]
            for a in page.annotations {
                guard let t = a.type, t != "Link", t != "Popup" else { continue }
                got[t, default: 0] += 1
                outAnnots += 1
            }
            let want2 = wantAnnots[j] ?? [:]
            for t in Set(got.keys).union(want2.keys) {
                let n = got[t] ?? 0, (lo, hi) = want2[t] ?? (0, 0)
                if n < lo || n > hi {
                    badOut.insert(j)
                    problems.append("saída p. \(j + 1): \(n) anotações \(t), esperadas \(lo == hi ? "\(lo)" : "\(lo)–\(hi)")")
                }
            }
        }
        let metrics = [Metric("itens de sumário", Double(oo.count)), Metric("itens de sumário na origem", Double(so.count)),
                       Metric("links", Double(outLinks)), Metric("links na origem", Double(srcLinks)),
                       Metric("links esperados", Double(wantLinks.values.reduce(0) { $0 + $1.count })),
                       Metric("links internos verificados", Double(internalChecked)),
                       Metric("anotações", Double(outAnnots)), Metric("anotações na origem", Double(srcAnnots)),
                       Metric("anotações sem tratamento", Double(unsupported))]
        let ok = problems.isEmpty
        return InvariantResult(id: "5", title: "Navegação", status: ok ? .passed : .failed,
                               detail: ok ? "sumário, links e anotações remapeados; destinos na colocação que contém o ponto"
                                          : problems.prefix(8).joined(separator: "; "),
                               metrics: metrics, outputPages: badOut.sorted())
    }

    // MARK: - Inv. 7

    /// Ida e volta pelo `PlanMapping`: grade 7×7 em cada colocação, origem → saída →
    /// origem e saída → origem → saída.
    func roundTrip(plan: LayoutPlan) -> InvariantResult {
        let m = PlanMapping(plan: plan)
        var worst: CGFloat = 0, samples = 0, lost = 0
        var bad = Set<Int>()
        for (o, page) in plan.pages.enumerated() {
            for p in page.placements {
                let r = p.sourceRect
                for i in 0...6 {
                    for j in 0...6 {
                        let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / 6, y: r.minY + r.height * CGFloat(j) / 6)
                        samples += 1
                        let hits = m.map(point: pt, fromSourcePage: p.sourcePage)
                        if !hits.contains(where: { $0.outputPage == o }) { lost += 1; bad.insert(o) }
                        for h in hits {
                            guard let back = m.unmap(point: h.point, onOutputPage: h.outputPage), back.sourcePage == p.sourcePage else {
                                lost += 1; bad.insert(h.outputPage); continue
                            }
                            worst = max(worst, hypot(back.point.x - pt.x, back.point.y - pt.y))
                        }
                        let q = pt.applying(p.transform)
                        guard let back = m.unmap(point: q, onOutputPage: o) else { lost += 1; bad.insert(o); continue }
                        let err = m.map(point: back.point, fromSourcePage: back.sourcePage)
                            .filter { $0.outputPage == o }.map { hypot($0.point.x - q.x, $0.point.y - q.y) }.min()
                        guard let err else { lost += 1; bad.insert(o); continue }
                        worst = max(worst, err)
                    }
                }
            }
        }
        let ok = lost == 0 && worst < roundTripTolerancePt
        let detail = ok ? "erro máximo \(Describe.number(Double(worst), decimals: 6)) pt em \(samples) pontos"
                        : "\(lost) pontos sem ida e volta; erro máximo \(Describe.number(Double(worst), decimals: 6)) pt"
        return InvariantResult(id: "7", title: "Ida e volta", status: ok ? .passed : .failed, detail: detail,
                               metrics: [Metric("pior erro", Double(worst), "pt"), Metric("amostras", Double(samples)),
                                         Metric("tolerância", Double(roundTripTolerancePt), "pt")],
                               outputPages: bad.sorted())
    }
}
