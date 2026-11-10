import CoreGraphics
import CryptoKit
import Foundation
import MiniGeometry
import PDFKit

public enum AnalysisError: Error, Equatable, Sendable {
    case unreadable
    case locked
}

/// Ponto de entrada da análise. PLAN.md §5 e §14.2.
public struct DocumentAnalyzer: Sendable {
    public struct Options: Sendable, Equatable {
        /// Resolução do raster de análise (2 px/pt = 144 dpi).
        public var pixelsPerPoint: CGFloat
        /// Tarefas simultâneas; `nil` = núcleos de desempenho.
        public var maxConcurrency: Int?

        public init(pixelsPerPoint: CGFloat = 2, maxConcurrency: Int? = nil) {
            self.pixelsPerPoint = pixelsPerPoint
            self.maxConcurrency = maxConcurrency
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func analyze(url: URL) async throws -> DocumentAnalysis {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await analyze(data: data)
    }

    public func analyze(data: Data) async throws -> DocumentAnalysis {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let probe = try Self.open(data)
        let count = probe.pageCount
        let title = probe.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let author = probe.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let workers = max(1, min(options.maxConcurrency ?? Self.performanceCores(), count))
        let ppp = options.pixelsPerPoint

        var works = [PageWork?](repeating: nil, count: count)
        try await withThrowingTaskGroup(of: [PageWork].self) { group in
            for w in 0..<workers {
                group.addTask {
                    // cada tarefa abre a própria instância: PDFDocument/CGPDFDocument
                    // não são seguros entre threads
                    let doc = try Self.open(data)
                    var out: [PageWork] = []
                    // distribuição intercalada: equilibra páginas pesadas sem fila compartilhada
                    for i in stride(from: w, to: count, by: workers) {
                        try Task.checkCancellation()
                        out.append(autoreleasepool {
                            guard let page = doc.page(at: i) else { return Self.unreadablePage(i) }
                            return PageAnalyzer.analyze(page: page, index: i, pixelsPerPoint: ppp)
                        })
                    }
                    return out
                }
            }
            for try await chunk in group {
                for w in chunk { works[w.analysis.index] = w }
            }
        }
        var pages = works.enumerated().map { $0.element ?? Self.unreadablePage($0.offset) }
        HeaderFooter.detect(&pages)
        return DocumentAnalysis(sha256: sha, pageCount: count, pages: pages.map(\.analysis),
                                kind: DocumentClassifier.classify(pages),
                                bodyXHeightPt: XHeightStats.modes(pages.flatMap(\.samples))?.body,
                                title: title, author: author)
    }

    private static func open(_ data: Data) throws -> PDFDocument {
        guard let doc = PDFDocument(data: data) else { throw AnalysisError.unreadable }
        // só senha de dono (permissões) abre com senha vazia
        if doc.isLocked && !doc.unlock(withPassword: "") { throw AnalysisError.locked }
        return doc
    }

    private static func unreadablePage(_ i: Int) -> PageWork {
        let a = PageAnalysis(index: i, boxes: PageBoxes(media: .zero, crop: .zero),
                             geometry: PageGeometry(effectiveBox: .zero, rotation: 0), kind: .empty,
                             inkBox: nil, warnings: [.renderFailed("página ilegível")])
        return PageWork(analysis: a, lineTexts: [], columns: 0, imageCoverage: 0, samples: [])
    }

    /// Núcleos de desempenho (P-cores); fallback para os ativos.
    static func performanceCores() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &v, &size, nil, 0) == 0, v > 0 { return Int(v) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}
