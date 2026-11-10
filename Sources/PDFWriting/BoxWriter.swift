import Foundation
import PDFKit
import CoreGraphics
import MiniGeometry
import LayoutEngine

/// Escritor por caixas (PDFKit). PLAN.md §9.1 e §6.4.
///
/// Só altera as caixas das páginas; o content stream, o sumário, os links e as
/// anotações ficam como estão. Aceita planos de 1 colocação por página de saída
/// com escala uniforme e sem rotação (E0, E1 e fatias simples).
public struct BoxWriter: PDFWriter {
    public init() {}

    public func write(_ plan: LayoutPlan, source: SourceDocument, to url: URL,
                      options: WriteOptions) async throws -> WriteReport {
        try Self.validateStructure(plan)

        guard let doc = PDFDocument(url: source.url) else { throw WriteError.cannotOpen(source.url) }
        if doc.isLocked {
            guard let password = source.password else { throw WriteError.encryptedWithoutPassword(source.url) }
            guard doc.unlock(withPassword: password) else { throw WriteError.wrongPassword(source.url) }
        }

        let pageCount = doc.pageCount
        for (i, out) in plan.pages.enumerated() {
            let s = out.placements[0].sourcePage
            guard (0..<pageCount).contains(s) else {
                throw WriteError.unsupportedPlan("página de saída \(i) usa a página de origem \(s); o PDF tem \(pageCount)")
            }
        }

        // Geometria de origem lida antes de qualquer alteração: as caixas
        // mudam, e cópias de uma página já alterada não podem servir de base.
        var geometry: [Int: PageGeometry] = [:]
        for s in Set(plan.pages.map { $0.placements[0].sourcePage }) {
            geometry[s] = Self.geometry(of: doc.page(at: s)!)
        }

        var warnings: [WriteWarning] = []
        var used = Set<Int>()
        var ordered: [PDFPage] = []
        var copies: [PDFPage] = []
        for (i, out) in plan.pages.enumerated() {
            let placement = out.placements[0]
            let s = placement.sourcePage
            let page: PDFPage
            if used.insert(s).inserted {
                page = doc.page(at: s)!
            } else {
                // Fatia: página repetida vira cópia, com caixas próprias.
                guard let copy = doc.page(at: s)!.copy() as? PDFPage else {
                    throw WriteError.unsupportedPlan("não foi possível copiar a página de origem \(s)")
                }
                page = copy
                copies.append(copy)
            }
            let box = geometry[s]!.toUser(placement.sourceRect)
            Self.setAllBoxes(of: page, to: box)
            ordered.append(page)

            let aspectOut = out.sizePt.width / out.sizePt.height
            let aspectBox = placement.sourceRect.width / placement.sourceRect.height
            let error = abs(aspectBox / aspectOut - 1)
            if error > 0.001 { warnings.append(.aspectMismatch(outputPage: i, relativeError: Double(error))) }
            if !out.overlays.isEmpty { warnings.append(.overlaysIgnored(count: out.overlays.count)) }
        }

        // Páginas fora do plano saem; de trás para frente para não deslocar índices.
        for s in stride(from: pageCount - 1, through: 0, by: -1) where !used.contains(s) {
            doc.removePage(at: s)
        }
        for copy in copies { doc.insert(copy, at: doc.pageCount) }

        // Ordem do plano, por trocas no próprio documento (o sumário aponta para os objetos de página).
        var current = (0..<doc.pageCount).map { doc.page(at: $0)! }
        for (i, target) in ordered.enumerated() {
            guard let j = current.firstIndex(where: { $0 === target }) else { continue }
            if j != i {
                doc.exchangePage(at: i, withPageAt: j)
                current.swapAt(i, j)
            }
        }

        Self.applyMetadata(to: doc, plan: plan, options: options)

        // Saída sem senha (§9.2). Um `write(to:)` simples manteria a criptografia e a senha
        // da origem; senhas vazias gravam um arquivo que abre sem pedir nada.
        let ok = doc.isEncrypted
            ? doc.write(to: url, withOptions: [.userPasswordOption: "", .ownerPasswordOption: ""])
            : doc.write(to: url)
        guard ok else { throw WriteError.writeFailed(url) }
        // O Quartz impõe o próprio Producer na gravação; regrava-se depois.
        let producer = "\(options.producer) recipe:\(options.recipeID ?? plan.recipe.id)"
        if !InfoPatch.setProducer(producer, in: url) { warnings.append(.producerNotApplied) }

        let bytes = Self.fileSize(url)
        let sourceBytes = Self.fileSize(source.url)
        if sourceBytes > 0 {
            let ratio = Double(bytes) / Double(sourceBytes)
            if ratio > 1.1 { warnings.append(.sizeBudgetExceeded(ratio: ratio)) }
        }
        return WriteReport(outputPageCount: plan.pages.count, bytes: bytes, warnings: warnings)
    }

    // MARK: - Validação

    static func validateStructure(_ plan: LayoutPlan) throws {
        guard !plan.pages.isEmpty else { throw WriteError.unsupportedPlan("plano sem páginas") }
        for (i, out) in plan.pages.enumerated() {
            guard out.placements.count == 1 else {
                throw WriteError.unsupportedPlan("página de saída \(i) tem \(out.placements.count) colocações; o BoxWriter aceita 1")
            }
            let p = out.placements[0]
            let t = p.transform
            let scale = t.a
            let tol = 1e-6 * max(1, abs(scale))
            guard scale > 0, abs(t.d - scale) <= tol, abs(t.b) <= tol, abs(t.c) <= tol else {
                throw WriteError.unsupportedPlan("página de saída \(i): transformação com rotação, espelho ou escala não uniforme")
            }
            guard p.hidden.isEmpty else {
                throw WriteError.unsupportedPlan("página de saída \(i): regiões ocultas exigem redesenho (PlacementWriter)")
            }
            let r = p.sourceRect
            guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, r.width > 0, r.height > 0 else {
                throw WriteError.unsupportedPlan("página de saída \(i): sourceRect inválido")
            }
        }
    }

    // MARK: - PDFKit

    /// `bounds(for:)` e `setBounds` do PDFKit trabalham em espaço do usuário,
    /// sem rotação (verificado em teste); `/Rotate` fica à parte.
    static func geometry(of page: PDFPage) -> PageGeometry {
        let media = page.bounds(for: .mediaBox)
        var effective = media.intersection(page.bounds(for: .cropBox))
        if effective.isNull || effective.isEmpty { effective = media }
        return PageGeometry(effectiveBox: effective, rotation: page.rotation)
    }

    /// Media primeiro: o PDFKit recorta as demais caixas pela media vigente.
    static func setAllBoxes(of page: PDFPage, to rect: CGRect) {
        page.setBounds(rect, for: .mediaBox)
        for box in [PDFDisplayBox.cropBox, .trimBox, .bleedBox, .artBox] {
            page.setBounds(rect, for: box)
        }
    }

    static func applyMetadata(to doc: PDFDocument, plan: LayoutPlan, options: WriteOptions) {
        var attrs = doc.documentAttributes ?? [:]
        if options.clearMetadata {
            for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute,
                        .keywordsAttribute, .creatorAttribute] {
                attrs.removeValue(forKey: key)
            }
        }
        if let title = options.title { attrs[PDFDocumentAttribute.titleAttribute] = title }
        if let author = options.author { attrs[PDFDocumentAttribute.authorAttribute] = author }
        doc.documentAttributes = attrs
    }

    static func fileSize(_ url: URL) -> Int64 {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return n?.int64Value ?? 0
    }
}
