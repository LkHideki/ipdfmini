import Foundation

/// Pasta temporária dos PDFs convertidos só para o AirDrop ("Enviar para o iPad").
///
/// Fica dentro do `$TMPDIR` do usuário (0700, invisível para outros usuários). Cada envio
/// grava numa subpasta própria; o envio é assíncrono e o macOS lê os arquivos depois que
/// `perform` retorna, então nada é apagado na hora. Subpastas antigas saem em `prune`,
/// chamado no início do app e de cada envio.
public struct AirDropStaging: Sendable {
    public let root: URL

    public static let `default` = AirDropStaging(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("iPDFmini-AirDrop", isDirectory: true))

    public init(root: URL) { self.root = root }

    /// Cria uma subpasta nova para um envio.
    public func makeBatchDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Apaga subpastas de envios com mais de `maxAge` segundos. Devolve quantas saíram.
    @discardableResult
    public func prune(olderThan maxAge: TimeInterval = 6 * 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }
        var removed = 0
        for d in dirs {
            let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maxAge, (try? fm.removeItem(at: d)) != nil { removed += 1 }
        }
        return removed
    }

    /// Nomes de saída sem colisão dentro de um envio ("x — mini.pdf", "x — mini 2.pdf", …).
    public static func uniqueNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var candidate = name, n = 2
            while !used.insert(candidate.lowercased()).inserted {
                candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            return candidate
        }
    }
}
