import Foundation

/// Nomes de saída do lote: "{título} — mini.pdf" (§13), sem sobrescrever nada.
///
/// Reserva os nomes já dados no mesmo lote: dois documentos com o mesmo título
/// rodam em paralelo e nenhum dos dois arquivos existe ainda quando o nome é escolhido.
public struct BatchNaming: Sendable {
    public var destination: URL
    /// Recria as subpastas da origem dentro do destino.
    public var mirrorSubfolders: Bool
    private var reserved = Set<String>()
    private let exists: @Sendable (URL) -> Bool

    public init(destination: URL, mirrorSubfolders: Bool,
                exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.destination = destination
        self.mirrorSubfolders = mirrorSubfolders
        self.exists = exists
    }

    /// Pasta de saída de um documento.
    public func directory(for found: FoundPDF) -> URL {
        guard mirrorSubfolders, !found.relativeDirectory.isEmpty else { return destination }
        return found.relativeDirectory.split(separator: "/").reduce(destination) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }

    /// Próximo nome livre: "X — mini.pdf", "X — mini 2.pdf", "X — mini 3.pdf"…
    public mutating func output(for found: FoundPDF, title: String?) -> URL {
        let dir = directory(for: found)
        let name = ExportNaming.defaultFileName(title: title, sourceURL: found.url)
        let stem = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent(n == 1 ? name : "\(stem) \(n).pdf")
            // Volume padrão do macOS não distingue maiúsculas: a reserva também não.
            let key = candidate.standardizedFileURL.path.lowercased()
            if !reserved.contains(key), !exists(candidate), candidate.standardizedFileURL != found.url.standardizedFileURL {
                reserved.insert(key)
                return candidate
            }
            n += 1
        }
    }
}
