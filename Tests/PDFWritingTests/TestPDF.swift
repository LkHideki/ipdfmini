import Foundation
import CoreGraphics
import CoreText
import PDFKit
import QPDFKit
import MiniGeometry
import LayoutEngine
@testable import PDFWriting

// Gerador de PDFs de teste, independente do SyntheticCorpus.

struct TestLink {
    var rect: CGRect
    var destinationPage: Int
}

struct TestPageSpec {
    var media = CGRect(x: 0, y: 0, width: 600, height: 800)
    var crop: CGRect?
    var rotation = 0
    /// Texto com palavras únicas por página ("p3l7" …), em espaço do usuário.
    var lines = 30
    /// Quadrado preto em espaço do usuário; nulo = sem marcador.
    var marker: CGRect?
    /// Páginas de marcador não têm texto (para medir pixels).
    var drawText = true
    var internalLink: TestLink?
    var externalLink: (rect: CGRect, url: URL)?
    var highlight: CGRect?
    /// Imagem de ruído (incompressível) de lado `noiseSide` px: dá peso realista à página.
    var noiseSide = 0
}

struct TestDocSpec {
    var pages: [TestPageSpec]
    /// (título, página de destino, nível 0 ou 1); nível 1 vira filho do último nível 0.
    var outline: [(title: String, page: Int, level: Int)] = []
    var title: String? = "Título de teste"
    var author: String? = "Autora de teste"
    var subject: String? = "Assunto de teste"
}

enum TestPDF {
    static let fontName = "Times New Roman"

    @discardableResult
    static func build(_ spec: TestDocSpec, to url: URL, ownerPassword: String? = nil, userPassword: String? = nil) throws -> PDFDocument {
        let data = NSMutableData()
        var firstBox = spec.pages[0].media
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &firstBox, nil)!
        for (i, p) in spec.pages.enumerated() {
            var media = p.media
            let info: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            if p.drawText { drawText(ctx, page: i, spec: p) }
            if p.noiseSide > 0, let img = noiseImage(side: p.noiseSide, seed: UInt64(i + 1)) {
                ctx.draw(img, in: CGRect(x: 20, y: 20, width: 200, height: 200))
            }
            if let m = p.marker {
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fill(m)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let doc = PDFDocument(data: data as Data)!
        for (i, p) in spec.pages.enumerated() {
            let page = doc.page(at: i)!
            if let c = p.crop { page.setBounds(c, for: .cropBox) }
            page.rotation = p.rotation
        }
        // Anotações depois de caixas e rotação; em espaço do usuário.
        for (i, p) in spec.pages.enumerated() {
            let page = doc.page(at: i)!
            if let l = p.internalLink {
                let a = PDFAnnotation(bounds: l.rect, forType: .link, withProperties: nil)
                let target = doc.page(at: l.destinationPage)!
                a.destination = PDFDestination(page: target, at: CGPoint(x: 10, y: 700))
                page.addAnnotation(a)
            }
            if let l = p.externalLink {
                let a = PDFAnnotation(bounds: l.rect, forType: .link, withProperties: nil)
                a.url = l.url
                page.addAnnotation(a)
            }
            if let h = p.highlight {
                let a = PDFAnnotation(bounds: h, forType: .highlight, withProperties: nil)
                a.color = .yellow
                a.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: h.height)), NSValue(point: CGPoint(x: h.width, y: h.height)),
                    NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: h.width, y: 0)),
                ]
                page.addAnnotation(a)
            }
        }
        var attrs: [AnyHashable: Any] = [:]
        if let t = spec.title { attrs[PDFDocumentAttribute.titleAttribute] = t }
        if let a = spec.author { attrs[PDFDocumentAttribute.authorAttribute] = a }
        if let s = spec.subject { attrs[PDFDocumentAttribute.subjectAttribute] = s }
        doc.documentAttributes = attrs

        var options: [PDFDocumentWriteOption: Any] = [:]
        if let o = ownerPassword { options[.ownerPasswordOption] = o }
        if let u = userPassword { options[.userPasswordOption] = u }
        let ok = options.isEmpty ? doc.write(to: url) : doc.write(to: url, withOptions: options)
        precondition(ok, "falha ao gravar PDF de teste")
        try fixNavigation(spec, at: url, encrypted: !options.isEmpty)
        return doc
    }

    /// O PDFKit do macOS 27.2 grava destinos de link criados em memória como "[/#2323N …]" e não
    /// grava sumário novo. O qpdf conserta os destinos e grava o sumário da especificação.
    static func fixNavigation(_ spec: TestDocSpec, at url: URL, encrypted: Bool) throws {
        let hasInternal = spec.pages.contains { $0.internalLink != nil }
        guard hasInternal || !spec.outline.isEmpty else { return }
        precondition(!encrypted, "PDF de teste cifrado com navegação: o qpdf gravaria sem cifra")
        let q = try QPDFDocument(contentsOf: url)
        try q.resolvePageIndexDestinations()
        var items: [QPDFDocument.OutlineItem] = []
        var lastTop: Int?
        for entry in spec.outline {
            let dest = "[\(try q.sourcePageReference(entry.page)) /XYZ 0 700 null]"
            let parent = entry.level == 0 ? nil : lastTop
            items.append(.init(title: entry.title, parent: parent, destination: dest))
            if parent == nil { lastTop = items.count - 1 }
        }
        if !items.isEmpty { try q.setOutline(items) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        try q.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func noiseImage(side: Int, seed: UInt64) -> CGImage? {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var bytes = [UInt8](repeating: 0, count: side * side)
        for i in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        return ctx?.makeImage()
    }

    /// CTFontCreateWithName concorrente trava no XPC do registro de fontes;
    /// os testes rodam em paralelo, então a fonte é criada uma vez, sob lock.
    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var cachedFont: CTFont?
    static var font: CTFont {
        fontLock.lock()
        defer { fontLock.unlock() }
        if let f = cachedFont { return f }
        let f = CTFontCreateWithName(fontName as CFString, 11, nil)
        cachedFont = f
        return f
    }

    static func drawText(_ ctx: CGContext, page: Int, spec: TestPageSpec) {
        let font = Self.font
        let box = spec.crop ?? spec.media
        for l in 0..<spec.lines {
            let text = "p\(page)l\(l) lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore"
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: box.minX + 20, y: box.maxY - 30 - CGFloat(l) * 14)
            CTLineDraw(line, ctx)
        }
    }

    // MARK: - Leitura

    static let boxes: [(String, PDFDisplayBox, CGPDFBox)] = [
        ("media", .mediaBox, .mediaBox), ("crop", .cropBox, .cropBox), ("trim", .trimBox, .trimBox),
        ("bleed", .bleedBox, .bleedBox), ("art", .artBox, .artBox),
    ]

    static func cgPage(_ url: URL, _ index: Int) -> CGPDFPage {
        let doc = CGPDFDocument(url as CFURL)!
        // Saída de origem criptografada abre com senha vazia.
        if !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        return doc.page(at: index + 1)!
    }

    /// Caixas segundo o CGPDFDocument (leitura independente do PDFKit).
    static func cgBoxes(_ url: URL, page index: Int) -> [String: CGRect] {
        let page = cgPage(url, index)
        return Dictionary(uniqueKeysWithValues: boxes.map { ($0.0, page.getBoxRect($0.2)) })
    }

    static func pdfkitBoxes(_ url: URL, page index: Int) -> [String: CGRect] {
        let page = PDFDocument(url: url)!.page(at: index)!
        return Dictionary(uniqueKeysWithValues: boxes.map { ($0.0, page.bounds(for: $0.1)) })
    }

    /// Tamanho exibido (caixa efetiva girada) segundo o CGPDFDocument.
    static func cgDisplaySize(_ url: URL, page index: Int) -> CGSize {
        let page = cgPage(url, index)
        let r = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? r.size : CGSize(width: r.height, height: r.width)
    }

    /// Retângulo (espaço de página exibido, origem no canto inferior esquerdo da
    /// página exibida, 1 px/pt) dos pixels escuros.
    static func inkRect(_ url: URL, page index: Int) -> CGRect? {
        let page = cgPage(url, index)
        let size = cgDisplaySize(url, page: index)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<h {
            for x in 0..<w where buf[row * w + x] < 128 {
                // linha 0 da memória = topo; converte para y para cima.
                let y = h - 1 - row
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Planos

    static let viewport = ViewportProfile.booksPortrait

    /// Colocação que leva `rect` (espaço de página) à página de saída inteira.
    static func placement(source: Int, rect: CGRect, scale: CGFloat? = nil) -> Placement {
        let s = scale ?? viewport.sizePt.width / rect.width
        let t = CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: s, y: s))
        return Placement(sourcePage: source, sourceRect: rect, transform: t)
    }

    static func plan(_ items: [(source: Int, rect: CGRect)], recipeID: String = "receita-teste") -> LayoutPlan {
        LayoutPlan(profile: viewport,
                   pages: items.map { OutputPage(sizePt: viewport.sizePt, placements: [placement(source: $0.source, rect: $0.rect)]) },
                   recipe: Recipe(id: recipeID))
    }

    /// Janela com a proporção do viewport, largura `width`.
    static func window(x: CGFloat, y: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: width * viewport.aspect)
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipdfmini-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
