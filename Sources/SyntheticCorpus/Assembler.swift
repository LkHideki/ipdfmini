import CoreGraphics
import CoreText
import Foundation
import MiniGeometry
import PDFKit

struct PageSpec {
    var media: CGRect
    var crop: CGRect?
    var trim: CGRect?
    var bleed: CGRect?
    var rotation = 0
    var draw: (Canvas) -> Void

    /// Caixa efetiva: `TrimBox` quando existe, senão `CropBox ∩ MediaBox`.
    var effectiveBox: CGRect { trim ?? crop.map { $0.intersection(media) } ?? media }
}

struct OutlineItem {
    var title: String
    var page: Int
    var point: CGPoint
    var children: [OutlineItem] = []

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

struct Plan {
    var pages: [PageSpec]
    var outline: [OutlineItem] = []
    var bodyFont: CTFont
}

enum Assembler {
    static func assemble(_ scenario: Scenario, _ plan: Plan) -> SyntheticDocument {
        let (raw, canvases) = render(plan)
        let needsPDFKit = plan.pages.contains { $0.rotation != 0 }
            || !plan.outline.isEmpty
            || canvases.contains { !$0.links.isEmpty || !$0.highlights.isEmpty }
        var data = needsPDFKit ? postProcess(raw, plan: plan, canvases: canvases) : raw
        let customBoxes = plan.pages.contains {
            $0.media.origin != .zero || $0.crop != nil || $0.trim != nil || $0.bleed != nil
        }
        // O PDFKit acrescenta TrimBox/BleedBox/ArtBox por conta própria: depois dele, sempre reescreve.
        // Navegação fora do PDFKit do macOS 27.2: ver `BoxPatcher.applyOutline` e
        // `BoxPatcher.resolvePageIndexDestinations`.
        data = BoxPatcher.resolvePageIndexDestinations(data)
        data = BoxPatcher.applyOutline(data, plan.outline.map(patchOutline))
        if needsPDFKit || customBoxes {
            data = BoxPatcher.apply(data, boxes: plan.pages.map {
                BoxPatcher.Boxes(media: $0.media, crop: $0.crop, trim: $0.trim, bleed: $0.bleed)
            })
        }

        let pages = zip(plan.pages, canvases).map { truth(spec: $0, canvas: $1) }
        let truth = DocumentTruth(
            pages: pages,
            bodyPointSize: CTFontGetSize(plan.bodyFont),
            bodyXHeightPt: CTFontGetXHeight(plan.bodyFont),
            outlineCount: plan.outline.reduce(0) { $0 + $1.count },
            linkCount: canvases.reduce(0) { $0 + $1.links.count },
            annotationCount: canvases.reduce(0) { $0 + $1.highlights.count },
            words: canvases.flatMap(\.words))
        return SyntheticDocument(scenario: scenario, data: data, truth: truth)
    }

    private static func patchOutline(_ o: OutlineItem) -> BoxPatcher.Outline {
        BoxPatcher.Outline(title: o.title, page: o.page, point: o.point, children: o.children.map(patchOutline))
    }

    // MARK: PDF base (CGContext)

    private static func boxData(_ r: CGRect) -> CFData {
        var box = r
        return withUnsafeBytes(of: &box) { Data($0) } as CFData
    }

    /// O CGContext de PDF normaliza a MediaBox para a origem (0,0) e recorta o desenho a ela.
    /// Por isso a página de geração cobre [0, maxX] × [0, maxY] da MediaBox final: o conteúdo é
    /// desenhado nas coordenadas finais do espaço do usuário e as caixas reais entram depois
    /// (`BoxPatcher`). Origem negativa não é suportada.
    private static func auxInfo(_ spec: PageSpec) -> CFDictionary {
        precondition(spec.media.minX >= 0 && spec.media.minY >= 0, "MediaBox com origem negativa")
        let cover = CGRect(x: 0, y: 0, width: spec.media.maxX, height: spec.media.maxY)
        return [kCGPDFContextMediaBox: boxData(cover)] as CFDictionary
    }

    private static func render(_ plan: Plan) -> (Data, [Canvas]) {
        let buffer = NSMutableData()
        let consumer = CGDataConsumer(data: buffer)!
        var first = plan.pages[0].media
        let info: [CFString: Any] = [kCGPDFContextCreator: "iPDFmini SyntheticCorpus", kCGPDFContextTitle: "Synthetic"]
        let ctx = CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary)!
        var canvases: [Canvas] = []
        for spec in plan.pages {
            ctx.beginPDFPage(auxInfo(spec))
            let canvas = Canvas(ctx: ctx)
            spec.draw(canvas)
            ctx.endPDFPage()
            canvases.append(canvas)
        }
        ctx.closePDF()
        return (buffer as Data, canvases)
    }

    // MARK: PDFKit (rotação, sumário, anotações)

    private static func postProcess(_ raw: Data, plan: Plan, canvases: [Canvas]) -> Data {
        guard let doc = PDFDocument(data: raw) else { fatalError("SyntheticCorpus: PDF base ilegível") }

        for (i, spec) in plan.pages.enumerated() {
            guard let page = doc.page(at: i) else { continue }
            if spec.rotation != 0 { page.rotation = spec.rotation }
            for l in canvases[i].links {
                let a = PDFAnnotation(bounds: l.rect, forType: .link, withProperties: nil)
                let border = PDFBorder()
                border.lineWidth = 0
                a.border = border
                switch l.target {
                case let .page(index, point): a.destination = PDFDestination(page: doc.page(at: index)!, at: point)
                case let .url(url): a.url = url
                }
                page.addAnnotation(a)
            }
            for r in canvases[i].highlights {
                let a = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil)
                a.markupType = .highlight
                a.color = NSColor.yellow.withAlphaComponent(0.4)
                // Pontos do quadrilátero relativos à origem da anotação: TL, TR, BL, BR.
                let w = r.width, h = r.height
                a.quadrilateralPoints = [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), .zero, CGPoint(x: w, y: 0)]
                    .map { NSValue(point: $0) }
                page.addAnnotation(a)
            }
        }

        guard let out = doc.dataRepresentation() else { fatalError("SyntheticCorpus: PDFKit não serializou") }
        return out
    }

    // MARK: verdade

    private static func truth(spec: PageSpec, canvas: Canvas) -> PageTruth {
        let geometry = PageGeometry(effectiveBox: spec.effectiveBox, rotation: spec.rotation)
        func union(_ rs: [CGRect]) -> CGRect? { rs.dropFirst().reduce(rs.first) { $0?.union($1) } }
        return PageTruth(
            geometry: geometry,
            mediaBox: spec.media,
            cropBox: spec.crop,
            trimBox: spec.trim,
            bleedBox: spec.bleed,
            inkBox: union(canvas.ink).map(geometry.toPage),
            ignorableInk: canvas.ignorable.map(geometry.toPage),
            headerFooter: canvas.headerFooter.map(geometry.toPage),
            lines: canvas.lines.map(geometry.toPage),
            columns: canvas.columns.map(geometry.toPage),
            isScan: canvas.isScan,
            blocks: canvas.blocks.enumerated().map { i, b in
                BlockTruth(rect: geometry.toPage(b.rect), type: b.type, column: b.column, readingOrder: i,
                           lines: b.lines.map(geometry.toPage))
            })
    }
}
