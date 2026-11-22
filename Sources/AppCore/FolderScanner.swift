import Foundation
import UniformTypeIdentifiers

/// Um PDF encontrado ao abrir arquivos ou pastas.
public struct FoundPDF: Sendable, Equatable {
    /// Caminho com symlinks resolvidos: chave de deduplicação da fila.
    public var url: URL
    /// Pasta de origem do grupo na lateral: a pasta solta/aberta, ou a pasta do arquivo avulso.
    public var root: URL
    /// Subpasta relativa a `root` ("" no primeiro nível), para espelhar a estrutura no lote.
    public var relativeDirectory: String

    public init(url: URL, root: URL, relativeDirectory: String = "") {
        self.url = url
        self.root = root
        self.relativeDirectory = relativeDirectory
    }

    public var key: String { url.path }
}

public struct ScanResult: Sendable, Equatable {
    public var found: [FoundPDF] = []
    /// Arquivos soltos/abertos diretamente que não são PDF (os de dentro de pastas são só ignorados).
    public var rejected: [URL] = []
}

/// Varre arquivos e pastas atrás de PDFs (arrastar pastas, "Abrir…").
///
/// Recursiva; ignora ocultos e pacotes (.app, .pages…); segue symlinks de pasta
/// com conjunto de visitadas (sem laço). PDF = tipo UTType conforme a `com.adobe.pdf`
/// e cabeçalho `%PDF-` no primeiro KB: a extensão sozinha deixaria passar um texto
/// renomeado, que só falharia depois no processo filho.
public enum FolderScanner {
    public static func scan(_ urls: [URL]) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        var visitedDirs = Set<String>()
        for raw in urls {
            let url = resolved(raw)
            guard let isDir = isDirectory(url) else { result.rejected.append(raw); continue }
            if isDir {
                // Pacote solto de propósito também é ignorado (um .app não tem PDFs do usuário).
                if isPackage(url) { result.rejected.append(raw); continue }
                var found: [FoundPDF] = []
                walk(url, root: url, relative: "", visited: &visitedDirs, into: &found)
                for f in found.sorted(by: { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending })
                where seen.insert(f.key).inserted {
                    result.found.append(f)
                }
            } else if isPDF(url) {
                if seen.insert(url.path).inserted {
                    result.found.append(FoundPDF(url: url, root: url.deletingLastPathComponent()))
                }
            } else {
                result.rejected.append(raw)
            }
        }
        return result
    }

    static func walk(_ dir: URL, root: URL, relative: String, visited: inout Set<String>, into out: inout [FoundPDF]) {
        guard visited.insert(dir.path).inserted else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return }
        for child in children {
            if child.lastPathComponent.hasPrefix(".") { continue }
            if (try? child.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true { continue }
            let target = resolved(child)
            guard let isDir = isDirectory(target) else { continue }
            if isDir {
                if isPackage(target) { continue }
                let name = child.lastPathComponent
                walk(target, root: root, relative: relative.isEmpty ? name : relative + "/" + name, visited: &visited, into: &out)
            } else if isPDF(target) {
                out.append(FoundPDF(url: target, root: root, relativeDirectory: relative))
            }
        }
    }

    /// Caminho canônico: symlinks resolvidos e `/private/var` ≡ `/var` unificados.
    public static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isDirectory(_ url: URL) -> Bool? {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { return nil }
        return dir.boolValue
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// Tipo pelo UTType do arquivo e conteúdo pelo cabeçalho.
    public static func isPDF(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .pdf) else { return false }
        return hasPDFHeader(url)
    }

    /// A especificação admite lixo antes de `%PDF-` dentro do primeiro KB.
    static func hasPDFHeader(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 1024), !data.isEmpty else { return false }
        return data.range(of: Data("%PDF-".utf8)) != nil
    }
}
