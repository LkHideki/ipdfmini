import Foundation
import CoreGraphics
import PDFKit
import MiniGeometry
import LayoutEngine
import QPDFKit

/// Escritor por colocações (qpdf). PLAN.md §9.1, E3–E6.
///
/// Cada página de origem vira um Form XObject único (o content stream é gravado
/// uma vez) e cada colocação o referencia com clip e matriz. Links, sumário,
/// anotações, `PageLabels` e Info também vão pelo qpdf: regravar pelo PDFKit
/// achata os Form XObjects (o Quartz reemite o conteúdo por colocação; medido:
/// até 3,3× o tamanho). O PDFKit só lê a origem (anotações e sumário).
/// Escrita atômica: temporário no diretório do destino e `rename` no fim.
public struct PlacementWriter: PDFWriter {
    /// Saída acima disto × a origem gera aviso (§9.3/§17 M3, vetor).
    public var sizeBudget: Double
    /// `PageLabels` com o número da página de origem (o leitor mostra "37" nas fatias da p. 37).
    public var writesPageLabels: Bool

    public init(sizeBudget: Double = 1.3, writesPageLabels: Bool = true) {
        self.sizeBudget = sizeBudget
        self.writesPageLabels = writesPageLabels
    }

    public func write(_ plan: LayoutPlan, source: SourceDocument, to url: URL,
                      options: WriteOptions) async throws -> WriteReport {
        try writeDetailed(plan, source: source, to: url, options: options).report
    }

    /// Entradas do catálogo que apontam para as páginas removidas ou descrevem a estrutura
    /// antiga (tags, formulários): ficariam quebradas e arrastariam objetos mortos para a saída.
    /// O XMP (`/Metadata`) sai porque contradiria o Info novo (Producer com a receita, §12.2).
    static let staleCatalogKeys = ["/Outlines", "/Dests", "/OpenAction", "/AcroForm", "/StructTreeRoot",
                                   "/MarkInfo", "/PageLabels", "/Threads", "/Metadata"]

    /// Como `write`, com o mapa e as contagens do remapeamento.
    public func writeDetailed(_ plan: LayoutPlan, source: SourceDocument, to url: URL,
                              options: WriteOptions) throws -> PlacementWriteResult {
        try Self.validate(plan)
        let doc = try Self.open(source)
        // O PDFKit só lê anotações e sumário da origem; o qpdf já validou a senha.
        guard let reader = PDFDocument(url: source.url) else { throw WriteError.cannotOpen(source.url) }
        if reader.isLocked, !(source.password.map { reader.unlock(withPassword: $0) } ?? false) {
            throw WriteError.wrongPassword(source.url)
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).ipdfmini-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mapping: PlanMapping
        var stats = RemapStats()
        do {
            let geometries = try Self.buildPages(plan, in: doc)
            mapping = PlanMapping(plan: plan, sourceGeometries: geometries)
            let refs = try (0..<plan.pages.count).map { try doc.outputPageReference($0) }
            let remap = AnnotationRemap(source: reader, mapping: mapping, pageRefs: refs)
            for a in remap.annotations(stats: &stats) { try doc.addAnnotation(a.dictionary, toPage: a.page) }
            for key in Self.staleCatalogKeys { try doc.setCatalogEntry(key, value: nil) }
            try doc.setCatalogEntry("/Names", subkey: "/Dests", value: nil)
            try doc.setOutline(remap.outline(stats: &stats))
            if writesPageLabels, let labels = Self.pageLabels(plan) { try doc.setCatalogEntry("/PageLabels", value: labels) }
            try Self.applyMetadata(doc, plan: plan, options: options)
            try doc.removeSourcePages()
            try doc.write(to: tmp)
        } catch let e as WriteError {
            throw e
        } catch {
            throw WriteError.writeFailed(url)
        }
        guard rename(tmp.path, url.path) == 0 else { throw WriteError.writeFailed(url) }

        var warnings: [WriteWarning] = []
        let bytes = BoxWriter.fileSize(url)
        let sourceBytes = BoxWriter.fileSize(source.url)
        if sourceBytes > 0 {
            let ratio = Double(bytes) / Double(sourceBytes)
            if ratio > sizeBudget { warnings.append(.sizeBudgetExceeded(ratio: ratio, budget: sizeBudget)) }
        }
        let report = WriteReport(outputPageCount: plan.pages.count, bytes: bytes, warnings: warnings)
        return PlacementWriteResult(report: report, mapping: mapping, remap: stats)
    }

    // MARK: - Validação

    static func validate(_ plan: LayoutPlan) throws {
        guard !plan.pages.isEmpty else { throw WriteError.unsupportedPlan("plano sem páginas") }
        func finite(_ r: CGRect) -> Bool { r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite }
        for (i, out) in plan.pages.enumerated() {
            let s = out.sizePt
            guard s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else {
                throw WriteError.unsupportedPlan("página de saída \(i): tamanho inválido \(s)")
            }
            for p in out.placements {
                let r = p.sourceRect
                guard finite(r), r.width > 0, r.height > 0 else {
                    throw WriteError.unsupportedPlan("página de saída \(i): sourceRect inválido")
                }
                let t = p.transform
                let det = t.a * t.d - t.b * t.c
                guard [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite), abs(det) > 1e-12 else {
                    throw WriteError.unsupportedPlan("página de saída \(i): transformação singular ou não finita")
                }
                guard p.hidden.allSatisfy(finite) else {
                    throw WriteError.unsupportedPlan("página de saída \(i): região oculta inválida")
                }
            }
        }
    }

    // MARK: - qpdf

    static func open(_ source: SourceDocument) throws -> QPDFDocument {
        do {
            return try QPDFDocument(contentsOf: source.url, password: source.password)
        } catch let e as QPDFError {
            switch e.kind {
            case .password: throw source.password == nil ? WriteError.encryptedWithoutPassword(source.url)
                                                         : WriteError.wrongPassword(source.url)
            default: throw WriteError.cannotOpen(source.url)
            }
        }
    }

    /// Cria as páginas de saída com colocações, máscaras e sobreposições; devolve a
    /// geometria lida (Crop∩Media e /Rotate) de cada página de origem usada.
    static func buildPages(_ plan: LayoutPlan, in doc: QPDFDocument) throws -> [Int: PageGeometry] {
        let count = try doc.sourcePageCount
        var geometries: [Int: PageGeometry] = [:]
        for (i, out) in plan.pages.enumerated() {
            for p in out.placements where geometries[p.sourcePage] == nil {
                guard (0..<count).contains(p.sourcePage) else {
                    throw WriteError.unsupportedPlan("página de saída \(i) usa a página de origem \(p.sourcePage); o PDF tem \(count)")
                }
                let info = try doc.sourcePageInfo(at: p.sourcePage)
                geometries[p.sourcePage] = PageGeometry(effectiveBox: info.cropBox.cgRect, rotation: info.rotation)
            }
        }
        let corner = plan.profile.cornerRadiusPt
        for out in plan.pages {
            let page = try doc.addPage(mediaBox: QPDFRect(llx: 0, lly: 0, urx: Double(out.sizePt.width),
                                                          ury: Double(out.sizePt.height)))
            var masks: [CGRect] = []
            for p in out.placements {
                // A geometria do plano manda (pode vir da TrimBox); sem ela, a lida aqui.
                let g = p.sourceGeometry ?? geometries[p.sourcePage]!
                // Form XObject = espaço do usuário bruto: clip nele, rotação composta na matriz.
                let clip = g.toUser(p.sourceRect)
                let m = g.userToPage.concatenating(p.transform)
                try doc.place(sourcePage: p.sourcePage, onto: page, clip: QPDFRect(clip),
                              matrix: QPDFMatrix(a: m.a, b: m.b, c: m.c, d: m.d, e: m.tx, f: m.ty))
                for h in p.hidden {
                    let x = h.standardized.intersection(p.sourceRect)
                    guard !x.isNull, x.width > 0, x.height > 0 else { continue }
                    masks.append(x.applying(p.transform).standardized)
                }
            }
            let ops = OverlayContent.masks(masks)
                + out.overlays.map { OverlayContent.ops(for: $0, page: out.sizePt, cornerRadius: corner) }.joined()
            if !ops.isEmpty { try doc.appendContent(ops, toPage: page) }
        }
        return geometries
    }

    /// Faixas decimais com o número (base 1) da página de origem da 1ª colocação; uma faixa
    /// nova só onde a contagem corrida diverge (fatias repetem o número).
    static func pageLabels(_ plan: LayoutPlan) -> String? {
        var ranges: [String] = []
        var expected: Int?
        for (i, out) in plan.pages.enumerated() {
            let want = out.placements.first.map { $0.sourcePage + 1 } ?? expected ?? 1
            if want != expected { ranges.append("\(i) << /S /D /St \(want) >>") }
            expected = want + 1
        }
        return ranges.isEmpty ? nil : "<< /Nums [\(ranges.joined(separator: " "))] >>"
    }

    /// Título e autor como no `BoxWriter`; `Producer` com o id da receita (§12.2).
    static func applyMetadata(_ doc: QPDFDocument, plan: LayoutPlan, options: WriteOptions) throws {
        if options.clearMetadata {
            for key in ["/Title", "/Author", "/Subject", "/Keywords", "/Creator"] { try doc.setInfo(key, nil) }
        }
        if let t = options.title { try doc.setInfo("/Title", t) }
        if let a = options.author { try doc.setInfo("/Author", a) }
        try doc.setInfo("/Producer", "\(options.producer) recipe:\(options.recipeID ?? plan.recipe.id)")
    }
}

/// Resultado detalhado do `PlacementWriter`.
public struct PlacementWriteResult: Sendable {
    public var report: WriteReport
    public var mapping: PlanMapping
    public var remap: RemapStats
}

extension QPDFRect {
    init(_ r: CGRect) {
        self.init(llx: Double(r.minX), lly: Double(r.minY), urx: Double(r.maxX), ury: Double(r.maxY))
    }

    var cgRect: CGRect { CGRect(x: llx, y: lly, width: urx - llx, height: ury - lly) }
}
