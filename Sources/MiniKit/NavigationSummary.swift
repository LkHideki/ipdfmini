import CoreGraphics
import Foundation
import LayoutEngine
import PDFKit
import PDFWriting

/// Contagens de navegação da conversão, para a interface mostrar
/// "Sumário: N de N preservados" sem garimpar as métricas do invariante 5.
///
/// Campo opcional em `ConversionReport`: JSON antigo (sem ele) continua decodificável.
public struct NavigationSummary: Codable, Sendable, Equatable {
    public var sourceOutlineItems: Int
    public var outputOutlineItems: Int
    /// Itens com o mesmo rótulo e destino na página de saída que o plano dá para o destino da origem.
    public var preservedOutlineItems: Int
    /// Links com destino interno (GoTo), em todas as páginas.
    public var sourceInternalLinks: Int
    /// Na saída do `PlacementWriter` um link que cruza colocações vira vários pedaços.
    public var outputInternalLinks: Int

    public init(sourceOutlineItems: Int, outputOutlineItems: Int, preservedOutlineItems: Int,
                sourceInternalLinks: Int, outputInternalLinks: Int) {
        self.sourceOutlineItems = sourceOutlineItems
        self.outputOutlineItems = outputOutlineItems
        self.preservedOutlineItems = preservedOutlineItems
        self.sourceInternalLinks = sourceInternalLinks
        self.outputInternalLinks = outputInternalLinks
    }

    /// Todos os itens do sumário da origem chegaram com destino na página certa.
    public var outlinePreserved: Bool {
        preservedOutlineItems == sourceOutlineItems && outputOutlineItems == sourceOutlineItems
    }

    /// Itens do sumário, em profundidade (o que o leitor mostra expandido).
    public static func outlineItems(_ doc: PDFDocument) -> [PDFOutline] {
        var out: [PDFOutline] = []
        func walk(_ o: PDFOutline) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                out.append(c)
                walk(c)
            }
        }
        if let root = doc.outlineRoot { walk(root) }
        return out
    }

    /// Contagem do sumário de um PDF em disco; `nil` se não abrir.
    public static func outlineItemCount(url: URL, password: String? = nil) -> Int? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked && !doc.unlock(withPassword: password ?? "") { return nil }
        return outlineItems(doc).count
    }

    static func destination(_ o: PDFOutline) -> PDFDestination? {
        o.destination ?? (o.action as? PDFActionGoTo)?.destination
    }

    static func internalLinkCount(_ doc: PDFDocument) -> Int {
        var n = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            n += page.annotations.count { a in
                a.type == "Link" && (a.destination != nil || a.action is PDFActionGoTo)
            }
        }
        return n
    }

    /// Mede origem e saída já gravadas. A página esperada vem do `PlanMapping` (a
    /// mesma função que os escritores usam), então vale para os dois backends: no
    /// `BoxWriter` cada página de origem tem uma só página de saída.
    public static func measure(plan: LayoutPlan, source: SourceDocument, output: URL) throws -> NavigationSummary {
        let srcData = try Data(contentsOf: source.url, options: .mappedIfSafe)
        let outData = try Data(contentsOf: output, options: .mappedIfSafe)
        let src = try Validator.open(srcData, password: source.password, url: source.url, isSource: true)
        let out = try Validator.open(outData, password: nil, url: output, isSource: false)
        let mapping = PlanMapping(plan: plan)
        let si = outlineItems(src), oi = outlineItems(out)
        var preserved = 0
        for (s, o) in zip(si, oi) where (s.label ?? "") == (o.label ?? "") {
            let sd = destination(s), od = destination(o)
            guard let want = Validator.expectedDestination(sd, src: src, mapping: mapping) else { continue }
            guard let want else {
                if od == nil { preserved += 1 }
                continue
            }
            guard let page = od?.page else { continue }
            if out.index(for: page) == want.out { preserved += 1 }
        }
        return NavigationSummary(sourceOutlineItems: si.count, outputOutlineItems: oi.count, preservedOutlineItems: preserved,
                                 sourceInternalLinks: internalLinkCount(src), outputInternalLinks: internalLinkCount(out))
    }
}
