import Foundation

/// Item da fila: um PDF, a pasta de origem e a caixa "incluir no lote".
public struct QueueEntry: Sendable, Equatable, Identifiable {
    public var found: FoundPDF
    /// Opt-out: marcado por padrão; desmarcado fica na fila mas fora do lote.
    public var included: Bool

    public init(found: FoundPDF, included: Bool = true) {
        self.found = found
        self.included = included
    }

    public var id: String { found.key }
    public var url: URL { found.url }
    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

/// Seção da lateral: uma pasta de origem.
public struct QueueGroup: Sendable, Equatable, Identifiable {
    public var root: URL
    public var entries: [QueueEntry]

    public var id: String { root.path }
    /// Nome da pasta; "/" para a raiz.
    public var title: String { root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent }
    public var includedCount: Int { entries.count { $0.included } }
    /// "3 de 5" quando há desmarcados; senão só o total.
    public var countLabel: String {
        includedCount == entries.count ? "\(entries.count)" : "\(includedCount) de \(entries.count)"
    }
}

/// Fila de PDFs agrupada por pasta de origem. Somar arquivos ou pastas nunca
/// duplica: a chave é o caminho com symlinks resolvidos.
public struct BatchQueue: Sendable, Equatable {
    public private(set) var entries: [QueueEntry] = []

    public init() {}

    public struct AddResult: Sendable, Equatable {
        public var added: [QueueEntry] = []
        public var duplicates = 0
    }

    @discardableResult
    public mutating func add(_ found: [FoundPDF]) -> AddResult {
        var r = AddResult()
        var keys = Set(entries.map(\.id))
        for f in found {
            guard keys.insert(f.key).inserted else { r.duplicates += 1; continue }
            let e = QueueEntry(found: f)
            entries.append(e)
            r.added.append(e)
        }
        return r
    }

    public func entry(_ id: String) -> QueueEntry? { entries.first { $0.id == id } }

    /// Grupos na ordem da primeira chegada; itens na ordem em que entraram.
    public var groups: [QueueGroup] {
        var order: [String] = []
        var byRoot: [String: QueueGroup] = [:]
        for e in entries {
            let k = e.found.root.path
            if byRoot[k] == nil {
                order.append(k)
                byRoot[k] = QueueGroup(root: e.found.root, entries: [])
            }
            byRoot[k]!.entries.append(e)
        }
        return order.map { byRoot[$0]! }
    }

    public var included: [QueueEntry] { entries.filter(\.included) }
    public var includedCount: Int { entries.count { $0.included } }

    public mutating func setIncluded(_ id: String, _ value: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].included = value
    }

    /// Marcar/desmarcar todos de uma pasta.
    public mutating func setIncluded(groupRoot: URL, _ value: Bool) {
        for i in entries.indices where entries[i].found.root.path == groupRoot.path { entries[i].included = value }
    }

    public mutating func setAllIncluded(_ value: Bool) {
        for i in entries.indices { entries[i].included = value }
    }

    /// Tira da fila os desmarcados; devolve as chaves removidas.
    @discardableResult
    public mutating func removeExcluded() -> [String] {
        let gone = entries.filter { !$0.included }.map(\.id)
        entries.removeAll { !$0.included }
        return gone
    }

    public mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// Tira da lista a seção da pasta (com as subpastas que vieram com ela); devolve as
    /// chaves removidas, na ordem da fila. Só a lista muda: nada é apagado nem movido no
    /// disco, e arrastar a pasta de novo a traz de volta.
    @discardableResult
    public mutating func removeGroup(root: URL) -> [String] {
        let gone = entries.filter { $0.found.root.path == root.path }.map(\.id)
        entries.removeAll { $0.found.root.path == root.path }
        return gone
    }

    /// Seleção depois de `removed` sair: a atual se ficou; senão o próximo da fila depois
    /// dela, ou o anterior; `nil` (tela vazia) se não sobrou nada. `before` = ordem antiga.
    public static func selection(after removed: Set<String>, current: String?, before: [String]) -> String? {
        guard let current else { return nil }
        guard removed.contains(current) else { return current }
        guard let i = before.firstIndex(of: current) else { return before.first { !removed.contains($0) } }
        return before[(i + 1)...].first { !removed.contains($0) } ?? before[..<i].last { !removed.contains($0) }
    }
}

/// Ajustes por documento sobre um padrão do lote ("receitas reaplicáveis").
///
/// Mexer no inspetor de um documento grava um ajuste próprio dele; quem não tem
/// ajuste usa o padrão. "Usar como padrão" promove os ajustes de um documento.
public struct SettingsStore: Sendable, Equatable {
    public var defaults: ConversionSettings
    public private(set) var overrides: [String: ConversionSettings] = [:]

    public init(defaults: ConversionSettings = ConversionSettings()) { self.defaults = defaults }

    public func effective(_ id: String) -> ConversionSettings { overrides[id] ?? defaults }
    public func hasOverride(_ id: String) -> Bool { overrides[id] != nil }

    /// Igual ao padrão não conta como ajuste próprio (volta a seguir o padrão).
    public mutating func set(_ id: String, _ s: ConversionSettings) {
        overrides[id] = s == defaults ? nil : s
    }

    public mutating func reset(_ id: String) { overrides[id] = nil }

    /// Os ajustes do documento viram o padrão; ele passa a seguir o padrão.
    public mutating func makeDefault(from id: String) {
        defaults = effective(id)
        overrides[id] = nil
        // Ajustes que agora coincidem com o padrão deixam de ser próprios.
        overrides = overrides.filter { $0.value != defaults }
    }

    public mutating func forget(_ ids: some Sequence<String>) { for id in ids { overrides[id] = nil } }
}

/// Aviso depois de somar arquivos/pastas à fila.
public enum QueueNotice {
    /// Banner depois de deslistar uma pasta.
    public static func folderRemoved(_ title: String, count: Int) -> String {
        "Pasta \(title) removida da lista (\(count == 1 ? "1 PDF" : "\(count) PDFs")) — os arquivos continuam no disco"
    }

    public static func text(added: Int, duplicates: Int, rejected: Int, folders: Int) -> String {
        var parts: [String] = []
        if added == 0 {
            parts.append(duplicates > 0 || rejected > 0 ? "Nenhum PDF novo" : "Nenhum PDF encontrado")
        } else {
            let docs = added == 1 ? "1 PDF adicionado" : "\(added) PDFs adicionados"
            parts.append(folders > 1 ? "\(docs) de \(folders) pastas" : docs)
        }
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 já estava na fila" : "\(duplicates) já estavam na fila") }
        if rejected > 0 { parts.append(rejected == 1 ? "1 item ignorado (não é PDF)" : "\(rejected) itens ignorados (não são PDF)") }
        return parts.joined(separator: " · ") + "."
    }
}
