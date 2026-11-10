import Foundation
import CoreGraphics
import PDFKit
import MiniGeometry
import QPDFKit

/// Contagens do remapeamento de navegação e anotações.
public struct RemapStats: Codable, Sendable, Equatable {
    public var sourceLinks = 0
    public var outputLinks = 0
    public var outlineItems = 0
    public var sourceAnnotations = 0
    public var outputAnnotations = 0
    /// Links/itens de sumário cujo destino caiu fora do plano ou com ação sem tratamento
    /// (o link sai; o item de sumário fica, sem destino).
    public var droppedDestinations = 0
    /// Anotações sem tratamento (formulário, carimbo, figuras…) ou fora de toda colocação.
    public var droppedAnnotations = 0

    public init() {}
}

/// Links, sumário e anotações de marcação levados da origem à saída pelo `PlanMapping`. PLAN.md §9.2.
///
/// Lidos pelo PDFKit (espaço do usuário sem rotação; caminhos de tinta e quadriláteros
/// relativos à origem da anotação) e gravados pelo qpdf em sintaxe PDF (coordenadas
/// absolutas da página de saída). O mapa trabalha no espaço de página: tudo passa por
/// `geometry.toPage` antes.
struct AnnotationRemap {
    static let markupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]

    let source: PDFDocument
    let mapping: PlanMapping
    /// "N G R" de cada página de saída.
    let pageRefs: [String]

    /// Anotação pronta para a C API.
    struct Output {
        var page: Int
        var dictionary: String
    }

    func annotations(stats: inout RemapStats) -> [Output] {
        var out: [Output] = []
        for s in mapping.sourcePages {
            guard let page = source.page(at: s), let g = mapping.geometry(ofSourcePage: s) else { continue }
            for a in page.annotations {
                guard let type = a.type, type != "Popup" else { continue }
                if type == "Link" {
                    stats.sourceLinks += 1
                    let made = link(a, page: s, geometry: g, stats: &stats)
                    stats.outputLinks += made.count
                    out += made
                } else {
                    stats.sourceAnnotations += 1
                    let made: [Output]
                    if Self.markupTypes.contains(type) { made = markup(a, type: type, page: s, geometry: g) }
                    else if type == "Text" { made = note(a, page: s, geometry: g) }
                    else if type == "Ink" { made = ink(a, page: s, geometry: g) }
                    else { made = [] }
                    if made.isEmpty { stats.droppedAnnotations += 1 }
                    stats.outputAnnotations += made.count
                    out += made
                }
            }
        }
        return out
    }

    func outline(stats: inout RemapStats) -> [QPDFDocument.OutlineItem] {
        guard let root = source.outlineRoot else { return [] }
        var items: [QPDFDocument.OutlineItem] = []
        func walk(_ node: PDFOutline, parent: Int?) {
            for i in 0..<node.numberOfChildren {
                guard let c = node.child(at: i) else { continue }
                var dest: String?
                if let d = c.destination ?? (c.action as? PDFActionGoTo)?.destination {
                    dest = destination(d)
                    if dest == nil { stats.droppedDestinations += 1 }
                } else if c.action != nil {
                    stats.droppedDestinations += 1
                }
                items.append(QPDFDocument.OutlineItem(title: c.label ?? "", parent: parent, destination: dest,
                                                      isOpen: c.isOpen))
                stats.outlineItems += 1
                walk(c, parent: items.count - 1)
            }
        }
        walk(root, parent: nil)
        return items
    }

    // MARK: - Destinos

    /// Destino remapeado em sintaxe PDF (`/XYZ`); coordenada livre vira o topo/esquerda da página.
    func destination(_ d: PDFDestination) -> String? {
        guard let page = d.page else { return nil }
        let s = source.index(for: page)
        guard s != NSNotFound, let g = mapping.geometry(ofSourcePage: s) else { return nil }
        let free = kPDFDestinationUnspecifiedValue / 2
        let raw = d.point
        var p = g.toPage(CGPoint(x: abs(raw.x) < free ? raw.x : g.effectiveBox.minX,
                                 y: abs(raw.y) < free ? raw.y : g.effectiveBox.maxY))
        // Livre numa coordenada só: com rotação, a convertida pode cair fora da caixa.
        if abs(raw.x) >= free || abs(raw.y) >= free { p = PlanMapping.clamp(p, g.pageBox) }
        guard let (o, q) = mapping.destination(point: p, fromSourcePage: s), o < pageRefs.count else { return nil }
        let zoom = d.zoom > 0 && d.zoom < free ? Self.n(d.zoom) : "null"
        return "[\(pageRefs[o]) /XYZ \(Self.n(q.x)) \(Self.n(q.y)) \(zoom)]"
    }

    // MARK: - Links

    func link(_ a: PDFAnnotation, page s: Int, geometry g: PageGeometry, stats: inout RemapStats) -> [Output] {
        let pieces = mapping.map(rect: g.toPage(a.bounds), fromSourcePage: s)
        guard !pieces.isEmpty else { return [] }
        let target: String
        if let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination {
            guard let dest = destination(d) else { stats.droppedDestinations += 1; return [] }
            target = "/Dest \(dest)"
        } else if let url = a.url ?? (a.action as? PDFActionURL)?.url {
            target = "/A << /S /URI /URI \(Self.string(url.absoluteString)) >>"
        } else if let named = a.action as? PDFActionNamed, let name = Self.namedAction(named.name) {
            target = "/A << /S /Named /N /\(name) >>"
        } else {
            stats.droppedDestinations += 1
            return []
        }
        let width = a.border?.lineWidth ?? 0
        return pieces.map { o, r in
            Output(page: o, dictionary: "<< /Type /Annot /Subtype /Link /Rect \(Self.rect(r)) /Border [0 0 \(Self.n(width))] \(target) >>")
        }
    }

    static func namedAction(_ n: PDFActionNamedName) -> String? {
        switch n {
        case .nextPage: "NextPage"
        case .previousPage: "PrevPage"
        case .firstPage: "FirstPage"
        case .lastPage: "LastPage"
        default: nil
        }
    }

    // MARK: - Anotações

    /// Cor, texto, autor e opacidade da anotação de origem.
    func common(_ a: PDFAnnotation) -> String {
        var s = ""
        if let c = a.color.usingColorSpace(.sRGB) {
            s += " /C [\(Self.n(c.redComponent)) \(Self.n(c.greenComponent)) \(Self.n(c.blueComponent))]"
            if c.alphaComponent < 1 { s += " /CA \(Self.n(c.alphaComponent))" }
        }
        if let t = a.contents, !t.isEmpty { s += " /Contents \(Self.string(t))" }
        if let u = a.userName, !u.isEmpty { s += " /T \(Self.string(u))" }
        return s + " /F 4"
    }

    /// Realce, sublinhado, tachado: cada quadrilátero recortado por colocação; uma anotação por colocação.
    func markup(_ a: PDFAnnotation, type: String, page s: Int, geometry g: PageGeometry) -> [Output] {
        let origin = a.bounds.origin
        var quads: [CGRect] = []
        if let pts = a.quadrilateralPoints?.map(\.pointValue), pts.count >= 4 {
            for k in stride(from: 0, to: pts.count - 3, by: 4) {
                quads.append(Self.bounding(pts[k..<(k + 4)].map { g.toPage(CGPoint(x: $0.x + origin.x, y: $0.y + origin.y)) }))
            }
        } else {
            quads = [g.toPage(a.bounds)]
        }
        var perEntry: [Int: [CGRect]] = [:]
        var order: [Int] = []
        for q in quads {
            for (e, r) in mapping.pieces(of: q, s) {
                if perEntry[e] == nil { order.append(e) }
                perEntry[e, default: []].append(r.applying(mapping.entries[e].transform).standardized)
            }
        }
        let extra = common(a)
        return order.map { e in
            let rects = perEntry[e]!
            let b = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            // TL, TR, BL, BR: a ordem que Acrobat e PDFKit gravam e leem.
            let qp = rects.flatMap { r in [r.minX, r.maxY, r.maxX, r.maxY, r.minX, r.minY, r.maxX, r.minY] }
                .map(Self.n).joined(separator: " ")
            return Output(page: mapping.entries[e].outputPage,
                          dictionary: "<< /Type /Annot /Subtype /\(type) /Rect \(Self.rect(b)) /QuadPoints [\(qp)]\(extra) >>")
        }
    }

    /// Nota: o ícone mantém o tamanho; o canto superior esquerdo segue o ponto.
    func note(_ a: PDFAnnotation, page s: Int, geometry g: PageGeometry) -> [Output] {
        let r = a.bounds
        let anchor = g.toPage(CGPoint(x: r.minX, y: r.maxY))
        guard let (o, q) = mapping.destination(point: anchor, fromSourcePage: s) else { return [] }
        let box = CGRect(x: q.x, y: q.y - r.height, width: r.width, height: r.height)
        let icon = Self.iconName(a.iconType)
        return [Output(page: o, dictionary: "<< /Type /Annot /Subtype /Text /Rect \(Self.rect(box)) /Name /\(icon)\(common(a)) >>")]
    }

    static func iconName(_ t: PDFTextAnnotationIconType) -> String {
        switch t {
        case .key: "Key"
        case .note: "Note"
        case .help: "Help"
        case .newParagraph: "NewParagraph"
        case .paragraph: "Paragraph"
        case .insert: "Insert"
        default: "Comment"
        }
    }

    /// Tinta: cada traço é dividido nos trechos dentro de cada colocação.
    func ink(_ a: PDFAnnotation, page s: Int, geometry g: PageGeometry) -> [Output] {
        let origin = a.bounds.origin
        let strokes: [[CGPoint]] = (a.paths ?? []).map { path in
            Self.points(of: path.flattened).map { g.toPage(CGPoint(x: $0.x + origin.x, y: $0.y + origin.y)) }
        }
        let width = a.border?.lineWidth ?? 1
        var out: [Output] = []
        for e in mapping.bySource[s] ?? [] {
            let entry = mapping.entries[e]
            let runs = strokes.flatMap { Self.clip($0, to: entry.sourceRect) }
                .map { $0.map { $0.applying(entry.transform) } }
            guard !runs.isEmpty else { continue }
            let b = Self.bounding(runs.flatMap { $0 }).insetBy(dx: -width, dy: -width)
            let list = runs.map { "[" + $0.flatMap { [$0.x, $0.y] }.map(Self.n).joined(separator: " ") + "]" }.joined(separator: " ")
            out.append(Output(page: entry.outputPage,
                              dictionary: "<< /Type /Annot /Subtype /Ink /Rect \(Self.rect(b)) /InkList [\(list)] /BS << /W \(Self.n(width)) >>\(common(a)) >>"))
        }
        return out
    }

    // MARK: - Utilidades

    /// Trechos da polilinha dentro de `r` (Liang–Barsky por segmento): o traço que cruza a
    /// borda é cortado nela, não no último ponto de dentro.
    static func clip(_ line: [CGPoint], to r: CGRect) -> [[CGPoint]] {
        if line.count == 1 { return PlanMapping.contains(r, line[0]) ? [[line[0], line[0]]] : [] }
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        for k in 1..<max(1, line.count) {
            let a = line[k - 1], b = line[k]
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            var t0: CGFloat = 0, t1: CGFloat = 1
            var visible = true
            for (p, q) in [(-d.x, a.x - r.minX), (d.x, r.maxX - a.x), (-d.y, a.y - r.minY), (d.y, r.maxY - a.y)] {
                if p == 0 { if q < 0 { visible = false; break } ; continue }
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { visible = false; break }
            }
            guard visible else {
                if run.count >= 2 { runs.append(run) }
                run = []
                continue
            }
            let s = CGPoint(x: a.x + t0 * d.x, y: a.y + t0 * d.y), e = CGPoint(x: a.x + t1 * d.x, y: a.y + t1 * d.y)
            // Continua o trecho só se este segmento começa onde o anterior terminou dentro.
            if t0 > 0 || run.isEmpty {
                if run.count >= 2 { runs.append(run) }
                run = [s]
            }
            run.append(e)
            if t1 < 1 {
                if run.count >= 2 { runs.append(run) }
                run = []
            }
        }
        if run.count >= 2 { runs.append(run) }
        return runs
    }

    static func points(of path: NSBezierPath) -> [CGPoint] {
        var out: [CGPoint] = []
        var buf = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            switch path.element(at: i, associatedPoints: &buf) {
            case .moveTo, .lineTo: out.append(buf[0])
            case .curveTo, .cubicCurveTo: out.append(buf[2])
            case .quadraticCurveTo: out.append(buf[1])
            case .closePath: if let f = out.first { out.append(f) }
            @unknown default: break
            }
        }
        return out
    }

    static func bounding(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func n(_ v: CGFloat) -> String { OverlayContent.n(v) }

    static func rect(_ r: CGRect) -> String { "[\(n(r.minX)) \(n(r.minY)) \(n(r.maxX)) \(n(r.maxY))]" }

    static func string(_ s: String) -> String { InfoPatch.pdfString(s) }
}
