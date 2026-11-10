import CQPDF
import Foundation

/// Retângulo PDF (llx, lly, urx, ury), em pontos.
public struct QPDFRect: Sendable, Equatable {
    public var llx: Double, lly: Double, urx: Double, ury: Double

    public init(llx: Double, lly: Double, urx: Double, ury: Double) {
        self.llx = llx; self.lly = lly; self.urx = urx; self.ury = ury
    }

    public var width: Double { urx - llx }
    public var height: Double { ury - lly }
    var array: [Double] { [llx, lly, urx, ury] }
}

/// Matriz afim do PDF: `x' = a·x + c·y + e`, `y' = b·x + d·y + f`.
public struct QPDFMatrix: Sendable, Equatable {
    public var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static let identity = QPDFMatrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public static func translation(x: Double, y: Double) -> QPDFMatrix {
        QPDFMatrix(a: 1, b: 0, c: 0, d: 1, e: x, f: y)
    }

    var array: [Double] { [a, b, c, d, e, f] }
}

/// Caixas e rotação de uma página de origem. A rotação é 0, 90, 180 ou 270.
public struct QPDFPageInfo: Sendable, Equatable {
    public var mediaBox: QPDFRect
    public var cropBox: QPDFRect
    public var rotation: Int
}

public struct QPDFError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Kind: Int32, Sendable {
        case invalidArgument = 1
        case io = 2
        case password = 3
        case damaged = 4
        case internalFailure = 5
    }

    public var kind: Kind
    public var message: String

    public var description: String { "QPDFError(\(kind)): \(message)" }
    public var errorDescription: String? { message }
}

/// PDF aberto no qpdf, com páginas de saída montadas por colocação de páginas de origem.
///
/// Fluxo: abrir; `addPage` cria uma página de saída; `place` coloca nela fatias de páginas de
/// origem; `removeSourcePages`; `write`. Não é thread-safe e por isso não é `Sendable`: use
/// uma instância por tarefa.
public final class QPDFDocument {
    private var handle: OpaquePointer?

    /// Abre o arquivo; `password` só é necessária em documento cifrado.
    public init(contentsOf url: URL, password: String? = nil) throws {
        var doc: OpaquePointer?
        try Self.call { err, cap in ipm_open(url.path, password, &doc, err, cap) }
        handle = doc
    }

    deinit { ipm_close(handle) }

    public var sourcePageCount: Int {
        get throws {
            var n: Int32 = 0
            try call { err, cap in ipm_source_page_count(handle, &n, err, cap) }
            return Int(n)
        }
    }

    public var outputPageCount: Int {
        get throws {
            var n: Int32 = 0
            try call { err, cap in ipm_output_page_count(handle, &n, err, cap) }
            return Int(n)
        }
    }

    public func sourcePageInfo(at index: Int) throws -> QPDFPageInfo {
        var media = [Double](repeating: 0, count: 4)
        var crop = [Double](repeating: 0, count: 4)
        var rotate: Int32 = 0
        try call { err, cap in
            ipm_source_page_info(handle, Int32(clamping: index), &media, &crop, &rotate, err, cap)
        }
        return QPDFPageInfo(mediaBox: QPDFRect(media), cropBox: QPDFRect(crop), rotation: Int(rotate))
    }

    /// Cria uma página de saída vazia no fim do documento e devolve seu índice.
    @discardableResult
    public func addPage(mediaBox: QPDFRect) throws -> Int {
        var page: Int32 = 0
        try call { err, cap in ipm_add_page(handle, mediaBox.array, &page, err, cap) }
        return Int(page)
    }

    /// Coloca a página de origem na de saída. `clip` está no espaço (bruto, sem `/Rotate`) da
    /// origem; `matrix` leva esse espaço ao da página de saída.
    public func place(sourcePage: Int, onto outputPage: Int, clip: QPDFRect, matrix: QPDFMatrix) throws {
        try call { err, cap in
            ipm_place_page(handle, Int32(clamping: outputPage), Int32(clamping: sourcePage), clip.array, matrix.array, err, cap)
        }
    }

    /// Acrescenta operadores PDF brutos à página de saída. A Helvetica fica disponível como
    /// `/IPMHelv` (`BT /IPMHelv 8 Tf … ET`).
    public func appendContent(_ content: String, toPage outputPage: Int) throws {
        let bytes = Array(content.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            try call { err, cap in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(buffer.count, 1)) { p in
                    ipm_append_content(handle, Int32(clamping: outputPage), p, buffer.count, err, cap)
                }
            }
        }
    }

    /// Remove as páginas originais; só as de saída ficam no arquivo.
    public func removeSourcePages() throws {
        try call { err, cap in ipm_remove_source_pages(handle, err, cap) }
    }

    /// Grava com streams comprimidos e object streams, sem criptografia. Em falha o arquivo
    /// de destino pode ficar parcial; grave num temporário se isso importar.
    public func write(to url: URL) throws {
        try call { err, cap in ipm_write(handle, url.path, err, cap) }
    }

    // MARK: - Fronteira C

    private static let errorCapacity = 1024

    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var buffer = [CChar](repeating: 0, count: errorCapacity)
        let status = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, errorCapacity) }
        if status != 0 {
            throw QPDFError(
                kind: QPDFError.Kind(rawValue: status) ?? .internalFailure,
                message: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            )
        }
    }

    private func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        try Self.call(body)
    }
}

extension QPDFRect {
    fileprivate init(_ a: [Double]) {
        self.init(llx: a[0], lly: a[1], urx: a[2], ury: a[3])
    }
}
