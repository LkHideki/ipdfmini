import Foundation
import LayoutEngine

// Contrato de escrita de PDF. PLAN.md §9.1.

public protocol PDFWriter: Sendable {
    func write(_ plan: LayoutPlan, source: SourceDocument, to url: URL, options: WriteOptions) async throws -> WriteReport
}

/// PDF de origem. `Placement.sourcePage` indexa as páginas daqui (base 0).
public struct SourceDocument: Sendable, Equatable {
    public var url: URL
    /// Senha do usuário, se o PDF for criptografado.
    public var password: String?

    public init(url: URL, password: String? = nil) {
        self.url = url
        self.password = password
    }
}

public struct WriteOptions: Sendable, Equatable {
    /// Prefixo do campo `Producer`; o campo final é "<producer> recipe:<id>".
    /// A devolução de anotações ao original (§12.2) identifica a receita por ele.
    public var producer: String
    /// Sobrescreve `plan.recipe.id` no `Producer`.
    public var recipeID: String?
    public var title: String?
    public var author: String?
    /// Descarta assunto, palavras-chave, criador, título e autor da origem
    /// (título e autor ainda podem ser fornecidos acima).
    public var clearMetadata: Bool

    public init(producer: String = "iPDFmini \(PDFWriting.version)", recipeID: String? = nil,
                title: String? = nil, author: String? = nil, clearMetadata: Bool = false) {
        self.producer = producer
        self.recipeID = recipeID
        self.title = title
        self.author = author
        self.clearMetadata = clearMetadata
    }
}

public enum WriteWarning: Codable, Sendable, Equatable {
    /// A janela gravada não tem a proporção de `OutputPage.sizePt`.
    case aspectMismatch(outputPage: Int, relativeError: Double)
    /// Saída acima do orçamento do escritor: 1,1× no BoxWriter (§9.3), 1,3× no PlacementWriter (§17 M3).
    case sizeBudgetExceeded(ratio: Double)
    /// O BoxWriter não desenha sobreposições (indicador de página etc.).
    case overlaysIgnored(count: Int)
    /// Não foi possível gravar o `Producer` (xref não clássica); o vínculo com a receita se perde.
    case producerNotApplied
}

public struct WriteReport: Codable, Sendable, Equatable {
    public var outputPageCount: Int
    public var bytes: Int64
    public var warnings: [WriteWarning]

    public init(outputPageCount: Int, bytes: Int64, warnings: [WriteWarning] = []) {
        self.outputPageCount = outputPageCount
        self.bytes = bytes
        self.warnings = warnings
    }
}

public enum WriteError: Error, Sendable, Equatable {
    case cannotOpen(URL)
    /// PDF criptografado e nenhuma senha informada.
    case encryptedWithoutPassword(URL)
    case wrongPassword(URL)
    /// O plano exige um recurso que o escritor não tem (ex.: 2 colocações, rotação).
    case unsupportedPlan(String)
    case writeFailed(URL)
}

public enum PDFWriting {
    public static let version = "0.1"
}
