import Foundation
import CoreGraphics
import PDFKit
import Testing
import MiniGeometry
import PDFAnalysis
import LayoutEngine
import SyntheticCorpus
@testable import PDFWriting

// Apoio dos testes do PlacementWriter: análise montada da verdade do corpus
// (sem o PDFAnalysis, em mudança paralela), render e extração independentes.

enum CorpusCache {
    static let scenarios: [Scenario] = [.arxivTwoColumn, .reportWithFigures, .navigation, .rotatedPages,
                                        .offsetBoxes, .tallFigure]
    /// Gerados em série: o corpus cria CTFont sob lock, mas não há motivo para disputar.
    static let docs: [Scenario: SyntheticDocument] = {
        var out: [Scenario: SyntheticDocument] = [:]
        for s in scenarios { out[s] = Corpus.make(s) }
        return out
    }()

    static func doc(_ s: Scenario) -> SyntheticDocument { docs[s]! }
}

/// `DocumentAnalysis` com os blocos/linhas de verdade do cenário.
func analysis(from doc: SyntheticDocument) -> DocumentAnalysis {
    let x = doc.truth.bodyXHeightPt
    func line(_ r: CGRect) -> Line { Line(rect: r, baseline: r.minY + 0.22 * r.height, xHeightPt: x) }
    let pages = doc.truth.pages.enumerated().map { i, t in
        PageAnalysis(index: i,
                     boxes: PageBoxes(media: t.mediaBox, crop: t.cropBox ?? t.mediaBox, trim: t.trimBox, bleed: t.bleedBox),
                     geometry: t.geometry,
                     kind: t.isScan ? .scan : (t.inkBox == nil ? .empty : .digitalText),
                     inkBox: t.inkBox,
                     lines: t.lines.map(line),
                     blocks: t.blocks.map { b in
                         Block(rect: b.rect, type: BlockType(rawValue: b.type) ?? .unknown, lines: b.lines.map(line),
                               column: b.column)
                     },
                     bodyXHeightPt: t.inkBox == nil ? nil : x,
                     smallestXHeightPt: t.inkBox == nil ? nil : x)
    }
    return DocumentAnalysis(sha256: doc.scenario.rawValue, pageCount: pages.count, pages: pages, kind: .unknown,
                            bodyXHeightPt: x)
}

/// Cenário × estratégia com o PDF de origem gravado e a saída escrita.
struct WrittenCase {
    let name: String
    let doc: SyntheticDocument
    let analysis: DocumentAnalysis
    let plan: LayoutPlan
    let dir: URL
    let src: URL
    let out: URL
    let result: PlacementWriteResult

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

struct CaseSpec: Sendable, CustomTestStringConvertible {
    let scenario: Scenario
    let strategy: StrategyID
    var testDescription: String { "\(scenario.rawValue)-\(strategy.rawValue)" }

    static let all: [CaseSpec] = [
        CaseSpec(scenario: .arxivTwoColumn, strategy: .columns),
        CaseSpec(scenario: .arxivTwoColumn, strategy: .landscapeSlices),
        CaseSpec(scenario: .reportWithFigures, strategy: .landscapeSlices),
        CaseSpec(scenario: .reportWithFigures, strategy: .portraitSlices),
        CaseSpec(scenario: .reportWithFigures, strategy: .columns),
        CaseSpec(scenario: .navigation, strategy: .portraitSlices),
        CaseSpec(scenario: .rotatedPages, strategy: .portraitSlices),
        CaseSpec(scenario: .offsetBoxes, strategy: .portraitSlices),
        CaseSpec(scenario: .tallFigure, strategy: .landscapeSlices),
    ]

    func strategyImpl() -> any AdaptationStrategy {
        switch strategy {
        case .landscapeSlices: LandscapeSlicesStrategy()
        case .portraitSlices: PortraitSlicesStrategy()
        default: ColumnsStrategy()
        }
    }

    func write(options: WriteOptions = WriteOptions()) throws -> WrittenCase {
        let doc = CorpusCache.doc(scenario)
        let a = analysis(from: doc)
        let plan = strategyImpl().plan(a, .booksPortrait, Recipe(id: testDescription, strategy: strategy))
        let dir = TestPDF.tempDir()
        let src = dir.appendingPathComponent("src.pdf")
        let out = dir.appendingPathComponent("out.pdf")
        try doc.data.write(to: src)
        let r = try PlacementWriter().writeDetailed(plan, source: SourceDocument(url: src), to: out, options: options)
        return WrittenCase(name: testDescription, doc: doc, analysis: a, plan: plan, dir: dir, src: src, out: out, result: r)
    }
}

// MARK: - Render

/// Raster cinza 8 bits; linha 0 = topo.
struct GrayImage {
    let width: Int, height: Int
    let pixels: [UInt8]

    static let inkThreshold: UInt8 = 200
    func isInk(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] < Self.inkThreshold }
    var inkCount: Int { pixels.reduce(0) { $0 + ($1 < Self.inkThreshold ? 1 : 0) } }

    /// `setup` recebe o contexto (y para cima, 1 unidade = 1 px) e desenha.
    static func render(width: Int, height: Int, _ setup: (CGContext) -> Void) -> GrayImage {
        var buf = [UInt8](repeating: 255, count: width * height)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Como o GrayRaster do Validator: sem quantização de subpixel, a posição do glifo
            // não depende do caminho de matrizes (direto × dentro do Form XObject).
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            setup(ctx)
        }
        return GrayImage(width: width, height: height, pixels: buf)
    }
}

enum Render {
    static let ppp: CGFloat = 2

    static func cgDoc(_ url: URL) -> CGPDFDocument { CGPDFDocument(url as CFURL)! }

    /// Janela `rect` (espaço de página de `g`) da origem, na escala `scale`, com a rotação do
    /// próprio CoreGraphics (`getDrawingTransform`), não com `PageGeometry.userToPage`.
    static func sourceWindow(_ page: CGPDFPage, geometry g: PageGeometry, rect: CGRect, scale: CGFloat) -> GrayImage {
        let k = scale * ppp
        let w = Int((rect.width * k).rounded(.up)), h = Int((rect.height * k).rounded(.up))
        return GrayImage.render(width: w, height: h) { ctx in
            ctx.concatenate(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                .concatenating(CGAffineTransform(scaleX: k, y: k)))
            ctx.clip(to: rect)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: g.effectiveBox.origin, size: g.displaySize),
                                                     rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
        }
    }

    /// Região `rect` (espaço da saída) da página de saída, com a mesma grade de `sourceWindow`.
    static func outputRegion(_ page: CGPDFPage, rect: CGRect, width: Int, height: Int) -> GrayImage {
        GrayImage.render(width: width, height: height) { ctx in
            ctx.concatenate(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                .concatenating(CGAffineTransform(scaleX: ppp, y: ppp)))
            ctx.clip(to: rect)
            ctx.drawPDFPage(page)
        }
    }

    /// Página de saída inteira (y para cima no contexto; `pixels` com linha 0 no topo).
    static func outputPage(_ page: CGPDFPage, size: CGSize) -> GrayImage {
        GrayImage.render(width: Int((size.width * ppp).rounded(.up)), height: Int((size.height * ppp).rounded(.up))) { ctx in
            ctx.scaleBy(x: ppp, y: ppp)
            ctx.drawPDFPage(page)
        }
    }

    /// Pixels de tinta de `img` dentro de `r` (espaço da saída, página inteira a `ppp`).
    static func ink(_ img: GrayImage, in r: CGRect, pageHeight: CGFloat, below: UInt8 = GrayImage.inkThreshold) -> Int {
        let x0 = max(0, Int((r.minX * ppp).rounded(.down))), x1 = min(img.width, Int((r.maxX * ppp).rounded(.up)))
        let y0 = max(0, Int(((pageHeight - r.maxY) * ppp).rounded(.down)))
        let y1 = min(img.height, Int(((pageHeight - r.minY) * ppp).rounded(.up)))
        var n = 0
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) where img.pixels[y * img.width + x] < below { n += 1 } }
        return n
    }
}

/// Comparação colocação a colocação (o inv. 1b do Validator, por colocação).
///
/// O limiar binário de tinta (< 200) não serve de critério pixel a pixel: medido, saída
/// e referência diferem no máximo 4 níveis de cinza (antialiasing de borda de glifo,
/// direto × dentro do Form XObject), e um pixel de borda perto de 200 troca de lado
/// por 1 nível (0,1–0,4% da tinta). Deslocamento ou corte trocam pixels inteiros
/// (diferença até 255). Por isso: pixel diferente = |Δ| > `grayTolerance` (1/8 de
/// cobertura, 8× o ruído medido), com a tolerância de contagem do Validator.
struct PlacementDiff {
    static let grayTolerance = 32

    var outputPage: Int
    var placement: Int
    var referenceInk: Int
    var outputInk: Int
    /// Pixels com |Δ| > `grayTolerance`.
    var mismatched: Int
    /// Pixels que só trocam de lado no limiar de tinta (informativo).
    var thresholdFlips: Int
    var maxGrayDelta: Int

    /// Mesma tolerância do Validator (inv. 1b): max(4 px, 0,1% da tinta de referência).
    var tolerance: Double { max(4, 0.001 * Double(referenceInk)) }
    var ok: Bool { Double(mismatched) <= tolerance }
}

/// `excluded`: retângulos (espaço da saída) fora da comparação (marca de continuidade).
func comparePlacements(plan: LayoutPlan, source: URL, output: URL, geometries: (Int) -> PageGeometry,
                       excluded: (Int) -> [CGRect] = { _ in [] }) -> [PlacementDiff] {
    let src = Render.cgDoc(source), out = Render.cgDoc(output)
    var diffs: [PlacementDiff] = []
    for (o, page) in plan.pages.enumerated() {
        guard let outPage = out.page(at: o + 1) else { continue }
        for (k, p) in page.placements.enumerated() {
            let g = p.sourceGeometry ?? geometries(p.sourcePage)
            let ref = Render.sourceWindow(src.page(at: p.sourcePage + 1)!, geometry: g, rect: p.sourceRect, scale: p.scale)
            let outRect = p.sourceRect.applying(p.transform).standardized
            let img = Render.outputRegion(outPage, rect: outRect, width: ref.width, height: ref.height)
            // Linhas da imagem (topo = 0) cobertas por algum retângulo excluído.
            var skip = Set<Int>()
            for r in excluded(o) where r.intersects(outRect) {
                let top = Int(((outRect.maxY - r.maxY) * Render.ppp).rounded(.down))
                let bottom = Int(((outRect.maxY - r.minY) * Render.ppp).rounded(.up))
                for y in max(0, top)..<min(ref.height, max(top, bottom)) { skip.insert(y) }
            }
            var refInk = 0, outInk = 0, mismatch = 0, flips = 0, maxDelta = 0
            for y in 0..<ref.height where !skip.contains(y) {
                for x in 0..<ref.width {
                    let a = ref.isInk(x, y), b = img.isInk(x, y)
                    if a { refInk += 1 }
                    if b { outInk += 1 }
                    if a != b { flips += 1 }
                    let d = abs(Int(ref.pixels[y * ref.width + x]) - Int(img.pixels[y * ref.width + x]))
                    maxDelta = max(maxDelta, d)
                    if d > PlacementDiff.grayTolerance { mismatch += 1 }
                }
            }
            diffs.append(PlacementDiff(outputPage: o, placement: k, referenceInk: refInk, outputInk: outInk,
                                       mismatched: mismatch, thresholdFlips: flips, maxGrayDelta: maxDelta))
        }
    }
    return diffs
}

// MARK: - Texto

func wordList(_ s: String?) -> [String] {
    (s ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

struct Multiset: Equatable, CustomStringConvertible {
    var counts: [String: Int] = [:]

    init(_ items: [String] = []) { for w in items { counts[w, default: 0] += 1 } }

    var total: Int { counts.values.reduce(0, +) }

    mutating func add(_ items: [String], times: Int = 1) { for w in items { counts[w, default: 0] += times } }

    mutating func add(_ other: Multiset) { for (w, n) in other.counts { counts[w, default: 0] += n } }

    /// `self − other`, só a parte positiva.
    func minus(_ other: Multiset) -> Multiset {
        var r = Multiset()
        for (w, n) in counts where n - (other.counts[w] ?? 0) > 0 { r.counts[w] = n - (other.counts[w] ?? 0) }
        return r
    }

    func isSubset(of other: Multiset) -> Bool { counts.allSatisfy { (other.counts[$0.key] ?? 0) >= $0.value } }

    var description: String {
        counts.sorted { $0.key < $1.key }.prefix(20).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            + (counts.count > 20 ? " …(\(counts.count))" : "")
    }
}

func documentWords(_ url: URL) -> [String] {
    let d = PDFDocument(url: url)!
    return (0..<d.pageCount).flatMap { wordList(d.page(at: $0)?.string) }
}

/// Palavras dos indicadores de página desenhados pelo escritor.
func overlayWords(_ plan: LayoutPlan) -> [String] {
    plan.pages.flatMap { $0.overlays.flatMap { o -> [String] in
        if case .pageIndicator(let t, _) = o { return wordList(t) }
        return []
    } }
}

// MARK: - Diversos

extension LayoutPlan {
    var allPlacements: [(out: Int, placement: Placement)] {
        pages.enumerated().flatMap { i, o in o.placements.map { (i, $0) } }
    }

    var continuityMarks: [Int: [CGRect]] {
        var out: [Int: [CGRect]] = [:]
        for (i, p) in pages.enumerated() {
            for o in p.overlays { if case .continuityMark(let y) = o { out[i, default: []].append(CGRect(x: 0, y: y - 1.5, width: p.sizePt.width, height: 3)) } }
        }
        return out
    }
}

func nearPoint(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.01) -> Bool { hypot(a.x - b.x, a.y - b.y) < tol }

func fileSize(_ url: URL) -> Int64 { TestPDF.size(url) }

/// Ocorrências de `needle` nos bytes do arquivo.
func occurrences(of needle: String, in url: URL) -> Int {
    let data = (try? Data(contentsOf: url)) ?? Data()
    let n = Array(needle.utf8)
    var count = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let b = raw.bindMemory(to: UInt8.self)
        guard b.count >= n.count else { return }
        var i = 0
        while i <= b.count - n.count {
            if b[i] == n[0] && Array(b[i..<(i + n.count)]) == n { count += 1; i += n.count } else { i += 1 }
        }
    }
    return count
}

/// Form XObjects distintos (por identidade do stream no CGPDFDocument) referenciados pelas páginas.
func formXObjectCount(_ url: URL) -> Int {
    let doc = CGPDFDocument(url as CFURL)!
    var seen = Set<Int>()
    for i in 1...max(1, doc.numberOfPages) {
        guard let page = doc.page(at: i), let dict = page.dictionary else { continue }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { continue }
        CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(sd, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" {
                seen.insert(unsafeBitCast(stream, to: Int.self))
            }
            return true
        }, nil)
    }
    return seen.count
}

/// Linha de métrica para o relatório (stdout do teste).
func metric(_ s: String) { print("METRIC \(s)") }
